#!/bin/bash

# ============================================================================
# GCP Deployment Script for S2S Attribution Server
# ============================================================================

set -e  # Exit on error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
PROJECT_ID="${GCP_PROJECT_ID}"
REGION="${GCP_REGION:-us-central1}"
SERVICE_NAME="${SERVICE_NAME:-s2s-attribution-prod}"

echo -e "${GREEN}==============================================================${NC}"
echo -e "${GREEN}   S2S Attribution Server - GCP Deployment${NC}"
echo -e "${GREEN}==============================================================${NC}"
echo ""

# Check if PROJECT_ID is set
if [ -z "$PROJECT_ID" ]; then
    echo -e "${RED}Error: GCP_PROJECT_ID environment variable is not set${NC}"
    exit 1
fi

echo -e "${YELLOW}Configuration:${NC}"
echo "  Project ID: $PROJECT_ID"
echo "  Region: $REGION"
echo "  Service Name: $SERVICE_NAME"
echo ""

# Step 1: Set GCP project
echo -e "${YELLOW}[1/6] Setting GCP project...${NC}"
gcloud config set project $PROJECT_ID

# Step 2: Enable required APIs
echo -e "${YELLOW}[2/6] Enabling required GCP APIs...${NC}"
gcloud services enable \
    run.googleapis.com \
    pubsub.googleapis.com \
    redis.googleapis.com \
    bigquery.googleapis.com \
    storage.googleapis.com \
    cloudbuild.googleapis.com

# Step 3: Deploy infrastructure with Terraform
echo -e "${YELLOW}[3/6] Deploying infrastructure with Terraform...${NC}"
cd infra/terraform/gcp

if [ ! -d ".terraform" ]; then
    terraform init
fi

terraform apply -var="project_id=$PROJECT_ID" -var="region=$REGION" -auto-approve

# Capture outputs
REDIS_HOST=$(terraform output -raw redis_host)
REDIS_PORT=$(terraform output -raw redis_port)

cd ../../..

echo -e "${GREEN}✓ Infrastructure deployed${NC}"

# Step 4: Build and push Docker image
echo -e "${YELLOW}[4/6] Building Docker image...${NC}"
gcloud builds submit --tag gcr.io/$PROJECT_ID/s2s-attribution:latest

echo -e "${GREEN}✓ Docker image built and pushed${NC}"

# Step 5: Deploy to Cloud Run
echo -e "${YELLOW}[5/6] Deploying to Cloud Run...${NC}"
gcloud run deploy $SERVICE_NAME \
    --image gcr.io/$PROJECT_ID/s2s-attribution:latest \
    --region $REGION \
    --platform managed \
    --allow-unauthenticated \
    --min-instances 1 \
    --max-instances 100 \
    --cpu 2 \
    --memory 512Mi \
    --timeout 30 \
    --set-env-vars "NODE_ENV=production,CLOUD_PROVIDER=gcp,GCP_PROJECT_ID=$PROJECT_ID,REDIS_HOST=$REDIS_HOST,REDIS_PORT=$REDIS_PORT"

SERVICE_URL=$(gcloud run services describe $SERVICE_NAME --region $REGION --format 'value(status.url)')

echo -e "${GREEN}✓ Service deployed to Cloud Run${NC}"

# Step 6: Initialize BigQuery schema
echo -e "${YELLOW}[6/6] Initializing BigQuery schema...${NC}"

# Replace ${project_id} in schema.sql
sed "s/\${project_id}/$PROJECT_ID/g" infra/bigquery/schema.sql > /tmp/schema.sql

bq query --use_legacy_sql=false < /tmp/schema.sql

rm /tmp/schema.sql

echo -e "${GREEN}✓ BigQuery schema initialized${NC}"

# Deployment summary
echo ""
echo -e "${GREEN}==============================================================${NC}"
echo -e "${GREEN}   Deployment Complete!${NC}"
echo -e "${GREEN}==============================================================${NC}"
echo ""
echo -e "${YELLOW}Service URL:${NC} $SERVICE_URL"
echo -e "${YELLOW}Redis Host:${NC} $REDIS_HOST"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo "1. Update your .env file with Redis credentials"
echo "2. Configure tenant API keys in Cloud Secret Manager"
echo "3. Test the endpoints:"
echo "   curl $SERVICE_URL/health"
echo ""
echo -e "${GREEN}Happy tracking! 🎯${NC}"
