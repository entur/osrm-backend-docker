#!/bin/bash

set -e

# Colors for output  
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

# Create test directories
mkdir -p test/expected test/results test-data

# Download test data if needed
if [ ! -f "test-data/zeeland-latest.osm.pbf" ]; then
    log "Downloading test data..."
    curl -L -o "test-data/zeeland-latest.osm.pbf" "https://download.geofabrik.de/europe/netherlands/zeeland-latest.osm.pbf"
fi

# Clean up any existing baselines
log "Removing existing baseline files..."
rm -f test/expected/*.json

# Start services
log "Starting test services..."
docker-compose -f docker-compose.test.yml up -d

# Wait for data preparation to complete
log "Waiting for data preparation to complete..."
while ! docker-compose -f docker-compose.test.yml logs osrm-prepare | grep -q "Data preparation complete!"; do
    echo -n "."
    sleep 5
done
echo

# Restart services to ensure they pick up the prepared data
log "Restarting routing services..."
docker-compose -f docker-compose.test.yml restart osrm-bus osrm-rail osrm-ferry

# Wait for services to be ready
log "Waiting for services to be ready..."
services=("bus:5001" "rail:5002" "ferry:5003")

for service_port in "${services[@]}"; do
    IFS=':' read -r service port <<< "$service_port"
    log "Waiting for $service service on port $port..."
    
    for i in {1..30}; do
        if curl -sf "http://localhost:$port/route/v1/driving/6.8,52.8;6.9,52.9?overview=false" >/dev/null 2>&1; then
            log "✓ $service service is ready"
            break
        fi
        
        if [ $i -eq 30 ]; then
            error "$service service failed to start"
            docker-compose -f docker-compose.test.yml logs
            exit 1
        fi
        
        echo -n "."
        sleep 2
    done
done

# Create baseline responses
log "Creating baseline responses..."

test_cases=(
    "kruiningen_perkpolder:4.0295,51.4481;4.0577,51.3644"  
    "anna_jacobapolder_kats:3.9686,51.6356;3.8708,51.6467"
)

for service_port in "${services[@]}"; do
    IFS=':' read -r service port <<< "$service_port"
    
    for test_case in "${test_cases[@]}"; do
        IFS=':' read -r test_name coordinates <<< "$test_case"
        
        log "Creating baseline for $service:$test_name"
        
        url="http://localhost:$port/route/v1/driving/$coordinates?overview=false"
        baseline_file="test/expected/${service}_${test_name}.json"
        
        # Make request and save as baseline
        if curl -sf "$url" > "$baseline_file"; then
            log "✓ Created baseline: $baseline_file"
        else
            error "Failed to create baseline for $service:$test_name"
            exit 1
        fi
    done
done

# Cleanup
log "Cleaning up..."
docker-compose -f docker-compose.test.yml down -v

# Summary
echo
log "Baseline creation complete!"
log "Created $(ls test/expected/*.json | wc -l) baseline files:"
ls test/expected/*.json | sed 's/^/  /'
echo
log "Next steps:"
log "1. Review the baseline files to ensure they look correct"
log "2. Commit these files to git: git add test/expected/ && git commit -m 'Add baseline responses for profile testing'"
log "3. Run './run-test.sh' to verify the testing framework works"