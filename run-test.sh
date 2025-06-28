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

# Create test directories
mkdir -p test/expected test/results test-data

# Download test data if needed
if [ ! -f "test-data/zeeland-latest.osm.pbf" ]; then
    log "Downloading test data..."
    curl -L -o "test-data/zeeland-latest.osm.pbf" "https://download.geofabrik.de/europe/netherlands/zeeland-latest.osm.pbf"
fi

# Start services
log "Starting test services..."
docker compose -f docker-compose.test.yml up -d

# Wait for services to be ready
log "Waiting for services to be ready..."
services=("bus:5001" "rail:5002" "ferry:5003")

for service_port in "${services[@]}"; do
    IFS=':' read -r service port <<< "$service_port"
    log "Waiting for $service service on port $port..."
    
    for i in {1..30}; do
        if curl -sf "http://localhost:$port/route/v1/driving/3.7,51.5;3.71,51.51?overview=false" >/dev/null 2>&1; then
            log "✓ $service service is ready"
            break
        fi
        
        if [ $i -eq 30 ]; then
            error "$service service failed to start"
            docker compose -f docker-compose.test.yml logs
            exit 1
        fi
        
        echo -n "."
        sleep 2
    done
done

# Run tests
log "Running routing tests..."
failed=0

test_cases=(
    "kruiningen_perkpolder:4.0295,51.4481;4.0577,51.3644"  
    "anna_jacobapolder_kats:3.9686,51.6356;3.8708,51.6467"
)

for service_port in "${services[@]}"; do
    IFS=':' read -r service port <<< "$service_port"
    
    for test_case in "${test_cases[@]}"; do
        IFS=':' read -r test_name coordinates <<< "$test_case"
        
        log "Testing $service: $test_name"
        
        url="http://localhost:$port/route/v1/driving/$coordinates?overview=false"
        result_file="test/results/${service}_${test_name}.json"
        expected_file="test/expected/${service}_${test_name}.json"
        
        # Make request
        if ! curl -sf "$url" > "$result_file"; then
            error "Failed to get response from $service for $test_name"
            ((failed++))
            continue
        fi
        
        # Create baseline if not exists
        if [ ! -f "$expected_file" ]; then
            log "Creating baseline for $service:$test_name"
            cp "$result_file" "$expected_file"
            continue
        fi
        
        # Compare responses (ignoring timestamps)
        expected_norm=$(jq -S 'del(.timestamp) | del(.uuid) | .routes[]? |= del(.uuid)' "$expected_file" 2>/dev/null || echo "")
        result_norm=$(jq -S 'del(.timestamp) | del(.uuid) | .routes[]? |= del(.uuid)' "$result_file" 2>/dev/null || echo "")
        
        if [ "$expected_norm" = "$result_norm" ]; then
            log "✓ $service:$test_name passed"
        else
            error "✗ $service:$test_name failed - response mismatch"
            echo "Expected: $expected_file"
            echo "Result: $result_file"
            ((failed++))
        fi
    done
done

# Cleanup
log "Cleaning up..."
docker compose -f docker-compose.test.yml down -v

# Summary
echo
if [ $failed -eq 0 ]; then
    log "All tests passed! ✓"
    exit 0
else
    error "$failed tests failed"
    exit 1
fi