# Debezium PostgreSQL CDC Connector Testing with Database Upgrade

This project tests the Debezium PostgreSQL CDC connector behavior during a PostgreSQL database upgrade, focusing on offset management and replication slot handling.

**Key Testing Scenarios:**
- Standard in-place PostgreSQL upgrades (LSN continuity preserved)
- PGbackrest-style restores (LSN continuity lost - like CrunchyBridge upgrades)
- Zero-duplicate CDC event strategies
- Gap analysis and verification

## Architecture

```
Data Generator Service → PostgreSQL (with logical replication) → Replication Slot → Debezium CDC Connector → Kafka
```

## Components

- **PostgreSQL 16**: Configured with logical replication (`wal_level=logical`)
- **Confluent Platform 7.5.0**: Kafka, Zookeeper, Schema Registry, Kafka Connect
- **Debezium PostgreSQL CDC Connector 2.4.0**: Open-source CDC connector using pgoutput plugin
- **Data Generator**: Python service that continuously writes to PostgreSQL

## Important Note

This project uses the **open-source Debezium PostgreSQL connector**, not the Confluent proprietary CDC connector. The Confluent PostgreSQL CDC Source Connector v2 is a commercial product that requires a Confluent Enterprise license and is not available for free download.

Debezium is an excellent open-source alternative that provides:
- Full CDC capabilities using PostgreSQL logical replication
- Wide community adoption and support
- Compatible with any Kafka distribution
- Free to use in production

## Prerequisites

- Docker and Docker Compose
- At least 4GB of available RAM
- Ports 5432, 9092, 8081, 8083 available
- Internet connection (for initial build to download Debezium connector)

## Quick Start

1. **Build and start the stack**:
   ```bash
   docker-compose build
   docker-compose up -d
   ```

2. **Wait for all services to be healthy** (about 1-2 minutes):
   ```bash
   docker-compose ps
   ```

3. **Verify Debezium connector is available**:
   ```bash
   curl http://localhost:8083/connector-plugins | jq '.[] | select(.class | contains("Postgres"))'
   ```

4. **Deploy the CDC connector**:
   
   **For initial deployment or standard upgrades (Scenario 1):**
   ```bash
   curl -X POST http://localhost:8083/connectors \
     -H "Content-Type: application/json" \
     -d @connector-config.json
   ```
   
   **For PGbackrest restore upgrades (Scenario 2 - CrunchyBridge):**
   ```bash
   # First, recreate replication infrastructure
   ./post-upgrade-setup.sh
   
   # Then deploy with snapshot.mode: never (prevents duplicates)
   curl -X POST http://localhost:8083/connectors \
     -H "Content-Type: application/json" \
     -d @connector-config-post-upgrade.json
   ```

5. **Check connector status**:
   ```bash
   curl http://localhost:8083/connectors/postgres-cdc-connector/status | jq '.'
   ```

6. **List CDC topics**:
   ```bash
   docker exec kafka kafka-topics --list --bootstrap-server localhost:9092 | grep cdc
   ```

7. **Monitor CDC events**:
   ```bash
   docker exec -it kafka kafka-console-consumer \
     --bootstrap-server localhost:9092 \
     --topic cdc.public.orders \
     --from-beginning
   ```

## Choosing Your Upgrade Strategy

⚠️ **IMPORTANT: Choose the correct configuration based on your upgrade type**

### Scenario 1: In-Place Upgrades (LSN Continuity Preserved)
**Use this for:**
- Minor PostgreSQL version upgrades (e.g., 16.0 → 16.1)
- Major version upgrades using `pg_upgrade` (e.g., 16 → 17)
- Upgrades where replication slots are preserved

**Configuration:** `connector-config.json` (with `snapshot.mode: initial`)  
**Procedure:** Pause connector → Upgrade database → Resume connector  
**Result:** ✅ No duplicates, ✅ No gap  
**See:** "Testing Database Upgrade with Offset Resume" section below

### Scenario 2: PGbackrest Restore (LSN Continuity Lost)
**Use this for:**
- **CrunchyBridge database upgrades** ⚠️
- Cross-region database migrations
- Disaster recovery from backups
- Any situation where database is restored using `pg_dump`/`pg_restore` or PGbackrest

