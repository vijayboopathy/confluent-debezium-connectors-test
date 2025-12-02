#!/bin/bash

# Script to test offset resume after database upgrade

set -e

echo "==================================="
echo "CDC Offset Resume Test Script"
echo "==================================="

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored output
print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Step 1: Check current state
print_info "Step 1: Checking current connector state..."
sleep 2

CONNECTOR_STATUS=$(curl -s http://localhost:8083/connectors/postgres-cdc-connector/status | jq -r '.connector.state')
print_info "Connector status: $CONNECTOR_STATUS"

# Get current LSN
print_info "Capturing current LSN..."
CURRENT_LSN=$(docker exec postgres psql -U postgres -d testdb -t -c \
  "SELECT confirmed_flush_lsn FROM pg_replication_slots WHERE slot_name = 'confluent_cdc_slot';" | tr -d ' ')
print_info "Current LSN: $CURRENT_LSN"

# Get current offset
print_info "Capturing current offset..."
curl -s http://localhost:8083/connectors/postgres-cdc-connector/offsets > current_offset.json
print_info "Offset saved to current_offset.json"

# Count messages in orders topic
print_info "Counting messages in orders topic..."
INITIAL_COUNT=$(docker exec kafka kafka-run-class kafka.tools.GetOffsetShell \
  --broker-list localhost:9092 \
  --topic cdc.public.orders \
  --time -1 | awk -F':' '{sum += $3} END {print sum}')
print_info "Initial message count: $INITIAL_COUNT"

# Step 2: Pause connector
print_info "\nStep 2: Pausing connector..."
curl -X PUT http://localhost:8083/connectors/postgres-cdc-connector/pause
sleep 2
print_info "Connector paused"

# Step 3: Stop data generator
print_info "\nStep 3: Stopping data generator..."
docker-compose stop data-generator
print_info "Data generator stopped"

# Step 4: Insert some test data manually
print_info "\nStep 4: Inserting test data during downtime..."
docker exec postgres psql -U postgres -d testdb -c \
  "INSERT INTO orders (customer_id, order_date, total_amount, status) 
   VALUES (1, NOW(), 999.99, 'test_order_during_upgrade');"
print_info "Test data inserted"

# Step 5: Backup database
print_info "\nStep 5: Creating database backup..."
docker exec postgres pg_dump -U postgres -d testdb -F c -f /tmp/testdb_backup.dump
docker cp postgres:/tmp/testdb_backup.dump ./testdb_backup_test.dump
print_info "Backup created: testdb_backup_test.dump"

# Step 6: Save replication slot info
print_info "\nStep 6: Saving replication slot information..."
docker exec postgres psql -U postgres -d testdb -c \
  "SELECT * FROM pg_replication_slots WHERE slot_name = 'confluent_cdc_slot';" \
  > replication_slot_before.txt
print_info "Replication slot info saved to replication_slot_before.txt"

# Step 7: Simulate upgrade by restarting postgres
print_info "\nStep 7: Simulating database upgrade (restarting PostgreSQL)..."
docker-compose restart postgres

print_info "Waiting for PostgreSQL to be ready..."
sleep 10

until docker exec postgres pg_isready -U postgres > /dev/null 2>&1; do
  echo -n "."
  sleep 2
done
echo ""
print_info "PostgreSQL is ready"

# Step 8: Verify replication slot survived restart
print_info "\nStep 8: Verifying replication slot..."
SLOT_EXISTS=$(docker exec postgres psql -U postgres -d testdb -t -c \
  "SELECT COUNT(*) FROM pg_replication_slots WHERE slot_name = 'confluent_cdc_slot';" | tr -d ' ')

if [ "$SLOT_EXISTS" -eq "1" ]; then
    print_info "Replication slot exists: ✓"
else
    print_warning "Replication slot missing! Recreating..."
    docker exec postgres psql -U postgres -d testdb -c \
      "SELECT * FROM pg_create_logical_replication_slot('confluent_cdc_slot', 'pgoutput');"
fi

# Step 9: Resume connector
print_info "\nStep 9: Resuming connector..."
curl -X PUT http://localhost:8083/connectors/postgres-cdc-connector/resume
sleep 5

CONNECTOR_STATUS=$(curl -s http://localhost:8083/connectors/postgres-cdc-connector/status | jq -r '.connector.state')
print_info "Connector status: $CONNECTOR_STATUS"

# Step 10: Restart data generator
print_info "\nStep 10: Restarting data generator..."
docker-compose start data-generator
sleep 5
print_info "Data generator restarted"

# Step 11: Verify messages are flowing
print_info "\nStep 11: Verifying CDC is working..."
sleep 10

FINAL_COUNT=$(docker exec kafka kafka-run-class kafka.tools.GetOffsetShell \
  --broker-list localhost:9092 \
  --topic cdc.public.orders \
  --time -1 | awk -F':' '{sum += $3} END {print sum}')

print_info "Initial message count: $INITIAL_COUNT"
print_info "Final message count: $FINAL_COUNT"

if [ "$FINAL_COUNT" -gt "$INITIAL_COUNT" ]; then
    print_info "✓ New messages detected! CDC is working correctly."
else
    print_warning "⚠ No new messages detected. Check connector logs."
fi

# Step 12: Check for the test order
print_info "\nStep 12: Checking if test order was captured..."
docker exec kafka kafka-console-consumer \
  --bootstrap-server localhost:9092 \
  --topic cdc.public.orders \
  --from-beginning \
  --max-messages 1000 \
  --timeout-ms 5000 2>/dev/null | grep -q "test_order_during_upgrade" && \
    print_info "✓ Test order found in Kafka!" || \
    print_warning "⚠ Test order not found. May need more time to process."

# Summary
print_info "\n==================================="
print_info "Test Complete!"
print_info "==================================="
print_info "Review the following files:"
print_info "  - current_offset.json"
print_info "  - replication_slot_before.txt"
print_info "  - testdb_backup_test.dump"
print_info "\nMonitor with:"
print_info "  docker-compose logs -f kafka-connect"
print_info "  docker-compose logs -f data-generator"
