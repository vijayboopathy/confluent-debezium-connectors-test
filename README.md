# Debezium PostgreSQL CDC Connector Testing with Database Upgrade

This project tests the Debezium PostgreSQL CDC connector behavior during a PostgreSQL database upgrade, focusing on offset management and replication slot handling.

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
   ```bash
   curl -X POST http://localhost:8083/connectors \
     -H "Content-Type: application/json" \
     -d @connector-config.json
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

## Testing Database Upgrade with Offset Resume

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

For automated testing of the upgrade scenario, use the provided test script:

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

## Key Configuration Files

- `docker-compose.yml`: Complete stack definition with PostgreSQL 16
- `Dockerfile.connect`: Custom Kafka Connect image with Debezium pre-installed
- `connector-config.json`: Debezium connector configuration
- `init-db.sql`: Database initialization script
- `data-generator/generator.py`: Data generation service
- `test-upgrade.sh`: Automated upgrade testing script

## Troubleshooting

### Connector not starting

```bash
# Check connector logs
docker-compose logs kafka-connect

# Verify PostgreSQL is accessible
docker exec -it kafka-connect ping postgres
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
- **Minor Version Upgrades** (e.g., 16.0 → 16.1): Generally safe with minimal downtime
- **Major Version Upgrades** (e.g., 16 → 17): Requires more careful planning:
  - Test thoroughly in non-production environment
  - Verify Debezium connector compatibility with new PostgreSQL version
  - Check for breaking changes in logical replication protocol
  - Consider using `pg_upgrade` for in-place upgrades

### Offset Management Best Practices
- **Before Upgrade**: Always capture current LSN and connector offsets
- **During Upgrade**: Keep connector paused to prevent connection errors
- **After Upgrade**: Verify replication slot exists before resuming connector
- **Validation**: Check for data continuity by comparing message counts and verifying test transactions

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
6. Consider blue-green deployment for zero-downtime upgrades
