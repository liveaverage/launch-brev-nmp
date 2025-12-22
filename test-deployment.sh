#!/bin/bash

# Test script for deployment application
# Tests all API endpoints and dry-run functionality

set -e

echo "=========================================="
echo "Deployment App Test Suite"
echo "=========================================="
echo ""

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test results
PASSED=0
FAILED=0

# Function to print test result
print_result() {
    if [ $1 -eq 0 ]; then
        echo -e "${GREEN}✓ PASSED${NC}: $2"
        PASSED=$((PASSED + 1))
    else
        echo -e "${RED}✗ FAILED${NC}: $2"
        FAILED=$((FAILED + 1))
    fi
}

# Start the app in background
echo "Starting deployment app..."
export CONFIG_FILE=./config-helm.json
export HELP_CONTENT_FILE=./help-content.json
python3 app.py > /tmp/deploy-app.log 2>&1 &
APP_PID=$!

# Wait for app to start
echo "Waiting for app to start..."
sleep 3

# Check if app is running
if ! ps -p $APP_PID > /dev/null; then
    echo -e "${RED}ERROR: App failed to start${NC}"
    echo "Log output:"
    cat /tmp/deploy-app.log
    exit 1
fi

echo -e "${GREEN}App started successfully (PID: $APP_PID)${NC}"
echo ""

# Cleanup function
cleanup() {
    echo ""
    echo "Cleaning up..."
    kill $APP_PID 2>/dev/null || true
    rm -f /tmp/deploy-app.log
}

trap cleanup EXIT

echo "Running tests..."
echo ""

# Test 1: Root endpoint
echo "Test 1: GET / (Root endpoint)"
if curl -s -f http://localhost:8080/ > /dev/null; then
    print_result 0 "Root endpoint returns HTML"
else
    print_result 1 "Root endpoint failed"
fi

# Test 2: Config endpoint
echo "Test 2: GET /config"
CONFIG_RESPONSE=$(curl -s http://localhost:8080/config)
if echo "$CONFIG_RESPONSE" | jq -e '.["helm-nemo"]' > /dev/null 2>&1; then
    print_result 0 "Config endpoint returns valid JSON"
else
    print_result 1 "Config endpoint response invalid"
fi

# Test 3: Help endpoint
echo "Test 3: GET /help"
HELP_RESPONSE=$(curl -s http://localhost:8080/help)
if echo "$HELP_RESPONSE" | jq -e '.title' > /dev/null 2>&1; then
    print_result 0 "Help endpoint returns valid JSON"
else
    print_result 1 "Help endpoint response invalid"
fi

# Test 4: Deploy endpoint validation (missing API key)
echo "Test 4: POST /deploy (missing API key)"
ERROR_RESPONSE=$(curl -s -X POST http://localhost:8080/deploy \
    -H "Content-Type: application/json" \
    -d '{"deployType":"helm-nemo"}')
if echo "$ERROR_RESPONSE" | jq -e '.error' | grep -q "API key"; then
    print_result 0 "Deploy endpoint validates API key requirement"
else
    print_result 1 "Deploy endpoint validation failed"
fi

# Test 5: Deploy endpoint validation (missing deploy type)
echo "Test 5: POST /deploy (missing deploy type)"
ERROR_RESPONSE=$(curl -s -X POST http://localhost:8080/deploy \
    -H "Content-Type: application/json" \
    -d '{"apiKey":"test-key"}')
if echo "$ERROR_RESPONSE" | jq -e '.error' | grep -q "Deployment type"; then
    print_result 0 "Deploy endpoint validates deployment type requirement"
else
    print_result 1 "Deploy endpoint validation failed"
fi

# Test 6: Dry-run deployment
echo "Test 6: POST /deploy (dry-run mode)"
DRYRUN_RESPONSE=$(curl -s -X POST http://localhost:8080/deploy \
    -H "Content-Type: application/json" \
    -d '{
        "apiKey":"test-key-12345",
        "deployType":"helm-nemo",
        "version":"25.12.0",
        "dryRun":true
    }')

if echo "$DRYRUN_RESPONSE" | jq -e '.dry_run' | grep -q "true"; then
    print_result 0 "Dry-run mode returns dry_run flag"
else
    print_result 1 "Dry-run mode failed"
fi

# Test 7: Dry-run response structure
echo "Test 7: Dry-run response structure"
if echo "$DRYRUN_RESPONSE" | jq -e '.would_execute.pre_commands' > /dev/null 2>&1; then
    print_result 0 "Dry-run response includes pre_commands"
else
    print_result 1 "Dry-run response structure incomplete"
fi

# Test 8: Dry-run masks secrets
echo "Test 8: Dry-run masks API keys"
if echo "$DRYRUN_RESPONSE" | grep -q "test-key-12345"; then
    print_result 1 "Dry-run exposes API key (security issue!)"
else
    if echo "$DRYRUN_RESPONSE" | grep -q "\*\*\*"; then
        print_result 0 "Dry-run properly masks API key"
    else
        print_result 1 "Dry-run masking unclear"
    fi
fi

# Test 9: Version substitution in dry-run
echo "Test 9: Version substitution"
if echo "$DRYRUN_RESPONSE" | jq -e '.would_execute.version' | grep -q "25.12.0"; then
    print_result 0 "Version properly set in dry-run"
else
    print_result 1 "Version substitution failed"
fi

# Test 10: Environment variable dry-run override
echo "Test 10: Environment variable DRY_RUN=true"
# Stop current app
kill $APP_PID
sleep 1

# Start with DRY_RUN env var
export DRY_RUN=true
python3 app.py > /tmp/deploy-app.log 2>&1 &
APP_PID=$!
sleep 3

# Try deployment without dryRun flag (should still be dry-run due to env var)
ENV_DRYRUN_RESPONSE=$(curl -s -X POST http://localhost:8080/deploy \
    -H "Content-Type: application/json" \
    -d '{
        "apiKey":"test-key",
        "deployType":"helm-nemo",
        "version":"25.12.0"
    }')

if echo "$ENV_DRYRUN_RESPONSE" | jq -e '.dry_run' | grep -q "true"; then
    print_result 0 "Environment variable DRY_RUN forces dry-run mode"
else
    print_result 1 "Environment variable DRY_RUN not working"
fi

# Summary
echo ""
echo "=========================================="
echo "Test Results Summary"
echo "=========================================="
echo -e "${GREEN}Passed: $PASSED${NC}"
echo -e "${RED}Failed: $FAILED${NC}"
echo ""

if [ $FAILED -eq 0 ]; then
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed. Check output above.${NC}"
    echo ""
    echo "App logs:"
    cat /tmp/deploy-app.log
    exit 1
fi