**Configuration:** `connector-config-post-upgrade.json` (with `snapshot.mode: never`)  
**Procedure:** Delete connector → Restore database → Recreate replication infrastructure → Deploy new connector  
**Result:** ✅ Zero duplicates, ⚠️ Gap exists (changes during upgrade window not captured)  
**See:** [CRUNCHYBRIDGE-UPGRADE.md](CRUNCHYBRIDGE-UPGRADE.md) for complete guide

### Configuration Comparison

| Setting | connector-config.json | connector-config-post-upgrade.json |
|---------|----------------------|-----------------------------------|
| **Use Case** | Initial deployment, Scenario 1 | Scenario 2 (after PGbackrest restore) |
| **snapshot.mode** | `initial` (takes snapshot) | `never` (no snapshot) ⚠️ |
| **publication.autocreate.mode** | `filtered` | `disabled` |
| **When to Use** | Standard upgrades, first deploy | After backup/restore upgrades |
| **Duplicates** | None (with Scenario 1) | Zero (skips snapshot) |
| **Gap** | None | Yes (acceptable tradeoff) |

## Testing Database Upgrade with Offset Resume (Scenario 1)

⚠️ **This section is for Scenario 1 only.** For CrunchyBridge/PGbackrest upgrades (Scenario 2), see [CRUNCHYBRIDGE-UPGRADE.md](CRUNCHYBRIDGE-UPGRADE.md).

### Step 1: Capture Current State

Before the upgrade, capture the current replication slot and offset information:

```bash
# Check replication slot status
docker exec -it postgres psql -U postgres -d testdb -c \
  "SELECT * FROM pg_replication_slots WHERE slot_name = 'debezium_slot';"

# Check connector offset
curl http://localhost:8083/connectors/postgres-cdc-connector/offsets

# Note the LSN (Log Sequence Number)
docker exec -it postgres psql -U postgres -d testdb -c \
  "SELECT confirmed_flush_lsn FROM pg_replication_slots WHERE slot_name = 'debezium_slot';"
```

### Step 2: Pause the Connector

```bash
curl -X PUT http://localhost:8083/connectors/postgres-cdc-connector/pause
```

### Step 3: Stop Data Generator

```bash
docker-compose stop data-generator
```

### Step 4: Backup the Database

```bash
# Backup with replication slot information
docker exec postgres pg_dump -U postgres -d testdb -F c -f /tmp/testdb_backup.dump

# Copy backup to host
docker cp postgres:/tmp/testdb_backup.dump ./testdb_backup.dump
```

### Step 5: Simulate Database Upgrade

Option A - Upgrade PostgreSQL version in-place (e.g., from 16.0 to 16.1):
```bash
# Stop all services
docker-compose down

# Edit docker-compose.yml and change postgres image to postgres:16.1 or postgres:17
# Then restart
docker-compose up -d postgres
```

Option B - Create new database instance (simulate migration to new server):
```bash
# Start new postgres instance (on different port)
docker run -d --name postgres-new \
  -e POSTGRES_USER=postgres \
  -e POSTGRES_PASSWORD=postgres \
  -e POSTGRES_DB=testdb \
  -p 5433:5432 \
  postgres:17 \
  postgres -c wal_level=logical \
           -c max_wal_senders=10 \
           -c max_replication_slots=10

# Restore backup
docker cp ./testdb_backup.dump postgres-new:/tmp/
docker exec postgres-new pg_restore -U postgres -d testdb /tmp/testdb_backup.dump
```

### Step 6: Recreate Replication Slot

```bash
# Connect to the new/upgraded database
docker exec -it postgres psql -U postgres -d testdb

# Create the replication slot with the same name
SELECT * FROM pg_create_logical_replication_slot('debezium_slot', 'pgoutput');

# Create publication
CREATE PUBLICATION debezium_publication FOR TABLE public.orders, public.customers;

# Set replica identity
ALTER TABLE orders REPLICA IDENTITY FULL;
ALTER TABLE customers REPLICA IDENTITY FULL;
```

### Step 7: Resume Connector

The connector should resume from its stored offset:

