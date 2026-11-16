#!/bin/bash

# Migration script from regular postgres container to pgbouncer+postgres setup
# This script prepares the existing postgres database for pgbouncer integration

set -e  # Exit on error

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Step 1: Ask for backup confirmation
echo ""
print_warning "=========================================="
print_warning "PgBouncer Migration Script"
print_warning "=========================================="
echo ""
print_warning "IMPORTANT: This script will modify your PostgreSQL database."
print_warning "It will create the pgbouncer user and set up required functions."
echo ""
read -p "Have you backed up your databases? (yes/no) [no]: " backup_confirmed

if [[ ! "$backup_confirmed" =~ ^[Yy][Ee][Ss]$ ]]; then
    print_error "Backup confirmation required. Exiting."
    exit 1
fi

print_success "Backup confirmation received. Proceeding with migration..."
echo ""

# Step 2: Read .env file if present
PREFIX=""
if [ -f "$REPO_ROOT/.env" ]; then
    print_info "Reading .env file..."
    
    # Source the .env file to get variables (suppress errors if file has issues)
    set -a
    if ! source "$REPO_ROOT/.env" 2>/dev/null; then
        print_warning "Warning: Could not fully parse .env file, continuing with available variables"
    fi
    set +a
    
    # Check if COMPOSE_PROJECT_NAME and CONTAINER_PREFIX are set
    if [ -n "$COMPOSE_PROJECT_NAME" ] && [ -n "$CONTAINER_PREFIX" ]; then
        if [ "$COMPOSE_PROJECT_NAME" != "$CONTAINER_PREFIX" ]; then
            print_error "COMPOSE_PROJECT_NAME ($COMPOSE_PROJECT_NAME) and CONTAINER_PREFIX ($CONTAINER_PREFIX) do not match!"
            exit 1
        fi
        PREFIX="$CONTAINER_PREFIX"
        print_success "Found matching COMPOSE_PROJECT_NAME and CONTAINER_PREFIX: '$PREFIX'"
    elif [ -n "$COMPOSE_PROJECT_NAME" ]; then
        PREFIX="$COMPOSE_PROJECT_NAME"
        print_info "Using COMPOSE_PROJECT_NAME as prefix: '$PREFIX'"
    elif [ -n "$CONTAINER_PREFIX" ]; then
        PREFIX="$CONTAINER_PREFIX"
        print_info "Using CONTAINER_PREFIX as prefix: '$PREFIX'"
    else
        print_info "No COMPOSE_PROJECT_NAME or CONTAINER_PREFIX found in .env, using empty prefix"
    fi
else
    print_info ".env file not found, using empty prefix"
fi

# Show PREFIX and ask for confirmation
echo ""
if [ -z "$PREFIX" ]; then
    print_info "Container prefix determined: (empty - no prefix)"
else
    print_info "Container prefix determined: '$PREFIX'"
fi
echo ""
read -p "Is this prefix correct? (yes/no) [yes]: " prefix_correct

# Default to yes if empty
if [ -z "$prefix_correct" ]; then
    prefix_correct="yes"
fi

