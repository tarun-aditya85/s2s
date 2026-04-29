#!/bin/bash

# ============================================================================
# Test Data Generator
# Generates sample click and postback events for testing
# ============================================================================

set -e

SERVER_URL="${SERVER_URL:-http://localhost:8080}"
API_KEY="${API_KEY:-sk_test_demo_key_12345}"
NUM_CLICKS="${1:-100}"

echo "=========================================="
echo "  S2S Test Data Generator"
echo "=========================================="
echo "Server URL: $SERVER_URL"
echo "API Key: $API_KEY"
echo "Generating: $NUM_CLICKS clicks"
echo ""

# Arrays for test data
SOURCES=("google" "facebook" "twitter" "linkedin" "instagram")
MEDIUMS=("cpc" "email" "social" "referral" "display")
CAMPAIGNS=("summer_sale" "q4_promo" "new_product" "retargeting" "brand")
URLS=("https://example.com/product-a" "https://example.com/product-b" "https://example.com/landing")

CLICK_IDS=()

echo "[1/2] Generating $NUM_CLICKS clicks..."

for i in $(seq 1 $NUM_CLICKS); do
  # Random test data
  SOURCE=${SOURCES[$RANDOM % ${#SOURCES[@]}]}
  MEDIUM=${MEDIUMS[$RANDOM % ${#MEDIUMS[@]}]}
  CAMPAIGN=${CAMPAIGNS[$RANDOM % ${#CAMPAIGNS[@]}]}
  URL=${URLS[$RANDOM % ${#URLS[@]}]}

  # Make click request
  RESPONSE=$(curl -s -X POST "$SERVER_URL/click" \
    -H "X-API-Key: $API_KEY" \
    -H "Content-Type: application/json" \
    -d "{
      \"url\": \"$URL\",
      \"utm_source\": \"$SOURCE\",
      \"utm_medium\": \"$MEDIUM\",
      \"utm_campaign\": \"$CAMPAIGN\"
    }" \
    -w "\n%{http_code}" \
    -L -o /dev/null)

  HTTP_CODE=$(echo "$RESPONSE" | tail -n1)

  if [ "$HTTP_CODE" = "302" ] || [ "$HTTP_CODE" = "200" ]; then
    echo "  ✓ Click $i/$NUM_CLICKS created"
  else
    echo "  ✗ Click $i/$NUM_CLICKS failed (HTTP $HTTP_CODE)"
  fi

  # Rate limiting
  if [ $((i % 10)) -eq 0 ]; then
    sleep 0.5
  fi
done

echo ""
echo "[2/2] Generating conversions (30% conversion rate)..."

# Simulate conversions for 30% of clicks
NUM_CONVERSIONS=$((NUM_CLICKS * 30 / 100))

for i in $(seq 1 $NUM_CONVERSIONS); do
  # Random conversion value
  VALUE=$(echo "scale=2; $RANDOM % 200 + 10" | bc)

  # Make postback request (using a dummy click_id for demo)
  RESPONSE=$(curl -s -X POST "$SERVER_URL/postback" \
    -H "X-API-Key: $API_KEY" \
    -H "Content-Type: application/json" \
    -d "{
      \"click_id\": \"test-click-$RANDOM\",
      \"conversion_value\": $VALUE,
      \"currency\": \"USD\",
      \"order_id\": \"ORDER-$RANDOM\"
    }" \
    -w "\n%{http_code}")

  HTTP_CODE=$(echo "$RESPONSE" | tail -n1)

  if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "404" ]; then
    echo "  ✓ Conversion $i/$NUM_CONVERSIONS sent"
  else
    echo "  ✗ Conversion $i/$NUM_CONVERSIONS failed (HTTP $HTTP_CODE)"
  fi

  if [ $((i % 10)) -eq 0 ]; then
    sleep 0.5
  fi
done

echo ""
echo "=========================================="
echo "  Test Data Generation Complete!"
echo "=========================================="
echo "Clicks generated: $NUM_CLICKS"
echo "Conversions sent: $NUM_CONVERSIONS"
echo ""
echo "Next steps:"
echo "1. Check Redis for click_ids: redis-cli KEYS 'click:*'"
echo "2. Verify events in Cloud Storage/S3"
echo "3. Query BigQuery: SELECT COUNT(*) FROM events WHERE partition_date = CURRENT_DATE()"