```bash
# Resume the connector
curl -X PUT http://localhost:8083/connectors/postgres-cdc-connector/resume

# Monitor status
curl http://localhost:8083/connectors/postgres-cdc-connector/status
```

### Step 8: Restart Data Generator

```bash
docker-compose start data-generator
```

### Step 9: Verify Offset Resume

```bash
# Check for any missing or duplicate events
docker exec -it kafka kafka-console-consumer \
  --bootstrap-server localhost:9092 \
  --topic cdc.public.orders \
  --from-beginning

# Verify connector is processing new changes
docker-compose logs -f kafka-connect
```

## Monitoring

### Check Kafka Topics

```bash
docker exec -it kafka kafka-topics --list --bootstrap-server localhost:9092
```

### View Connector Logs

```bash
docker-compose logs -f kafka-connect
```

### Monitor Data Generator

```bash
docker-compose logs -f data-generator
```

### PostgreSQL Replication Status

```bash
docker exec -it postgres psql -U postgres -d testdb -c \
  "SELECT slot_name, plugin, slot_type, active, confirmed_flush_lsn FROM pg_replication_slots;"
```

## Offset Management Details

The Debezium connector stores offsets in the Kafka topic `docker-connect-offsets`. Key information includes:

- **LSN (Log Sequence Number)**: PostgreSQL's position in the WAL
- **Transaction ID**: Last processed transaction
- **Timestamp**: When the offset was recorded

The connector configuration uses:
- `slot.name`: `debezium_slot` - the replication slot name
- `publication.name`: `debezium_publication` - the logical replication publication
- `snapshot.mode`: `initial` - takes initial snapshot, then streams changes
- `plugin.name`: `pgoutput` - PostgreSQL's native logical replication output plugin
- `transforms`: Uses `ExtractNewRecordState` to unwrap Debezium change events

## Automated Testing

### Standard Upgrade Test (LSN Continuity Preserved)

For testing upgrades where replication slots persist (e.g., minor version upgrades):

```bash
./test-upgrade.sh
```

This script will:
1. Capture current state (LSN, offsets, message counts)
2. Pause the connector and stop data generator
3. Insert test data during simulated downtime
4. Create database backup
5. Restart PostgreSQL (simulating upgrade)
6. Verify replication slot persistence
7. Resume connector and data generator
8. Verify no data loss and offset resume

### PGbackrest Restore Test (LSN Continuity Lost)

For testing upgrades where database is restored from backup (e.g., CrunchyBridge upgrades):

```bash
./test-pgbackrest-restore.sh
```

This script simulates a **CrunchyBridge-style upgrade** where:
1. Database is restored using PGbackrest (LSN timeline changes)
2. Replication slots and publications are NOT preserved
3. Connector must be reconfigured with `snapshot.mode: never` to prevent duplicates
4. Gap exists (changes during upgrade are not captured)
5. Verifies zero duplicates after upgrade

**See [CRUNCHYBRIDGE-UPGRADE.md](CRUNCHYBRIDGE-UPGRADE.md) for detailed CrunchyBridge upgrade procedures.**

### Verification Script

To verify no duplicate events after upgrade:

```bash
./verify-no-duplicates.sh
```

This script:
- Checks for duplicate primary keys in Kafka messages
- Verifies LSN uniqueness
- Analyzes operation types (detects unexpected snapshot reads)
- Compares database row count vs Kafka message count (gap detection)
- Provides pass/fail results

## Key Configuration Files

### Core Files
- `docker-compose.yml`: Complete stack definition with PostgreSQL 16
- `Dockerfile.connect`: Custom Kafka Connect image with Debezium pre-installed
- `init-db.sql`: Database initialization script
- `data-generator/generator.py`: Data generation service

### Connector Configurations (Choose One)
- **`connector-config.json`**: 
  - For initial deployment and Scenario 1 (standard upgrades)
  - Has `snapshot.mode: initial` (takes initial snapshot, then streams changes)
  - Use when replication slots are preserved during upgrade
  
- **`connector-config-post-upgrade.json`**: ⚠️
  - For Scenario 2 (PGbackrest restore / CrunchyBridge upgrades)
  - Has `snapshot.mode: never` (NO snapshot - prevents duplicates)
  - Use after backup/restore when LSN continuity is lost
  - **This is the key difference for preventing duplicates!**

