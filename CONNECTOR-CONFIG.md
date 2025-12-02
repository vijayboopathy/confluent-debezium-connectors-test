# Confluent PostgreSQL CDC Connector v2 Configuration

This document explains the key configuration options for the Confluent PostgreSQL CDC Source Connector v2.

## Connector Class

```json
"connector.class": "io.confluent.connect.cdc.postgres.PostgresCdcSourceConnector"
```

This is the Confluent-proprietary CDC connector (not Debezium).

## Key Configuration Options

### Database Connection
- `database.hostname`: PostgreSQL server hostname
- `database.port`: PostgreSQL server port (default: 5432)
- `database.user`: Database user with replication privileges
- `database.password`: Database password
- `database.dbname`: Target database name

### Replication Settings
- `slot.name`: Name of the PostgreSQL replication slot (e.g., `confluent_cdc_slot`)
- `publication.name`: Name of the PostgreSQL publication
- `publication.autocreate.mode`: Auto-create publication (`filtered` for specific tables)
- `slot.drop.on.stop`: Whether to drop the slot when connector stops (`false` recommended)

### Table Selection
- `table.include.list`: Comma-separated list of tables to capture (format: `schema.table`)
- Example: `public.orders,public.customers`

### Snapshot Behavior
- `snapshot.mode`: How to handle initial snapshot
  - `initial`: Take initial snapshot, then stream changes (recommended)
  - `never`: Only stream changes, no initial snapshot
  - `when_needed`: Snapshot if no offset exists

### Output Format
- `output.data.format`: Format for change event data
  - `AVRO`: Avro format with Schema Registry (recommended)
  - `JSON`: JSON format
  - `PROTOBUF`: Protocol Buffers format
- `output.key.format`: Format for message keys (typically same as data format)
- `after.state.only`: Only emit final state, not before/after (default: `true`)

### Schema Registry
- `schema.registry.url`: URL of Schema Registry (required for Avro/Protobuf)

### Delete Handling
- `delete.enabled`: Whether to capture DELETE operations (default: `true`)
- `tombstone.on.delete`: Emit tombstone (null value) for deletes (default: `true`)

### Performance Tuning
- `poll.interval.ms`: How often to poll for changes (default: 1000)
- `max.batch.size`: Maximum number of records per batch (default: 1000)
- `tasks.max`: Number of parallel tasks (default: 1)

### Heartbeat
- `heartbeat.interval.ms`: Interval for heartbeat messages (helps with offset management)

## Confluent CDC vs Debezium

### Confluent PostgreSQL CDC Connector
- **License**: Commercial (requires Confluent Platform subscription)
- **Connector Class**: `io.confluent.connect.cdc.postgres.PostgresCdcSourceConnector`
- **Features**:
  - Native Avro/Protobuf support with Schema Registry integration
  - Simplified configuration with `after.state.only`
  - Enterprise support from Confluent
  - Optimized for Confluent Platform

### Debezium PostgreSQL Connector
- **License**: Open source (Apache 2.0)
- **Connector Class**: `io.debezium.connector.postgresql.PostgresConnector`
- **Features**:
  - Rich change event structure (before/after, metadata)
  - SMT (Single Message Transforms) ecosystem
  - Community-driven, widely adopted
  - Works with any Kafka distribution

## Migration from Debezium to Confluent CDC

If migrating from Debezium to Confluent CDC:

1. **Different slot name**: Use a new replication slot to avoid conflicts
2. **Schema changes**: Output format differs (especially if using `after.state.only`)
3. **Consumer updates**: Consumers may need updates for different message format
4. **Configuration mapping**:
   - `database.server.name` → Similar functionality but different usage
   - `topic.prefix` → Same
   - `transforms` → May need replacement with Confluent features
   - `plugin.name` → Not needed (automatically uses pgoutput)

## Example Configuration

See `connector-config.json` in this repository for a complete working example.
