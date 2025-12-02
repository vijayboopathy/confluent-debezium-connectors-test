# Confluent CDC Connector Testing with PostgreSQL Database Upgrade

This project tests Confluent/Debezium CDC connector behavior during a PostgreSQL database upgrade, focusing on offset management and replication slot handling.

## Architecture

```
Data Generator Service → PostgreSQL (with logical replication) → Replication Slot → Debezium CDC Connector → Kafka
```

## Components

- **PostgreSQL 15**: Configured with logical replication (`wal_level=logical`)
- **Confluent Platform**: Kafka, Zookeeper, Schema Registry, Kafka Connect
- **Debezium PostgreSQL Connector**: CDC connector using pgoutput plugin
- **Data Generator**: Python service that continuously writes to PostgreSQL

## Prerequisites

- Docker and Docker Compose
- At least 4GB of available RAM
- Ports 5432, 9092, 8081, 8083 available

## Quick Start

1. **Start the stack**:
   ```bash
   docker-compose up -d
   ```

2. **Wait for all services to be healthy** (about 1-2 minutes):
   ```bash
   docker-compose ps
   ```

3. **Deploy the CDC connector**:
   ```bash
   curl -X POST http://localhost:8083/connectors \
     -H "Content-Type: application/json" \
     -d @connector-config.json
   ```

4. **Check connector status**:
   ```bash
   curl http://localhost:8083/connectors/postgres-cdc-connector/status
   ```

5. **Monitor CDC events**:
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

Option A - Upgrade PostgreSQL version in-place:
```bash
# Stop all services
docker-compose down

# Edit docker-compose.yml and change postgres image to postgres:16
# Then restart
docker-compose up -d postgres
```

Option B - Create new database instance:
```bash
# Start new postgres instance (on different port)
docker run -d --name postgres-new \
  -e POSTGRES_USER=postgres \
  -e POSTGRES_PASSWORD=postgres \
  -e POSTGRES_DB=testdb \
  -p 5433:5432 \
  postgres:16 \
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

## Key Configuration Files

- `docker-compose.yml`: Complete stack definition
- `connector-config.json`: Debezium connector configuration
- `init-db.sql`: Database initialization script
- `data-generator/generator.py`: Data generation service

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

## Notes

- The replication slot will grow if the connector is paused for extended periods
- Monitor disk space on PostgreSQL during upgrades
- The connector automatically handles schema changes in most cases
- For major version upgrades, test thoroughly in a non-production environment first