### Scripts
- `test-upgrade.sh`: Standard upgrade testing (Scenario 1 - LSN preserved)
- `test-pgbackrest-restore.sh`: PGbackrest restore simulation (Scenario 2 - LSN lost)
- `post-upgrade-setup.sh`: Recreates replication slots and publications after restore
- `verify-no-duplicates.sh`: Verifies no duplicate events in Kafka

### Documentation
- `CRUNCHYBRIDGE-UPGRADE.md`: Comprehensive guide for CrunchyBridge/PGbackrest upgrades
- `CONNECTOR-CONFIG.md`: Detailed connector configuration reference

## Troubleshooting

### Connector not starting

```bash
# Check connector logs
docker-compose logs kafka-connect

# Verify PostgreSQL is accessible
docker exec -it kafka-connect ping postgres
```

### I used the wrong connector config - seeing duplicates!

**Problem:** Deployed `connector-config.json` (with `snapshot.mode: initial`) after a PGbackrest restore, now seeing duplicate events.

**Solution:**
```bash
# 1. Delete the connector
curl -X DELETE http://localhost:8083/connectors/postgres-cdc-connector

# 2. Wait a few seconds
sleep 5

# 3. Deploy with the correct config (snapshot.mode: never)
curl -X POST http://localhost:8083/connectors \
  -H "Content-Type: application/json" \
  -d @connector-config-post-upgrade.json

# 4. Verify it's using the right config
curl http://localhost:8083/connectors/postgres-cdc-connector/config | jq '.["snapshot.mode"]'
# Should show: "never"
```

### How do I know which connector config to use?

**Use `connector-config.json` if:**
- ✅ First time deploying the connector
- ✅ Database upgraded in-place (minor version bump)
- ✅ Used `pg_upgrade` for major version upgrade
- ✅ Replication slot still exists after upgrade

**Use `connector-config-post-upgrade.json` if:**
- ✅ Database restored from backup (PGbackrest, pg_dump, pg_restore)
- ✅ **CrunchyBridge database upgrade**
- ✅ Cross-region migration
- ✅ Replication slot does NOT exist after upgrade
- ✅ Want zero duplicates (accept gap)

**Quick test:**
```bash
# Check if replication slot exists
docker exec postgres psql -U postgres -d testdb -c \
  "SELECT COUNT(*) FROM pg_replication_slots WHERE slot_name = 'debezium_slot';"

# If returns 0: Use connector-config-post-upgrade.json
# If returns 1: Can use connector-config.json
```

### Seeing duplicate events in Kafka

**Cause:** Used `snapshot.mode: initial` after a backup/restore upgrade (LSN timeline changed)

**Prevention:**
- Always use `connector-config-post-upgrade.json` (with `snapshot.mode: never`) after PGbackrest restores

**Verification:**
```bash
# Run duplicate detection
./verify-no-duplicates.sh
```

### Replication slot issues

```bash
# List all replication slots
docker exec -it postgres psql -U postgres -d testdb -c \
  "SELECT * FROM pg_replication_slots;"

# Drop and recreate slot if needed
docker exec -it postgres psql -U postgres -d testdb -c \
  "SELECT pg_drop_replication_slot('debezium_slot');"
```

### Reset connector offset

```bash
# Delete connector
curl -X DELETE http://localhost:8083/connectors/postgres-cdc-connector

# Clear offsets (requires recreating connector with new group.id)
# Or manually delete from docker-connect-offsets topic
```

## Cleanup

```bash
# Stop all services
docker-compose down

# Remove volumes (deletes all data)
docker-compose down -v

# Remove backup
rm -f testdb_backup.dump
```

## Important Considerations

### Replication Slot Management
- **Slot Growth**: The replication slot will accumulate WAL data if the connector is paused for extended periods
- **Disk Space**: Monitor PostgreSQL disk space during upgrades, especially with active replication slots
- **Retention**: WAL files are retained until consumed by all replication slots

### Database Upgrade Scenarios

