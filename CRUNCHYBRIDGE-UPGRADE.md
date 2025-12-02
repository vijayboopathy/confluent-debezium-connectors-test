# CrunchyBridge Database Upgrade Procedure

## Overview

This document provides a comprehensive procedure for upgrading your PostgreSQL database on CrunchyBridge while preventing data loss and duplicate events for Debezium CDC.

**Key Facts:**
- CrunchyBridge uses **PGbackrest** for database restore
- PGbackrest restore **does NOT preserve LSN continuity**
- Replication slots and publications are **NOT preserved**
- Old LSN offsets become **invalid** on the restored database
- **Strategy**: Accept gap during upgrade, prevent duplicates after

## Architecture During Upgrade

```
Before Upgrade:
  Application → Old DB → Replication Slot → Debezium → Kafka → Consumers
                  (LSN: 0/12345678)

During Upgrade (Database Frozen):
  Application → [FROZEN] → Debezium STOPPED
  CrunchyBridge: PGbackrest restore in progress
  Gap: Changes during this window are NOT captured

After Upgrade:
  Application → New DB → NEW Replication Slot → Debezium → Kafka → Consumers
                  (LSN: 0/ABCDEF - NEW timeline!)
```

## Pre-Upgrade Checklist

### 1. Verify Current State

```bash
# Check connector health
curl http://localhost:8083/connectors/postgres-cdc-connector/status | jq '.'

# Get current LSN (for reference only - will be invalid after restore)
docker exec postgres psql -U postgres -d testdb -c \
  "SELECT slot_name, confirmed_flush_lsn, active FROM pg_replication_slots WHERE slot_name = 'debezium_slot';"

# Check topic message counts (baseline)
docker exec kafka kafka-run-class kafka.tools.GetOffsetShell \
  --broker-list localhost:9092 \
  --topic cdc.public.orders \
  --time -1
```

### 2. Capture State for Gap Analysis (Optional)

