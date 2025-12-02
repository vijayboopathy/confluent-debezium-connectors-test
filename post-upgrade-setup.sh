#!/bin/bash

# Post-upgrade setup script for CrunchyBridge database
# This script recreates the replication infrastructure after PGbackrest restore

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
echo "Post-Upgrade Setup Script"
echo "CrunchyBridge Database Upgrade"
echo "=========================================="
echo ""

# Configuration
DB_HOST="${DB_HOST:-postgres}"
DB_PORT="${DB_PORT:-5432}"
DB_USER="${DB_USER:-postgres}"
DB_NAME="${DB_NAME:-testdb}"
SLOT_NAME="debezium_slot"
PUBLICATION_NAME="debezium_publication"

print_info "Configuration:"
print_info "  Database Host: $DB_HOST"
print_info "  Database Port: $DB_PORT"
print_info "  Database Name: $DB_NAME"
print_info "  Replication Slot: $SLOT_NAME"
print_info "  Publication: $PUBLICATION_NAME"
echo ""

# Step 1: Verify database connectivity
print_step "Step 1: Verifying database connectivity..."
if docker exec postgres pg_isready -U "$DB_USER" -d "$DB_NAME" > /dev/null 2>&1; then
    print_info "✓ Database is ready"
else
    print_error "✗ Database is not ready. Please check connection settings."
    exit 1
fi
echo ""

# Step 2: Check if replication slot already exists
print_step "Step 2: Checking for existing replication slot..."
SLOT_EXISTS=$(docker exec postgres psql -U "$DB_USER" -d "$DB_NAME" -t -A -c \
  "SELECT COUNT(*) FROM pg_replication_slots WHERE slot_name = '$SLOT_NAME';")

if [ "$SLOT_EXISTS" -eq "1" ]; then
    print_warning "⚠ Replication slot '$SLOT_NAME' already exists"
    print_info "Dropping existing slot..."
    docker exec postgres psql -U "$DB_USER" -d "$DB_NAME" -c \
      "SELECT pg_drop_replication_slot('$SLOT_NAME');"
    print_info "✓ Existing slot dropped"
fi
echo ""

# Step 3: Create replication slot
print_step "Step 3: Creating replication slot '$SLOT_NAME'..."
docker exec postgres psql -U "$DB_USER" -d "$DB_NAME" -c \
  "SELECT * FROM pg_create_logical_replication_slot('$SLOT_NAME', 'pgoutput');"

# Verify creation
SLOT_EXISTS=$(docker exec postgres psql -U "$DB_USER" -d "$DB_NAME" -t -A -c \
  "SELECT COUNT(*) FROM pg_replication_slots WHERE slot_name = '$SLOT_NAME';")

if [ "$SLOT_EXISTS" -eq "1" ]; then
    print_info "✓ Replication slot created successfully"
    
    # Show slot details
    docker exec postgres psql -U "$DB_USER" -d "$DB_NAME" -c \
      "SELECT slot_name, plugin, slot_type, active, restart_lsn 
       FROM pg_replication_slots 
       WHERE slot_name = '$SLOT_NAME';"
else
    print_error "✗ Failed to create replication slot"
    exit 1
fi
echo ""

# Step 4: Check if publication already exists
print_step "Step 4: Checking for existing publication..."
PUB_EXISTS=$(docker exec postgres psql -U "$DB_USER" -d "$DB_NAME" -t -A -c \
  "SELECT COUNT(*) FROM pg_publication WHERE pubname = '$PUBLICATION_NAME';")

if [ "$PUB_EXISTS" -eq "1" ]; then
    print_warning "⚠ Publication '$PUBLICATION_NAME' already exists"
    print_info "Dropping existing publication..."
    docker exec postgres psql -U "$DB_USER" -d "$DB_NAME" -c \
      "DROP PUBLICATION $PUBLICATION_NAME;"
    print_info "✓ Existing publication dropped"
fi
echo ""

# Step 5: Create publication
print_step "Step 5: Creating publication '$PUBLICATION_NAME'..."
docker exec postgres psql -U "$DB_USER" -d "$DB_NAME" -c \
  "CREATE PUBLICATION $PUBLICATION_NAME FOR TABLE public.orders, public.customers;"

# Verify creation
PUB_EXISTS=$(docker exec postgres psql -U "$DB_USER" -d "$DB_NAME" -t -A -c \
  "SELECT COUNT(*) FROM pg_publication WHERE pubname = '$PUBLICATION_NAME';")

if [ "$PUB_EXISTS" -eq "1" ]; then
    print_info "✓ Publication created successfully"
    
    # Show publication details
    docker exec postgres psql -U "$DB_USER" -d "$DB_NAME" -c \
      "SELECT pubname, puballtables, pubinsert, pubupdate, pubdelete 
       FROM pg_publication 
       WHERE pubname = '$PUBLICATION_NAME';"
else
    print_error "✗ Failed to create publication"
    exit 1
fi
echo ""

# Step 6: Set replica identity for tables
print_step "Step 6: Setting replica identity for tables..."

# Set replica identity for orders table
docker exec postgres psql -U "$DB_USER" -d "$DB_NAME" -c \
  "ALTER TABLE public.orders REPLICA IDENTITY FULL;"
print_info "✓ Replica identity set for 'orders' table"

# Set replica identity for customers table
docker exec postgres psql -U "$DB_USER" -d "$DB_NAME" -c \
  "ALTER TABLE public.customers REPLICA IDENTITY FULL;"
print_info "✓ Replica identity set for 'customers' table"

# Verify replica identity
docker exec postgres psql -U "$DB_USER" -d "$DB_NAME" -c \
  "SELECT schemaname, tablename, relreplident 
   FROM pg_tables t 
   JOIN pg_class c ON t.tablename = c.relname 
   WHERE schemaname = 'public' 
   AND tablename IN ('orders', 'customers');"
echo ""

# Step 7: Verify setup
print_step "Step 7: Final verification..."

# Check replication slots
print_info "Replication slots:"
docker exec postgres psql -U "$DB_USER" -d "$DB_NAME" -c \
  "SELECT slot_name, plugin, active, restart_lsn 
   FROM pg_replication_slots;"

# Check publications
print_info "Publications:"
docker exec postgres psql -U "$DB_USER" -d "$DB_NAME" -c \
  "SELECT pubname FROM pg_publication;"

# Check WAL level
print_info "WAL configuration:"
docker exec postgres psql -U "$DB_USER" -d "$DB_NAME" -c \
  "SHOW wal_level;"

echo ""
print_info "=========================================="
print_info "✓ Post-upgrade setup completed successfully!"
print_info "=========================================="
print_info ""
print_info "Next steps:"
print_info "  1. Update connector config with new database hostname (if changed)"
print_info "  2. Deploy connector: curl -X POST http://localhost:8083/connectors -H 'Content-Type: application/json' -d @connector-config-post-upgrade.json"
print_info "  3. Verify connector status: curl http://localhost:8083/connectors/postgres-cdc-connector/status"
print_info "  4. Monitor connector logs: docker-compose logs -f kafka-connect"
print_info ""
