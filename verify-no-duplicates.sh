#!/bin/bash

# Script to verify no duplicate events in Kafka after database upgrade
# Checks message uniqueness based on primary keys

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
echo "Duplicate Detection Verification"
echo "=========================================="
echo ""

# Configuration
KAFKA_TOPIC="${KAFKA_TOPIC:-cdc.public.orders}"
MAX_MESSAGES="${MAX_MESSAGES:-10000}"
TEMP_FILE="/tmp/kafka_messages_$$.json"

print_info "Configuration:"
print_info "  Kafka Topic: $KAFKA_TOPIC"
print_info "  Max Messages: $MAX_MESSAGES"
echo ""

# Step 1: Consume messages from Kafka
print_step "Step 1: Consuming messages from Kafka..."

docker exec kafka kafka-console-consumer \
  --bootstrap-server localhost:9092 \
  --topic $KAFKA_TOPIC \
  --from-beginning \
  --max-messages $MAX_MESSAGES \
  --timeout-ms 10000 2>/dev/null > $TEMP_FILE || true

MESSAGE_COUNT=$(wc -l < $TEMP_FILE | tr -d ' ')
print_info "✓ Consumed $MESSAGE_COUNT messages from Kafka"

if [ "$MESSAGE_COUNT" -eq "0" ]; then
    print_warning "⚠ No messages found in topic. Verify CDC is working."
    rm -f $TEMP_FILE
    exit 0
fi

echo ""

# Step 2: Extract primary keys and check for duplicates
print_step "Step 2: Checking for duplicate primary keys..."

# Extract IDs from JSON messages (assuming 'id' field exists)
cat $TEMP_FILE | jq -r 'select(.id != null) | .id' 2>/dev/null > /tmp/ids_$$.txt || true

TOTAL_IDS=$(wc -l < /tmp/ids_$$.txt | tr -d ' ')
UNIQUE_IDS=$(sort -u /tmp/ids_$$.txt | wc -l | tr -d ' ')

print_info "Total IDs found: $TOTAL_IDS"
print_info "Unique IDs:      $UNIQUE_IDS"

if [ "$TOTAL_IDS" -eq "$UNIQUE_IDS" ]; then
    print_info "✓ NO DUPLICATES FOUND: All IDs are unique"
    DUPLICATE_COUNT=0
else
    DUPLICATE_COUNT=$((TOTAL_IDS - UNIQUE_IDS))
    print_warning "⚠ DUPLICATES DETECTED: $DUPLICATE_COUNT duplicate IDs found"
    
    # Show which IDs are duplicated
    print_info ""
    print_info "Duplicate IDs:"
    sort /tmp/ids_$$.txt | uniq -d | head -20
    
    if [ "$DUPLICATE_COUNT" -gt "20" ]; then
        print_info "... (showing first 20 duplicates)"
    fi
fi

echo ""

# Step 3: Check for duplicate LSN positions
print_step "Step 3: Checking for duplicate LSN positions..."

# Extract LSN values from messages
cat $TEMP_FILE | jq -r 'select(.lsn != null) | .lsn' 2>/dev/null > /tmp/lsns_$$.txt || true

TOTAL_LSNS=$(wc -l < /tmp/lsns_$$.txt | tr -d ' ')
UNIQUE_LSNS=$(sort -u /tmp/lsns_$$.txt | wc -l | tr -d ' ')

if [ "$TOTAL_LSNS" -gt "0" ]; then
    print_info "Total LSNs found: $TOTAL_LSNS"
    print_info "Unique LSNs:      $UNIQUE_LSNS"
    
    if [ "$TOTAL_LSNS" -eq "$UNIQUE_LSNS" ]; then
        print_info "✓ NO DUPLICATE LSNS: All LSN positions are unique"
    else
        LSN_DUPLICATE_COUNT=$((TOTAL_LSNS - UNIQUE_LSNS))
        print_warning "⚠ DUPLICATE LSNS: $LSN_DUPLICATE_COUNT duplicate LSN positions found"
    fi
else
    print_info "LSN information not available in messages"
fi

echo ""

# Step 4: Check for timestamp ordering
print_step "Step 4: Checking timestamp ordering..."

# Extract timestamps
cat $TEMP_FILE | jq -r 'select(.ts_ms != null) | .ts_ms' 2>/dev/null > /tmp/timestamps_$$.txt || true

TIMESTAMP_COUNT=$(wc -l < /tmp/timestamps_$$.txt | tr -d ' ')