If you want to measure the gap (even though you're not filling it):

```bash
# Record current row counts
docker exec postgres psql -U postgres -d testdb -c \
  "SELECT 'orders' as table_name, COUNT(*) as row_count FROM orders
   UNION ALL
   SELECT 'customers', COUNT(*) FROM customers;"

# Record max IDs (if using sequences)
docker exec postgres psql -U postgres -d testdb -c \
  "SELECT 'orders' as table_name, MAX(id) as max_id FROM orders
   UNION ALL
   SELECT 'customers', MAX(id) FROM customers;"

# Record timestamp
date -u +"%Y-%m-%d %H:%M:%S UTC" > upgrade_start_time.txt
```

### 3. Stop the Connector

**IMPORTANT**: Delete the connector (not just pause) to ensure clean slate:

```bash
# Capture final offset (for reference/debugging)
curl http://localhost:8083/connectors/postgres-cdc-connector/offsets > pre_upgrade_offsets.json

# Delete the connector
curl -X DELETE http://localhost:8083/connectors/postgres-cdc-connector

# Verify deletion
curl http://localhost:8083/connectors/
```

### 4. Stop Application Writes (Recommended)

Stop your data generator or applications to freeze writes:

```bash
docker-compose stop data-generator
```

### 5. Final Verification

```bash
# Verify no active replication connections
docker exec postgres psql -U postgres -d testdb -c \
  "SELECT * FROM pg_stat_replication;"

# Should return no rows (connector is stopped)
```

## During Upgrade

**CrunchyBridge performs the upgrade:**
1. Creates PGbackrest backup
2. Provisions new database instance
3. Restores from backup + WAL replay
4. Provides new connection details

**What happens to CDC:**
- ❌ Replication slot `debezium_slot` is NOT preserved
- ❌ Publication `debezium_publication` is NOT preserved  
- ❌ LSN sequence starts fresh on new timeline
- ⚠️ Gap exists: changes during frozen period are NOT captured (but you don't care)

## Post-Upgrade Setup

### 1. Connect to New Database

Update your connection details (if hostname changed):

```bash
# Test connection to new database
psql -h new-db-host.crunchybridge.com -U postgres -d testdb

# Or with docker (update docker-compose.yml if needed)
docker exec postgres psql -U postgres -d testdb
```

### 2. Recreate Replication Infrastructure

Run the post-upgrade setup script:

```bash
./post-upgrade-setup.sh
```

Or manually:

```sql
-- Create replication slot (same name as before)
SELECT * FROM pg_create_logical_replication_slot('debezium_slot', 'pgoutput');

-- Create publication
CREATE PUBLICATION debezium_publication FOR TABLE public.orders, public.customers;

-- Set replica identity (required for CDC)
ALTER TABLE public.orders REPLICA IDENTITY FULL;
ALTER TABLE public.customers REPLICA IDENTITY FULL;

-- Verify setup
SELECT * FROM pg_replication_slots WHERE slot_name = 'debezium_slot';
SELECT * FROM pg_publication WHERE pubname = 'debezium_publication';
```

### 3. Update Connector Configuration

The key decision: **snapshot.mode**

**Option A: Skip Snapshot (Zero Duplicates, Accept Gap)**

```json
{
  "name": "postgres-cdc-connector",
  "config": {
    "connector.class": "io.debezium.connector.postgresql.PostgresConnector",
    "tasks.max": "1",
    "database.hostname": "NEW_DB_HOST",
    "database.port": "5432",
    "database.user": "postgres",
    "database.password": "postgres",
    "database.dbname": "testdb",
    "database.server.name": "postgres_server",
    "topic.prefix": "cdc",
    "plugin.name": "pgoutput",
    "slot.name": "debezium_slot",
    "publication.name": "debezium_publication",
    "publication.autocreate.mode": "disabled",
    "table.include.list": "public.orders,public.customers",
    "heartbeat.interval.ms": "10000",
    "snapshot.mode": "never",
    "key.converter": "org.apache.kafka.connect.json.JsonConverter",
    "value.converter": "org.apache.kafka.connect.json.JsonConverter",
    "key.converter.schemas.enable": "false",
    "value.converter.schemas.enable": "true",
    "transforms": "unwrap",
    "transforms.unwrap.type": "io.debezium.transforms.ExtractNewRecordState",
    "transforms.unwrap.drop.tombstones": "false",
    "transforms.unwrap.delete.handling.mode": "rewrite",
    "transforms.unwrap.add.fields": "op,source.ts_ms,source.lsn"
  }
}
```

**Key Changes:**
- `snapshot.mode: "never"` - Skip snapshot, only stream NEW changes
- `publication.autocreate.mode: "disabled"` - Use manually created publication
- `database.hostname` - Update if changed

**Option B: Full Snapshot (Includes Duplicates, No Gap)**

```json
{
  "snapshot.mode": "initial",
  "publication.autocreate.mode": "filtered"
}
```

Use this if:
- Your idempotent applications can handle duplicates
- You want a fresh baseline of all data
- You're okay with longer startup time

### 4. Deploy the Connector

```bash
# Update connector-config.json with your choice above
# Then deploy:

curl -X POST http://localhost:8083/connectors \
  -H "Content-Type: application/json" \
  -d @connector-config-post-upgrade.json

# Check status
curl http://localhost:8083/connectors/postgres-cdc-connector/status | jq '.'
```

### 5. Restart Application Writes

```bash
docker-compose start data-generator
```

## Verification Procedures

### 1. Verify Connector Health

```bash
# Check connector status (should be RUNNING)
curl http://localhost:8083/connectors/postgres-cdc-connector/status | jq '.connector.state'

# Check task status
curl http://localhost:8083/connectors/postgres-cdc-connector/status | jq '.tasks[].state'

# View connector logs
docker-compose logs -f kafka-connect | grep postgres-cdc-connector
```

### 2. Verify Replication Slot Activity

```bash
docker exec postgres psql -U postgres -d testdb -c \
  "SELECT slot_name, active, confirmed_flush_lsn, 
          pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)) as lag
   FROM pg_replication_slots 
   WHERE slot_name = 'debezium_slot';"
```

Expected:
- `active = true` (connector is connected)
- `lag` should be small (bytes to KB, not MB/GB)

### 3. Test CDC with Sample Data

```bash
# Insert test record
docker exec postgres psql -U postgres -d testdb -c \
  "INSERT INTO orders (customer_id, order_date, total_amount, status) 
   VALUES (999, NOW(), 888.88, 'test_post_upgrade');"

# Consume from Kafka (should see the test record)
docker exec kafka kafka-console-consumer \
  --bootstrap-server localhost:9092 \
  --topic cdc.public.orders \
  --max-messages 10 \
  --timeout-ms 5000 | grep test_post_upgrade
```

### 4. Check for Duplicates (if using snapshot.mode: initial)

```bash
# Run the verification script
./verify-no-duplicates.sh
```

### 5. Monitor Offset Progression

```bash
# Check connector offsets (should have NEW LSN values)
curl http://localhost:8083/connectors/postgres-cdc-connector/offsets | jq '.'

# Compare to pre-upgrade offsets
diff <(cat pre_upgrade_offsets.json | jq -S .) \
     <(curl -s http://localhost:8083/connectors/postgres-cdc-connector/offsets | jq -S .)
```

Expected: LSN values will be completely different (new timeline)

## Gap Analysis (Post-Upgrade)

If you want to measure the gap (even though you're not filling it):

```bash
# Compare row counts
docker exec postgres psql -U postgres -d testdb -c \
  "SELECT 'orders' as table_name, COUNT(*) as row_count FROM orders
   UNION ALL
   SELECT 'customers', COUNT(*) FROM customers;"

# Compare with pre-upgrade counts
# Gap = (new count - old count) - (records seen in Kafka during upgrade)
```

## Rollback Procedure

If something goes wrong after the upgrade:

### 1. Stop the Connector

```bash
curl -X DELETE http://localhost:8083/connectors/postgres-cdc-connector
```

### 2. Contact CrunchyBridge Support

- Request rollback to pre-upgrade snapshot
- They can restore from PGbackrest backup

### 3. Recreate Replication Infrastructure

Once rolled back:
- Replication slot should be restored with backup
- Publication should be restored with backup
- Resume with old connector configuration

## Troubleshooting

### Connector fails to start with "replication slot does not exist"

**Cause**: Replication slot not created on new database

**Solution**:
```bash
docker exec postgres psql -U postgres -d testdb -c \
  "SELECT * FROM pg_create_logical_replication_slot('debezium_slot', 'pgoutput');"
```

### Connector fails with "publication does not exist"

**Cause**: Publication not created on new database

**Solution**:
```bash
docker exec postgres psql -U postgres -d testdb -c \
  "CREATE PUBLICATION debezium_publication FOR TABLE public.orders, public.customers;"
```

### Connector fails with "replica identity not set"

**Cause**: Tables missing replica identity configuration

**Solution**:
```bash
docker exec postgres psql -U postgres -d testdb -c \
  "ALTER TABLE public.orders REPLICA IDENTITY FULL;
   ALTER TABLE public.customers REPLICA IDENTITY FULL;"
```

### Seeing duplicate events in Kafka

**Cause**: Used `snapshot.mode: "initial"` which re-snapshots all data

**Solution**: 
- If applications are idempotent: No action needed
- If not: Implement consumer-side deduplication using primary keys
- Or: Restart with `snapshot.mode: "never"` (but will lose snapshot benefits)

### Connector offset shows old LSN values

**Cause**: Connector is trying to use pre-upgrade offsets (which are invalid)

**Solution**: Delete and recreate connector to clear offsets:
```bash
curl -X DELETE http://localhost:8083/connectors/postgres-cdc-connector
# Wait 10 seconds
curl -X POST http://localhost:8083/connectors -H "Content-Type: application/json" -d @connector-config.json
```

### Replication slot lag growing

**Cause**: Connector not consuming fast enough, or connector is down

**Solution**:
```bash
# Check connector status
curl http://localhost:8083/connectors/postgres-cdc-connector/status

# Check connector logs for errors
docker-compose logs kafka-connect | tail -100

# Monitor replication lag
docker exec postgres psql -U postgres -d testdb -c \
  "SELECT pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)) as lag
   FROM pg_replication_slots WHERE slot_name = 'debezium_slot';"
```

## Best Practices

### Before Upgrade
1. ✅ Test the entire procedure in staging environment first
2. ✅ Capture baseline metrics (row counts, LSN, Kafka offsets)
3. ✅ Schedule maintenance window (communicate to downstream consumers)
4. ✅ Have CrunchyBridge support contact ready

### During Upgrade
1. ✅ Monitor CrunchyBridge upgrade progress
2. ✅ Keep connector stopped (don't try to reconnect)
3. ✅ Communicate status to team

### After Upgrade
1. ✅ Verify replication slot and publication exist before deploying connector
2. ✅ Start with `snapshot.mode: "never"` for zero duplicates
3. ✅ Monitor connector health for 1-2 hours after upgrade
4. ✅ Alert downstream consumers that CDC has resumed

## Production Considerations

### For Applications That CANNOT Handle Duplicates

Since you're using `snapshot.mode: "never"`, they won't see duplicates. However:

1. **Gap Awareness**: They will miss changes that occurred during upgrade window
2. **Solution Options**:
   - Accept the gap (if acceptable for your use case)
   - Manually query and produce gap records (complex)
   - Use database triggers to log changes during upgrade (requires planning)

### For Applications That CAN Handle Duplicates (Idempotent)

You have flexibility to use `snapshot.mode: "initial"`:
- ✅ Fresh baseline of all data
- ✅ No gap concerns
- ✅ Longer startup time (acceptable tradeoff)

### Monitoring After Upgrade

Set up alerts for:
- Replication slot lag > 100MB
- Connector state != RUNNING
- Kafka topic lag increasing
- No new messages in topics for > 5 minutes

## Summary

**Pre-Upgrade:**
1. Stop connector (DELETE)
2. Capture state (optional)
3. CrunchyBridge upgrades (PGbackrest restore)

**Post-Upgrade:**
1. Create replication slot `debezium_slot`
2. Create publication `debezium_publication`
3. Deploy connector with `snapshot.mode: "never"` (zero duplicates)
4. Verify health and CDC flow

**Key Insight:**
- PGbackrest restore = new LSN timeline = old offsets invalid
- Gap is acceptable (as per your requirement)
- Zero duplicates achieved with `snapshot.mode: "never"`

## Next Steps

1. Test this procedure in staging
2. Run `./test-pgbackrest-restore.sh` to simulate locally
3. Coordinate with CrunchyBridge for upgrade window
4. Execute procedure during maintenance window
