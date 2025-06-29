#!/bin/bash

# Script to manage database migrations for staff-service
# Usage: ./scripts/migrate.sh [up|down|reset|status|sample]

# Load environment variables from the service-specific .env file
SERVICE_ENV_PATH="$(pwd)/.env"

if [ -f "$SERVICE_ENV_PATH" ]; then
    source "$SERVICE_ENV_PATH"
    echo "Loaded environment from: $SERVICE_ENV_PATH"
else
    echo "Warning: No service-specific .env file found at $SERVICE_ENV_PATH"
fi

# Colors for better output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Set container and DB parameters from environment variables with defaults
CONTAINER_NAME=${STAFF_SERVICE_CONTAINER_NAME:-fitness-staff-db}
DB_PORT=${STAFF_SERVICE_DB_PORT:-5433}
DB_USER=${DB_USER:-fitness_user}
DB_PASSWORD=${DB_PASSWORD:-admin}
DB_NAME=${STAFF_SERVICE_DB_NAME:-fitness_staff_db}

# Function to apply all migrations (up migrations only)
apply_migrations() {
    echo -e "${BLUE}Applying migrations...${NC}"
    
    for migration in ./migrations/*.up.sql; do
        # Skip sample data migration, handle separately
        if [[ "$migration" != *"sample_data"* && "$migration" != *"drop_tables"* ]]; then
            echo -e "${YELLOW}Applying: $(basename "$migration")${NC}"
            if ! docker exec -i $CONTAINER_NAME psql -U $DB_USER -d $DB_NAME < "$migration"; then
                echo -e "${RED}Failed to apply migration: $(basename "$migration")${NC}"
                return 1
            fi
            echo -e "${GREEN}Successfully applied: $(basename "$migration")${NC}"
        fi
    done
    
    echo -e "${GREEN}All migrations applied successfully!${NC}"
    return 0
}

# Function to revert all migrations
revert_migrations() {
    echo -e "${BLUE}Reverting migrations...${NC}"
    
    # Apply down migrations in reverse order
    for migration in $(ls -r ./migrations/*.down.sql); do
        echo -e "${YELLOW}Reverting: $(basename "$migration")${NC}"
        if ! docker exec -i $CONTAINER_NAME psql -U $DB_USER -d $DB_NAME < "$migration"; then
            echo -e "${RED}Failed to revert migration: $(basename "$migration")${NC}"
            return 1
        fi
        echo -e "${GREEN}Successfully reverted: $(basename "$migration")${NC}"
    done
    
    echo -e "${GREEN}All migrations reverted successfully!${NC}"
    return 0
}

# Function to reset database (drop everything and reapply)
reset_database() {
    echo -e "${BLUE}Resetting database...${NC}"
    
    # First check if container is running
    if ! docker ps | grep -q "$CONTAINER_NAME"; then
        echo -e "${RED}Container $CONTAINER_NAME is not running. Please start it first.${NC}"
        echo -e "You can use: ${YELLOW}./scripts/docker-db.sh start${NC}"
        return 1
    fi
    
    # Apply drop tables migration to ensure clean slate
    if [ -f "./migrations/000_drop_tables.sql" ]; then
        echo -e "${YELLOW}Dropping all existing tables...${NC}"
        if ! docker exec -i $CONTAINER_NAME psql -U $DB_USER -d $DB_NAME < "./migrations/000_drop_tables.sql"; then
            echo -e "${RED}Failed to drop tables${NC}"
            return 1
        fi
    fi
    
    # Apply all migrations
    if ! apply_migrations; then
        echo -e "${RED}Failed to apply migrations during reset${NC}"
        return 1
    fi
    
    echo -e "${GREEN}Database reset successfully! Tables have been recreated.${NC}"
    echo -e "To load sample data, run: ${YELLOW}./scripts/migrate.sh sample${NC}"
    
    return 0
}

# Function to check migration status
check_status() {
    echo -e "${BLUE}Checking migration status...${NC}"
    
    # First check if container is running
    if ! docker ps | grep -q "$CONTAINER_NAME"; then
        echo -e "${RED}Container $CONTAINER_NAME is not running. Please start it first.${NC}"
        echo -e "You can use: ${YELLOW}./scripts/docker-db.sh start${NC}"
        return 1
    fi
    
    # Check for each required table
    required_tables=("staff" "staff_qualifications" "trainers" "personal_training")
    missing_tables=0
    
    echo -e "${YELLOW}Required tables:${NC}"
    for table in "${required_tables[@]}"; do
        exists=$(docker exec -i $CONTAINER_NAME psql -U $DB_USER -d $DB_NAME -t -c "SELECT EXISTS(SELECT FROM information_schema.tables WHERE table_name = '$table')" | xargs)
        
        if [ "$exists" == "t" ]; then
            # Count rows in the table
            row_count=$(docker exec -i $CONTAINER_NAME psql -U $DB_USER -d $DB_NAME -t -c "SELECT COUNT(*) FROM $table" | xargs)
            echo -e "${GREEN}✓ $table${NC} (rows: $row_count)"
        else
            echo -e "${RED}✗ $table${NC} (missing)"
            missing_tables=$((missing_tables + 1))
        fi
    done
    
    # Overall status
    if [ $missing_tables -eq 0 ]; then
        echo -e "\n${GREEN}Database schema is complete!${NC}"
    else
        echo -e "\n${RED}Database schema is incomplete! $missing_tables tables are missing.${NC}"
        echo -e "To apply migrations, run: ${YELLOW}./scripts/migrate.sh up${NC}"
        return 1
    fi
    
    return 0
}

# Function to load sample data
load_sample_data() {
    echo -e "${BLUE}Loading sample data...${NC}"
    
    # First check if container is running
    if ! docker ps | grep -q "$CONTAINER_NAME"; then
        echo -e "${RED}Container $CONTAINER_NAME is not running. Please start it first.${NC}"
        echo -e "You can use: ${YELLOW}./scripts/docker-db.sh start${NC}"
        return 1
    fi
    
    # Try to find sample data file with different possible names
    local sample_data_file=""
    for file in "./migrations/002_sample_data.sql" "./migrations/sample_data.sql"; do
        if [ -f "$file" ]; then
            sample_data_file="$file"
            break
        fi
    done
    
    if [ -n "$sample_data_file" ]; then
        echo -e "${YELLOW}Loading sample data from: $sample_data_file...${NC}"
        if ! docker exec -i $CONTAINER_NAME psql -U $DB_USER -d $DB_NAME < "$sample_data_file"; then
            echo -e "${RED}Failed to load sample data${NC}"
            return 1
        fi
        echo -e "${GREEN}Sample data loaded successfully!${NC}"
    else
        echo -e "${RED}Sample data file not found in the migrations directory${NC}"
        echo -e "${YELLOW}Looking for sample files with pattern: *sample*.sql${NC}"
        sample_files=$(find ./migrations -name "*sample*.sql" -type f)
        if [ -n "$sample_files" ]; then
            echo -e "${YELLOW}Found potential sample data files:${NC}"
            echo "$sample_files"
            echo -e "${YELLOW}Please choose one to load (enter full path or leave empty to skip):${NC}"
            read -r chosen_file
            if [ -n "$chosen_file" ] && [ -f "$chosen_file" ]; then
                if ! docker exec -i $CONTAINER_NAME psql -U $DB_USER -d $DB_NAME < "$chosen_file"; then
                    echo -e "${RED}Failed to load sample data${NC}"
                    return 1
                fi
                echo -e "${GREEN}Sample data loaded successfully!${NC}"
            else
                echo -e "${YELLOW}No valid file chosen, skipping sample data${NC}"
                return 1
            fi
        else
            echo -e "${RED}No sample data files found${NC}"
            return 1
        fi
    fi
    
    return 0
}

# Main script logic
case "$1" in
    "up")
        apply_migrations
        ;;
    "down")
        revert_migrations
        ;;
    "reset")
        reset_database
        ;;
    "status")
        check_status
        ;;
    "sample")
        load_sample_data
        ;;
    *)
        echo "Usage: $0 [up|down|reset|status|sample]"
        echo ""
        echo "Commands:"
        echo "  up     - Apply all migrations"
        echo "  down   - Revert all migrations"
        echo "  reset  - Reset database (drop everything and reapply migrations)"
        echo "  status - Check migration status"
        echo "  sample - Load sample data"
        exit 1
        ;;
esac

exit $?
