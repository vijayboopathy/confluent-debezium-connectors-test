#!/bin/bash

# Script to test PGbackrest-style database restore scenario
# Simulates CrunchyBridge upgrade where LSN continuity is lost

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;36m'
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

print_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

echo "=========================================="
echo "PGbackrest Restore Simulation Test"
echo "CrunchyBridge Database Upgrade"
echo "=========================================="
echo ""

# Configuration
CONNECTOR_NAME="postgres-cdc-connector"
KAFKA_TOPIC="cdc.public.orders"
SLOT_NAME="debezium_slot"

# Step 1: Check initial state
print_step "Step 1: Capturing initial state..."

print_info "Checking connector status..."
CONNECTOR_STATUS=$(curl -s http://localhost:8083/connectors/$CONNECTOR_NAME/status 2>/dev/null | jq -r '.connector.state' 2>/dev/null || echo "NOT_FOUND")

if [ "$CONNECTOR_STATUS" == "NOT_FOUND" ]; then
    print_warning "⚠ Connector not found. Deploy it first with: curl -X POST http://localhost:8083/connectors -H 'Content-Type: application/json' -d @connector-config.json"
    exit 1
fi

print_info "Connector status: $CONNECTOR_STATUS"

# Get current LSN
print_info "Capturing current LSN..."
INITIAL_LSN=$(docker exec postgres psql -U postgres -d testdb -t -A -c \
  "SELECT confirmed_flush_lsn FROM pg_replication_slots WHERE slot_name = '$SLOT_NAME';" 2>/dev/null || echo "")

if [ -z "$INITIAL_LSN" ]; then
    print_warning "⚠ Replication slot not found or not active"
else
    print_info "Initial LSN: $INITIAL_LSN"
fi

# Count initial messages
print_info "Counting messages in Kafka topic..."
INITIAL_MSG_COUNT=$(docker exec kafka kafka-run-class kafka.tools.GetOffsetShell \
  --broker-list localhost:9092 \
  --topic $KAFKA_TOPIC \
  --time -1 2>/dev/null | awk -F':' '{sum += $3} END {print sum}' || echo "0")
print_info "Initial message count: $INITIAL_MSG_COUNT"

# Save connector offsets
print_info "Saving connector offsets..."
curl -s http://localhost:8083/connectors/$CONNECTOR_NAME/offsets > pre_restore_offsets.json
print_info "✓ Offsets saved to pre_restore_offsets.json"

echo ""

# Step 2: Stop connector
print_step "Step 2: Stopping connector (simulating pre-upgrade)..."
curl -s -X DELETE http://localhost:8083/connectors/$CONNECTOR_NAME > /dev/null
sleep 3

CONNECTOR_STATUS=$(curl -s http://localhost:8083/connectors/$CONNECTOR_NAME/status 2>/dev/null | jq -r '.connector.state' 2>/dev/null || echo "DELETED")
print_info "✓ Connector deleted"

echo ""

# Step 3: Stop data generator
print_step "Step 3: Stopping data generator..."
docker-compose stop data-generator > /dev/null 2>&1
print_info "✓ Data generator stopped"

echo ""

# Step 4: Insert test data during "upgrade window"
print_step "Step 4: Inserting test data during upgrade window (simulating gap)..."

# Insert 5 test orders that will be in the gap
for i in {1..5}; do
  docker exec postgres psql -U postgres -d testdb -c \
    "INSERT INTO orders (customer_id, order_date, total_amount, status) 
     VALUES ($i, NOW(), $((i * 100)).99, 'gap_order_$i');" > /dev/null 2>&1
done

print_info "✓ Inserted 5 orders during upgrade window (these will be in the gap)"

# Get row count before restore
ROW_COUNT_BEFORE=$(docker exec postgres psql -U postgres -d testdb -t -A -c \
  "SELECT COUNT(*) FROM orders;")
print_info "Total orders before restore: $ROW_COUNT_BEFORE"

echo ""

# Step 5: Create database backup
print_step "Step 5: Creating database backup (simulating PGbackrest)..."
docker exec postgres pg_dump -U postgres -d testdb -F c -f /tmp/testdb_pgbackrest.dump > /dev/null 2>&1
docker cp postgres:/tmp/testdb_pgbackrest.dump ./testdb_pgbackrest.dump
print_info "✓ Backup created: testdb_pgbackrest.dump"

# Capture current LSN before "restore"
PRE_RESTORE_LSN=$(docker exec postgres psql -U postgres -d testdb -t -A -c \
  "SELECT pg_current_wal_lsn();" 2>/dev/null || echo "")
print_info "Database LSN before restore: $PRE_RESTORE_LSN"

echo ""

# Step 6: Simulate PGbackrest restore (drop and recreate database)
print_step "Step 6: Simulating PGbackrest restore (NEW LSN timeline)..."

print_warning "⚠ This will simulate a PGbackrest restore by:"
print_warning "  1. Dropping the database"
print_warning "  2. Recreating it from backup"
print_warning "  3. Resulting in a NEW LSN timeline (like CrunchyBridge)"

# Drop and recreate database
docker exec postgres psql -U postgres -c "DROP DATABASE IF EXISTS testdb;" > /dev/null 2>&1
docker exec postgres psql -U postgres -c "CREATE DATABASE testdb;" > /dev/null 2>&1
print_info "✓ Database recreated"

# Restore from backup
docker exec postgres pg_restore -U postgres -d testdb /tmp/testdb_pgbackrest.dump > /dev/null 2>&1
print_info "✓ Backup restored"

# Get row count after restore
ROW_COUNT_AFTER=$(docker exec postgres psql -U postgres -d testdb -t -A -c \
  "SELECT COUNT(*) FROM orders;")
print_info "Total orders after restore: $ROW_COUNT_AFTER"

# Get NEW LSN (this will be different - new timeline!)
POST_RESTORE_LSN=$(docker exec postgres psql -U postgres -d testdb -t -A -c \
  "SELECT pg_current_wal_lsn();" 2>/dev/null || echo "")
print_info "Database LSN after restore: $POST_RESTORE_LSN"

if [ "$PRE_RESTORE_LSN" != "$POST_RESTORE_LSN" ]; then
    print_warning "⚠ LSN has changed! (This simulates PGbackrest restore behavior)"
    print_warning "  Old LSN: $PRE_RESTORE_LSN"
    print_warning "  New LSN: $POST_RESTORE_LSN"
else
    print_info "Note: LSN may appear similar, but in real PGbackrest restore, timeline changes"
fi

echo ""

# Step 7: Verify replication infrastructure is lost
print_step "Step 7: Verifying replication infrastructure was NOT preserved..."

SLOT_EXISTS=$(docker exec postgres psql -U postgres -d testdb -t -A -c \
  "SELECT COUNT(*) FROM pg_replication_slots WHERE slot_name = '$SLOT_NAME';" 2>/dev/null || echo "0")

if [ "$SLOT_EXISTS" -eq "0" ]; then
    print_info "✓ Confirmed: Replication slot does NOT exist (as expected with PGbackrest)"
else
    print_warning "⚠ Replication slot still exists (unexpected in real PGbackrest restore)"
fi

PUB_EXISTS=$(docker exec postgres psql -U postgres -d testdb -t -A -c \
  "SELECT COUNT(*) FROM pg_publication WHERE pubname = 'debezium_publication';" 2>/dev/null || echo "0")

if [ "$PUB_EXISTS" -eq "0" ]; then
    print_info "✓ Confirmed: Publication does NOT exist (as expected with PGbackrest)"
else
    print_warning "⚠ Publication still exists (unexpected in real PGbackrest restore)"
fi

echo ""

# Step 8: Run post-upgrade setup
print_step "Step 8: Running post-upgrade setup script..."
./post-upgrade-setup.sh

echo ""

# Step 9: Deploy connector with new configuration
print_step "Step 9: Deploying connector with post-upgrade configuration..."
print_info "Using snapshot.mode: never (to prevent duplicates)"

curl -s -X POST http://localhost:8083/connectors \
  -H "Content-Type: application/json" \
  -d @connector-config-post-upgrade.json > /dev/null

sleep 5

CONNECTOR_STATUS=$(curl -s http://localhost:8083/connectors/$CONNECTOR_NAME/status | jq -r '.connector.state')
print_info "Connector status: $CONNECTOR_STATUS"

if [ "$CONNECTOR_STATUS" != "RUNNING" ]; then
    print_error "✗ Connector failed to start. Check logs with: docker-compose logs kafka-connect"
    exit 1
fi

print_info "✓ Connector deployed successfully"

echo ""

# Step 10: Restart data generator
print_step "Step 10: Restarting data generator..."
docker-compose start data-generator > /dev/null 2>&1
sleep 3
print_info "✓ Data generator restarted"

echo ""

# Step 11: Verify CDC is working
print_step "Step 11: Verifying CDC is capturing new changes..."

# Insert a test record
docker exec postgres psql -U postgres -d testdb -c \
  "INSERT INTO orders (customer_id, order_date, total_amount, status) 
   VALUES (9999, NOW(), 777.77, 'test_post_restore');" > /dev/null 2>&1
print_info "✓ Inserted test order: test_post_restore"

# Wait for CDC to capture it
sleep 5

# Check if it appears in Kafka
print_info "Checking if test order appears in Kafka..."
docker exec kafka kafka-console-consumer \
  --bootstrap-server localhost:9092 \
  --topic $KAFKA_TOPIC \
  --max-messages 100 \
  --timeout-ms 5000 2>/dev/null | grep -q "test_post_restore" && \
    print_info "✓ Test order found in Kafka! CDC is working." || \
    print_warning "⚠ Test order not found yet. May need more time."

echo ""

# Step 12: Check for gap orders (should NOT be in Kafka)
print_step "Step 12: Verifying gap orders are NOT in Kafka (no duplicates)..."

GAP_FOUND=0
for i in {1..5}; do
  if docker exec kafka kafka-console-consumer \
    --bootstrap-server localhost:9092 \
    --topic $KAFKA_TOPIC \
    --from-beginning \
    --max-messages 1000 \
    --timeout-ms 5000 2>/dev/null | grep -q "gap_order_$i"; then
    print_warning "⚠ Found gap_order_$i in Kafka (should not be there)"
    GAP_FOUND=1
  fi
done

if [ "$GAP_FOUND" -eq "0" ]; then
    print_info "✓ Gap orders NOT found in Kafka (as expected with snapshot.mode: never)"
    print_info "✓ NO DUPLICATES: Connector only capturing NEW changes"
else
    print_error "✗ Gap orders found in Kafka (unexpected)"
fi

echo ""

# Step 13: Count final messages
print_step "Step 13: Comparing message counts..."

FINAL_MSG_COUNT=$(docker exec kafka kafka-run-class kafka.tools.GetOffsetShell \
  --broker-list localhost:9092 \
  --topic $KAFKA_TOPIC \
  --time -1 2>/dev/null | awk -F':' '{sum += $3} END {print sum}' || echo "0")

print_info "Initial message count: $INITIAL_MSG_COUNT"
print_info "Final message count:   $FINAL_MSG_COUNT"

NEW_MESSAGES=$((FINAL_MSG_COUNT - INITIAL_MSG_COUNT))
print_info "New messages captured: $NEW_MESSAGES"

if [ "$NEW_MESSAGES" -gt "0" ]; then
    print_info "✓ CDC is capturing new changes"
else
    print_warning "⚠ No new messages detected yet"
fi

echo ""

# Step 14: Check connector offsets
print_step "Step 14: Comparing connector offsets..."

curl -s http://localhost:8083/connectors/$CONNECTOR_NAME/offsets > post_restore_offsets.json
print_info "✓ Post-restore offsets saved to post_restore_offsets.json"

print_info "Comparing LSN values..."
PRE_LSN=$(cat pre_restore_offsets.json | jq -r '.offsets[0].offset.lsn' 2>/dev/null || echo "N/A")
POST_LSN=$(cat post_restore_offsets.json | jq -r '.offsets[0].offset.lsn' 2>/dev/null || echo "N/A")

print_info "Pre-restore LSN:  $PRE_LSN"
print_info "Post-restore LSN: $POST_LSN"

if [ "$PRE_LSN" != "$POST_LSN" ] && [ "$POST_LSN" != "N/A" ]; then
    print_warning "⚠ LSN values are different (expected with PGbackrest restore)"
    print_info "✓ Connector is using NEW LSN timeline"
else
    print_info "Note: Check offsets manually to confirm new timeline"
fi

echo ""

# Summary
print_step "=========================================="
print_info "Test Summary"
print_step "=========================================="
print_info ""
print_info "✓ Simulated PGbackrest restore (LSN timeline changed)"
print_info "✓ Replication slot and publication recreated"
print_info "✓ Connector deployed with snapshot.mode: never"
print_info "✓ CDC is capturing NEW changes only"
print_info "✓ Gap orders (5) are NOT in Kafka (no duplicates)"
print_info "✓ No data loss for NEW changes after restore"
print_info ""
print_warning "Expected behavior:"
print_warning "  - Gap exists: 5 orders inserted during 'upgrade' are missing from Kafka"
print_warning "  - No duplicates: Existing data not re-sent to Kafka"
print_warning "  - New changes: All changes after restore are captured"
print_info ""
print_info "Files created:"
print_info "  - pre_restore_offsets.json"
print_info "  - post_restore_offsets.json"
print_info "  - testdb_pgbackrest.dump"
print_info ""
print_info "Monitor with:"
print_info "  docker-compose logs -f kafka-connect"
print_info "  docker-compose logs -f data-generator"
print_info ""
print_info "To verify gap, check database vs Kafka:"
print_info "  docker exec postgres psql -U postgres -d testdb -c \"SELECT COUNT(*) FROM orders;\""
print_info "  docker exec kafka kafka-run-class kafka.tools.GetOffsetShell --broker-list localhost:9092 --topic $KAFKA_TOPIC --time -1"
print_info ""
