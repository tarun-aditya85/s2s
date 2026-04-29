#!/bin/bash

# ============================================================================
# Tenant Setup Script
# Creates a new tenant with BigQuery authorized view
# ============================================================================

set -e

# Color codes
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Check arguments
if [ "$#" -ne 3 ]; then
    echo -e "${RED}Usage: $0 <tenant_id> <tenant_name> <tenant_email>${NC}"
    echo "Example: $0 client_001 'Acme Corp' client@acme.com"
    exit 1
fi

TENANT_ID=$1
TENANT_NAME=$2
TENANT_EMAIL=$3
PROJECT_ID="${GCP_PROJECT_ID}"

if [ -z "$PROJECT_ID" ]; then
    echo -e "${RED}Error: GCP_PROJECT_ID environment variable is not set${NC}"
    exit 1
fi

echo -e "${GREEN}==============================================================${NC}"
echo -e "${GREEN}   Setting up new tenant: $TENANT_NAME${NC}"
echo -e "${GREEN}==============================================================${NC}"

# Generate API key
API_KEY="sk_live_$(openssl rand -hex 16)"

echo -e "${YELLOW}Tenant ID:${NC} $TENANT_ID"
echo -e "${YELLOW}API Key:${NC} $API_KEY"
echo ""

# Step 1: Create BigQuery authorized view
echo -e "${YELLOW}[1/3] Creating BigQuery authorized view...${NC}"

VIEW_SQL=$(cat <<EOF
CREATE OR REPLACE VIEW \`${PROJECT_ID}.s2s_attribution.tenant_${TENANT_ID}_view\` AS
SELECT
  event_id,
  event_type,
  timestamp,
  click_id,
  ip_address,
  user_agent,
  referrer,
  target_url,
  utm_source,
  utm_medium,
  utm_campaign,
  utm_term,
  utm_content,
  device_type,
  device_brand,
  os,
  browser,
  country,
  region,
  city,
  conversion_value,
  currency,
  order_id,
  network_name,
  payout,
  commission,
  latency_ms,
  matched,
  partition_date
FROM \`${PROJECT_ID}.s2s_attribution.events\`
WHERE tenant_id = '$TENANT_ID';
EOF
)

echo "$VIEW_SQL" | bq query --use_legacy_sql=false

echo -e "${GREEN}✓ Authorized view created${NC}"

# Step 2: Grant access to tenant
echo -e "${YELLOW}[2/3] Granting BigQuery access to tenant...${NC}"

bq add-iam-policy-binding \
    --member="user:$TENANT_EMAIL" \
    --role="roles/bigquery.dataViewer" \
    "${PROJECT_ID}:s2s_attribution.tenant_${TENANT_ID}_view"

echo -e "${GREEN}✓ Access granted${NC}"

# Step 3: Save tenant configuration
echo -e "${YELLOW}[3/3] Saving tenant configuration...${NC}"

TENANT_JSON=$(cat <<EOF
{
  "tenant_id": "$TENANT_ID",
  "name": "$TENANT_NAME",
  "api_key": "$API_KEY",
  "email": "$TENANT_EMAIL",
  "active": true,
  "created_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
)

# Save to Cloud Secret Manager (recommended for production)
echo "$TENANT_JSON" | gcloud secrets create "tenant-${TENANT_ID}" --data-file=- 2>/dev/null || \
  echo "$TENANT_JSON" | gcloud secrets versions add "tenant-${TENANT_ID}" --data-file=-

echo -e "${GREEN}✓ Configuration saved to Secret Manager${NC}"

# Output summary
echo ""
echo -e "${GREEN}==============================================================${NC}"
echo -e "${GREEN}   Tenant Setup Complete!${NC}"
echo -e "${GREEN}==============================================================${NC}"
echo ""
echo -e "${YELLOW}Tenant Details:${NC}"
echo "  ID: $TENANT_ID"
echo "  Name: $TENANT_NAME"
echo "  Email: $TENANT_EMAIL"
echo "  API Key: $API_KEY"
echo ""
echo -e "${YELLOW}BigQuery View:${NC} ${PROJECT_ID}.s2s_attribution.tenant_${TENANT_ID}_view"
echo ""
echo -e "${YELLOW}Add to .env TENANTS variable:${NC}"
cat <<EOF
TENANTS='[
  {
    "tenant_id": "$TENANT_ID",
    "api_key": "$API_KEY",
    "name": "$TENANT_NAME",
    "active": true
  }
]'
EOF
echo ""
echo -e "${GREEN}Done! 🎉${NC}"