if [[ ! "$prefix_correct" =~ ^[Yy][Ee][Ss]$ ]]; then
    print_info "Please enter the correct container prefix:"
    read -p "Prefix (leave empty for no prefix): " PREFIX
    
    # Trim whitespace
    PREFIX=$(echo "$PREFIX" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
    
    if [ -z "$PREFIX" ]; then
        print_info "Using empty prefix (no prefix will be used)"
    else
        print_success "Using manually entered prefix: '$PREFIX'"
    fi
else
    if [ -z "$PREFIX" ]; then
        print_success "Using empty prefix (no prefix will be used)"
    else
        print_success "Using prefix: '$PREFIX'"
    fi
fi
echo ""

# Step 3: Prompt for postgres credentials
print_info "Please enter PostgreSQL credentials to connect to the existing database:"
read -p "Username: " POSTGRES_USER
read -sp "Password: " POSTGRES_PASSWORD
echo ""

if [ -z "$POSTGRES_USER" ] || [ -z "$POSTGRES_PASSWORD" ]; then
    print_error "Username and password cannot be empty. Exiting."
    exit 1
fi

print_success "PostgreSQL credentials received."
echo ""

# Step 4: Prompt for pgbouncer credentials
print_info "Please enter PgBouncer user credentials (leave empty for defaults):"
read -p "PgBouncer username [pgbouncer]: " PGBOUNCER_USER

# Set default username if empty
if [ -z "$PGBOUNCER_USER" ]; then
    PGBOUNCER_USER="pgbouncer"
fi

# Prompt for password with confirmation
while true; do
    read -sp "PgBouncer password [pgbouncer]: " PGBOUNCER_PASSWORD
    echo ""
    
    # If empty, use default
    if [ -z "$PGBOUNCER_PASSWORD" ]; then
        PGBOUNCER_PASSWORD="pgbouncer"
        print_info "Using default password: pgbouncer"
        break
    fi
    
    read -sp "Confirm PgBouncer password: " PGBOUNCER_PASSWORD_CONFIRM
    echo ""
    
    if [ "$PGBOUNCER_PASSWORD" != "$PGBOUNCER_PASSWORD_CONFIRM" ]; then
        print_error "Passwords do not match. Please try again."
        continue
    fi
    
    break
done

print_success "Using PgBouncer username: '$PGBOUNCER_USER'"
echo ""

# Step 5: Determine container and network names
MIGRATION_CONTAINER_NAME="${PREFIX}cxo-pgbouncer-postgres-migration"
NETWORK_NAME="${PREFIX}cxo_network"
EXISTING_DB_CONTAINER="${PREFIX}cxo-db"

print_info "Configuration:"
print_info "  Migration container: $MIGRATION_CONTAINER_NAME"
print_info "  Network: $NETWORK_NAME"
print_info "  Target database container: $EXISTING_DB_CONTAINER"
echo ""

# Step 6: Check if the existing postgres container is running
print_info "Checking if existing postgres container '$EXISTING_DB_CONTAINER' is running..."
if ! docker ps --format '{{.Names}}' | grep -q "^${EXISTING_DB_CONTAINER}$"; then
    print_error "Container '$EXISTING_DB_CONTAINER' is not running. Please start it first."
    exit 1
fi
print_success "Existing postgres container is running."

# Step 7: Check if network exists
print_info "Checking if network '$NETWORK_NAME' exists..."
if ! docker network ls --format '{{.Name}}' | grep -q "^${NETWORK_NAME}$"; then
    print_error "Network '$NETWORK_NAME' does not exist. Please ensure docker-compose services are running."
    exit 1
fi
print_success "Network exists."

# Step 8: Clean up any existing migration container
print_info "Cleaning up any existing migration container..."
if docker ps -a --format '{{.Names}}' | grep -q "^${MIGRATION_CONTAINER_NAME}$"; then
    print_info "Removing existing migration container..."
    docker rm -f "$MIGRATION_CONTAINER_NAME" > /dev/null 2>&1 || true
    print_success "Existing container removed."
fi

# Step 9: Spin up migration container
print_info "Starting migration container '$MIGRATION_CONTAINER_NAME'..."
docker run -d \
    --name "$MIGRATION_CONTAINER_NAME" \
    --network "$NETWORK_NAME" \
    postgres:15-bookworm \
    sleep infinity > /dev/null

if [ $? -ne 0 ]; then
    print_error "Failed to start migration container"
    exit 1
fi

print_success "Migration container started."

# Wait a moment for container to be ready
sleep 2

# Step 10: Check if pgbouncer user already exists
print_info ""
print_info "=========================================="
print_info "Checking if PgBouncer user exists"
print_info "=========================================="

USER_EXISTS=$(docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" "$MIGRATION_CONTAINER_NAME" psql \
    -h "$EXISTING_DB_CONTAINER" \
    -U "$POSTGRES_USER" \
    -d postgres \
    -t -c "SELECT 1 FROM pg_roles WHERE rolname = '$PGBOUNCER_USER';" 2>/dev/null | tr -d '[:space:]')

if [ "$USER_EXISTS" = "1" ]; then
    print_warning "PgBouncer user '$PGBOUNCER_USER' already exists!"
    print_error "Migration may have already been performed. Exiting to prevent duplicate migration."
    print_info "Cleaning up migration container..."
    docker rm -f "$MIGRATION_CONTAINER_NAME" > /dev/null 2>&1 || true
    exit 1
fi

print_success "PgBouncer user '$PGBOUNCER_USER' does not exist. Proceeding with migration."
echo ""

# Step 11: Create pgbouncer user
print_info "=========================================="
print_info "Creating PgBouncer user"
print_info "=========================================="
print_info "Creating user: $PGBOUNCER_USER"

CREATE_USER_SQL="CREATE ROLE $PGBOUNCER_USER LOGIN PASSWORD '$PGBOUNCER_PASSWORD';"

if docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" "$MIGRATION_CONTAINER_NAME" psql \
    -h "$EXISTING_DB_CONTAINER" \
    -U "$POSTGRES_USER" \
    -d postgres \
    -c "$CREATE_USER_SQL" > /dev/null 2>&1; then
    print_success "PgBouncer user created successfully!"
else
    print_error "Failed to create PgBouncer user!"
    print_info "Cleaning up migration container..."
    docker rm -f "$MIGRATION_CONTAINER_NAME" > /dev/null 2>&1 || true
    exit 1
fi
echo ""

# Step 12: Get list of all databases and create function in each
print_info "=========================================="
print_info "Creating get_pg_shadow_pass function in all databases"
print_info "=========================================="

# Get list of all databases (excluding system databases)
# Use -A flag to remove alignment and get clean output
DB_LIST=$(docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" "$MIGRATION_CONTAINER_NAME" psql \
    -h "$EXISTING_DB_CONTAINER" \
    -U "$POSTGRES_USER" \
    -d postgres \
    -t -A -c "SELECT datname FROM pg_database WHERE datistemplate = false AND datname != 'postgres' ORDER BY datname;" 2>/dev/null)

# Also include postgres
DATABASES="postgres"
for DB in $DB_LIST; do
    # Trim whitespace and skip empty lines
    DB=$(echo "$DB" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
    [ -n "$DB" ] && DATABASES="$DATABASES $DB"
done

# Create function SQL file locally and copy to container
TEMP_SQL_FILE=$(mktemp)
cat > "$TEMP_SQL_FILE" << EOF
DROP FUNCTION IF EXISTS public.get_pg_shadow_pass(text);
DROP FUNCTION IF EXISTS public.get_pg_shadow_pass(name);
CREATE OR REPLACE FUNCTION public.get_pg_shadow_pass(username text)
RETURNS TABLE(usename name, passwd text)
LANGUAGE sql
SECURITY DEFINER
STABLE
AS \$func\$
    SELECT usename::name, passwd::text
    FROM pg_shadow
    WHERE usename = username::name;
\$func\$;
ALTER FUNCTION public.get_pg_shadow_pass(text) OWNER TO postgres;
GRANT EXECUTE ON FUNCTION public.get_pg_shadow_pass(text) TO $PGBOUNCER_USER;
EOF

# Copy SQL file to container
docker cp "$TEMP_SQL_FILE" "$MIGRATION_CONTAINER_NAME:/tmp/create_function.sql" > /dev/null 2>&1
rm -f "$TEMP_SQL_FILE"

SUCCESS_COUNT=0
FAILED_COUNT=0
FAILED_DBS=""

for DB_NAME in $DATABASES; do
    # Skip empty database names
    [ -z "$DB_NAME" ] && continue
    
    print_info "Processing database: $DB_NAME"
    
    # Create function in the database using the SQL file
    if docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" "$MIGRATION_CONTAINER_NAME" psql \
        -h "$EXISTING_DB_CONTAINER" \
        -U "$POSTGRES_USER" \
        -d "$DB_NAME" \
        -f /tmp/create_function.sql > /dev/null 2>&1; then
        print_success "  ✓ Function created in $DB_NAME"
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    else
        print_warning "  ✗ Failed to create function in $DB_NAME"
        FAILED_COUNT=$((FAILED_COUNT + 1))
        FAILED_DBS="$FAILED_DBS $DB_NAME"
    fi
done

echo ""
if [ $FAILED_COUNT -eq 0 ]; then
    print_success "Function created successfully in all $SUCCESS_COUNT databases!"
else
    print_warning "Function created in $SUCCESS_COUNT databases, but failed in $FAILED_COUNT:"
    for DB in $FAILED_DBS; do
        print_warning "  - $DB"
    done
    print_info "Continuing with migration..."
fi
echo ""

# Step 13: Clean up migration container
print_info "Cleaning up migration container..."
docker rm -f "$MIGRATION_CONTAINER_NAME" > /dev/null 2>&1 || true
print_success "Migration container removed."

# Step 14: Final report
echo ""
print_success "=========================================="
print_success "Migration Completed Successfully!"
print_success "=========================================="
echo ""
print_info "Summary of changes:"
print_info "  ✓ Created PgBouncer user '$PGBOUNCER_USER' in PostgreSQL"
print_info "  ✓ Created get_pg_shadow_pass function in all databases ($SUCCESS_COUNT databases)"
print_info "  ✓ Granted execute permissions to $PGBOUNCER_USER user"
echo ""
print_info "Next steps:"
print_info "  1. Stop the current postgres container (docker-compose down)"
print_info "  2. Switch to using docker-compose.db.pg-with-bouncer.yml"
print_info "  3. Start the new pgbouncer+postgres setup (docker-compose up -d)"
echo ""
print_success "Your database is now ready for pgbouncer integration!"
echo ""