#### Scenario 1: In-Place Upgrades (LSN Continuity Preserved)
- **Minor Version Upgrades** (e.g., 16.0 → 16.1): Generally safe with minimal downtime
- **Major Version Upgrades with pg_upgrade** (e.g., 16 → 17): LSN continuity maintained
- **Strategy**: Pause connector, upgrade, resume connector
- **Result**: No duplicates, no gap - connector resumes from stored offset
- **Use**: `connector-config.json` with standard settings

#### Scenario 2: PGbackrest Restore (LSN Continuity Lost)
- **CrunchyBridge upgrades**: Uses PGbackrest restore
- **Cross-region migrations**: Restore from backup to new instance
- **Disaster recovery**: Restore from point-in-time backup
- **Key Issue**: New LSN timeline makes old offsets invalid
- **Strategy**: Delete connector, restore database, recreate replication infrastructure, deploy with `snapshot.mode: never`
- **Result**: Zero duplicates, gap exists (acceptable tradeoff)
- **Use**: `connector-config-post-upgrade.json` and `post-upgrade-setup.sh`
- **See**: [CRUNCHYBRIDGE-UPGRADE.md](CRUNCHYBRIDGE-UPGRADE.md) for detailed guide

### Duplicate Prevention Strategies

**For applications that CANNOT handle duplicates:**
1. Use `snapshot.mode: never` after PGbackrest restore
2. Accept gap during upgrade window
3. Optionally: Manually backfill gap data if critical

**For applications that CAN handle duplicates (idempotent):**
1. Use `snapshot.mode: initial` after restore
2. Fresh baseline of all data
3. Longer startup time but no gap

### Offset Management Best Practices
- **Before Upgrade**: Always capture current LSN and connector offsets
- **During Upgrade**: Keep connector stopped (DELETE, not pause) for PGbackrest restores
- **After Upgrade**: Verify replication slot exists before deploying connector
- **Validation**: Check for data continuity by comparing message counts and verifying test transactions
- **For PGbackrest Restores**: Always recreate replication infrastructure manually

### Schema Changes
- The connector automatically handles most schema changes (ALTER TABLE, ADD COLUMN)
- Replica identity set to FULL captures all column changes (before/after values)
- For destructive changes (DROP TABLE), manually update connector configuration

### Production Recommendations
1. Test upgrade procedure in staging environment first
2. Schedule maintenance window for upgrade
3. Monitor connector lag metrics before and after upgrade
4. Have rollback plan ready (database backups, connector configuration)
5. Document LSN positions at each stage for troubleshooting
6. **For PGbackrest restores**: Use `./post-upgrade-setup.sh` to ensure proper infrastructure recreation
7. **For zero duplicates**: Always use `connector-config-post-upgrade.json` (with `snapshot.mode: never`) after PGbackrest restore
8. **Verify**: Run `./verify-no-duplicates.sh` after upgrade completes

## Quick Reference Guide

### For CrunchyBridge Users (or any PGbackrest restore)

**Step-by-step:**
1. **Before upgrade:** Delete connector (not pause)
   ```bash
   curl -X DELETE http://localhost:8083/connectors/postgres-cdc-connector
   ```

2. **CrunchyBridge performs upgrade** (database frozen, PGbackrest restore happens)

3. **After upgrade:** Recreate replication infrastructure
   ```bash
   ./post-upgrade-setup.sh
   ```

4. **Deploy connector with snapshot.mode: never** (prevents duplicates)
   ```bash
   curl -X POST http://localhost:8083/connectors \
     -H "Content-Type: application/json" \
     -d @connector-config-post-upgrade.json
   ```

5. **Verify zero duplicates**
   ```bash
   ./verify-no-duplicates.sh
   ```

**Key point:** Use `connector-config-post-upgrade.json` (NOT `connector-config.json`) to prevent duplicates!

### For Standard In-Place Upgrades

**Step-by-step:**
1. Pause connector
   ```bash
   curl -X PUT http://localhost:8083/connectors/postgres-cdc-connector/pause
   ```

2. Perform database upgrade (minor version or pg_upgrade)

3. Resume connector
   ```bash
   curl -X PUT http://localhost:8083/connectors/postgres-cdc-connector/resume
   ```

**Key point:** Replication slot preserved, connector resumes from stored offset automatically.