if [ "$TIMESTAMP_COUNT" -gt "0" ]; then
    # Check if timestamps are monotonically increasing (roughly)
    FIRST_TS=$(head -1 /tmp/timestamps_$$.txt)
    LAST_TS=$(tail -1 /tmp/timestamps_$$.txt)
    
    print_info "First timestamp: $FIRST_TS ($(date -r $((FIRST_TS / 1000)) 2>/dev/null || echo 'N/A'))"
    print_info "Last timestamp:  $LAST_TS ($(date -r $((LAST_TS / 1000)) 2>/dev/null || echo 'N/A'))"
    
    if [ "$LAST_TS" -ge "$FIRST_TS" ]; then
        print_info "✓ Timestamps are ordered (first <= last)"
    else
        print_warning "⚠ Timestamps out of order"
    fi
else
    print_info "Timestamp information not available in messages"
fi

echo ""

# Step 5: Check operation types
print_step "Step 5: Analyzing operation types..."

# Extract operation types (c=create, u=update, d=delete)
cat $TEMP_FILE | jq -r 'select(.op != null) | .op' 2>/dev/null > /tmp/ops_$$.txt || true

if [ -s /tmp/ops_$$.txt ]; then
    CREATE_COUNT=$(grep -c "^c$" /tmp/ops_$$.txt 2>/dev/null || echo "0")
    UPDATE_COUNT=$(grep -c "^u$" /tmp/ops_$$.txt 2>/dev/null || echo "0")
    DELETE_COUNT=$(grep -c "^d$" /tmp/ops_$$.txt 2>/dev/null || echo "0")
    READ_COUNT=$(grep -c "^r$" /tmp/ops_$$.txt 2>/dev/null || echo "0")
    
    print_info "Operation breakdown:"
    print_info "  Creates (c): $CREATE_COUNT"
    print_info "  Updates (u): $UPDATE_COUNT"
    print_info "  Deletes (d): $DELETE_COUNT"
    print_info "  Reads (r):   $READ_COUNT (from snapshot)"
    
    if [ "$READ_COUNT" -gt "0" ]; then
        print_warning "⚠ Snapshot reads detected. If using snapshot.mode: never, this is unexpected."
    else
        print_info "✓ No snapshot reads (consistent with snapshot.mode: never)"
    fi
else
    print_info "Operation information not available in messages"
fi

echo ""

# Step 6: Compare with database
print_step "Step 6: Comparing Kafka message count with database row count..."

DB_ROW_COUNT=$(docker exec postgres psql -U postgres -d testdb -t -A -c \
  "SELECT COUNT(*) FROM orders;" 2>/dev/null || echo "N/A")

print_info "Database rows:   $DB_ROW_COUNT"
print_info "Kafka messages:  $MESSAGE_COUNT"

if [ "$DB_ROW_COUNT" != "N/A" ]; then
    DIFF=$((DB_ROW_COUNT - MESSAGE_COUNT))
    
    if [ "$DIFF" -eq "0" ]; then
        print_warning "⚠ Database and Kafka have same count. If using snapshot.mode: never, there should be a gap."
    elif [ "$DIFF" -gt "0" ]; then
        print_info "✓ Gap detected: $DIFF records in database but not in Kafka (expected with snapshot.mode: never)"
    else
        print_error "✗ More messages in Kafka than database? ($DIFF difference)"
    fi
fi

echo ""

# Summary
print_step "=========================================="
print_info "Verification Summary"
print_step "=========================================="
print_info ""

if [ "$DUPLICATE_COUNT" -eq "0" ]; then
    print_info "✓ PASS: No duplicate primary keys detected"
else
    print_error "✗ FAIL: $DUPLICATE_COUNT duplicate primary keys found"
fi

if [ "$READ_COUNT" -eq "0" ] || [ -z "$READ_COUNT" ]; then
    print_info "✓ PASS: No snapshot reads (consistent with snapshot.mode: never)"
else
    print_warning "⚠ WARNING: $READ_COUNT snapshot reads detected"
fi

if [ "$DB_ROW_COUNT" != "N/A" ] && [ "$DIFF" -gt "0" ]; then
    print_info "✓ PASS: Gap exists between database and Kafka ($DIFF records)"
else
    print_info "Note: Gap verification inconclusive"
fi

echo ""

# Cleanup
rm -f $TEMP_FILE /tmp/ids_$$.txt /tmp/lsns_$$.txt /tmp/timestamps_$$.txt /tmp/ops_$$.txt

if [ "$DUPLICATE_COUNT" -eq "0" ]; then
    print_info "=========================================="
    print_info "✓ VERIFICATION PASSED"
    print_info "=========================================="
    exit 0
else
    print_error "=========================================="
    print_error "✗ VERIFICATION FAILED"
    print_error "=========================================="
    exit 1
fi
