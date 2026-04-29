# Deployment Guide

This guide covers deployment to both GCP and AWS environments.

---

## Prerequisites

- Node.js 18+
- Docker
- Terraform 1.0+
- GCP CLI (`gcloud`) or AWS CLI (`aws`)
- Redis (managed service recommended)

---

## GCP Deployment

### Step 1: Set Up GCP Project

```bash
# Set project ID
export GCP_PROJECT_ID="your-project-id"
export GCP_REGION="us-central1"

# Enable billing
gcloud config set project $GCP_PROJECT_ID

# Enable required APIs
gcloud services enable \
  run.googleapis.com \
  pubsub.googleapis.com \
  redis.googleapis.com \
  bigquery.googleapis.com \
  storage.googleapis.com \
  cloudbuild.googleapis.com
```

### Step 2: Deploy Infrastructure

```bash
cd infra/terraform/gcp

# Initialize Terraform
terraform init

# Preview changes
terraform plan -var="project_id=$GCP_PROJECT_ID"

# Deploy
terraform apply -var="project_id=$GCP_PROJECT_ID"
```

**Outputs**:
- `cloud_run_url`: Your server URL
- `redis_host`: Redis IP address
- `storage_bucket`: Parquet storage bucket
- `bigquery_dataset`: Dataset name

### Step 3: Configure Environment

Create `.env.production`:

```bash
NODE_ENV=production
PORT=8080

REDIS_HOST=<from_terraform_output>
REDIS_PORT=6379
REDIS_PASSWORD=<from_secret_manager>
REDIS_TLS_ENABLED=true

CLOUD_PROVIDER=gcp
GCP_PROJECT_ID=your-project-id
GCP_PUBSUB_TOPIC_CLICKS=s2s-clicks-prod
GCP_PUBSUB_TOPIC_POSTBACKS=s2s-postbacks-prod

TENANTS='[{"tenant_id":"demo","api_key":"sk_test_demo","name":"Demo","active":true}]'
```

### Step 4: Deploy Server

**Option A: Automated Script**

```bash
chmod +x scripts/deploy-gcp.sh
./scripts/deploy-gcp.sh
```

**Option B: Manual Deployment**

```bash
# Build Docker image
gcloud builds submit --tag gcr.io/$GCP_PROJECT_ID/s2s-attribution:latest

# Deploy to Cloud Run
gcloud run deploy s2s-attribution-prod \
  --image gcr.io/$GCP_PROJECT_ID/s2s-attribution:latest \
  --region $GCP_REGION \
  --platform managed \
  --allow-unauthenticated \
  --min-instances 1 \
  --max-instances 100 \
  --cpu 2 \
  --memory 512Mi \
  --env-vars-file .env.production
```

### Step 5: Initialize BigQuery

```bash
# Replace placeholders
sed "s/\${project_id}/$GCP_PROJECT_ID/g" infra/bigquery/schema.sql > /tmp/schema.sql

# Load schema
bq query --use_legacy_sql=false < /tmp/schema.sql
```

### Step 6: Verify Deployment

```bash
# Get service URL
SERVICE_URL=$(gcloud run services describe s2s-attribution-prod \
  --region $GCP_REGION \
  --format 'value(status.url)')

# Test health check
curl $SERVICE_URL/health

# Test click tracking
curl -X POST $SERVICE_URL/click \
  -H "X-API-Key: sk_test_demo" \
  -H "Content-Type: application/json" \
  -d '{"url":"https://example.com","utm_source":"test"}'
```

---

## AWS Deployment

### Step 1: Set Up AWS Account

```bash
# Configure AWS CLI
aws configure

export AWS_REGION="us-east-1"
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
```

### Step 2: Deploy Infrastructure

```bash
cd infra/terraform/aws

terraform init
terraform plan -var="region=$AWS_REGION"
terraform apply -var="region=$AWS_REGION"
```

**Outputs**:
- `redis_endpoint`: ElastiCache endpoint
- `s3_bucket`: Parquet storage bucket
- `kinesis_clicks_stream`: Stream name
- `glue_database`: Glue catalog database

### Step 3: Create ECS Cluster

```bash
# Create ECS cluster
aws ecs create-cluster --cluster-name s2s-attribution-prod

# Create task definition
aws ecs register-task-definition --cli-input-json file://infra/aws/task-definition.json

# Create service
aws ecs create-service \
  --cluster s2s-attribution-prod \
  --service-name s2s-server \
  --task-definition s2s-attribution:1 \
  --desired-count 2 \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[subnet-xxx],securityGroups=[sg-xxx],assignPublicIp=ENABLED}"
```

### Step 4: Configure Load Balancer

```bash
# Create Application Load Balancer
aws elbv2 create-load-balancer \
  --name s2s-alb \
  --subnets subnet-xxx subnet-yyy \
  --security-groups sg-xxx

# Create target group
aws elbv2 create-target-group \
  --name s2s-targets \
  --protocol HTTP \
  --port 8080 \
  --vpc-id vpc-xxx \
  --health-check-path /health
```

---

## Environment-Specific Configuration

### Development

```bash
NODE_ENV=development
REDIS_HOST=localhost
CLOUD_PROVIDER=gcp
TENANTS='[{"tenant_id":"dev","api_key":"sk_test_dev","name":"Dev","active":true}]'
```

### Staging

```bash
NODE_ENV=staging
REDIS_HOST=staging-redis.example.com
CLOUD_PROVIDER=gcp
TENANTS='[...]' # Load from Secret Manager
```

### Production

```bash
NODE_ENV=production
REDIS_TLS_ENABLED=true
ENABLE_METRICS=true
RATE_LIMIT_MAX_REQUESTS=5000
```

---

## Post-Deployment Checklist

- [ ] Health check returns 200
- [ ] Redis connection is healthy
- [ ] Click tracking creates redirect
- [ ] Postback matching works
- [ ] Events appear in Cloud Storage/S3
- [ ] BigQuery table is populated
- [ ] Monitoring dashboards show data
- [ ] Alerts are configured

---

## Monitoring Setup

### GCP Cloud Monitoring

```bash
# Create uptime check
gcloud monitoring uptime-configs create \
  --display-name="S2S Health Check" \
  --monitored-resource-type="uptime-url" \
  --http-check-url="https://your-url/health"

# Create alert policy
gcloud alpha monitoring policies create \
  --notification-channels=CHANNEL_ID \
  --display-name="S2S High Latency" \
  --condition-display-name="P99 > 10ms" \
  --condition-threshold-value=10
```

### AWS CloudWatch

```bash
# Create alarm
aws cloudwatch put-metric-alarm \
  --alarm-name s2s-high-latency \
  --metric-name Latency \
  --namespace AWS/ApplicationELB \
  --statistic Average \
  --period 300 \
  --threshold 10 \
  --comparison-operator GreaterThanThreshold
```

---

## Rollback Procedure

### GCP

```bash
# List revisions
gcloud run revisions list --service s2s-attribution-prod

# Rollback to previous revision
gcloud run services update-traffic s2s-attribution-prod \
  --to-revisions REVISION_NAME=100
```

### AWS

```bash
# Update service to previous task definition
aws ecs update-service \
  --cluster s2s-attribution-prod \
  --service s2s-server \
  --task-definition s2s-attribution:PREVIOUS_VERSION
```

---

## Scaling Configuration

### Auto-Scaling Rules

**GCP Cloud Run**:
```bash
gcloud run services update s2s-attribution-prod \
  --min-instances 2 \
  --max-instances 200 \
  --cpu-throttling
```

**AWS ECS**:
```bash
aws application-autoscaling register-scalable-target \
  --service-namespace ecs \
  --scalable-dimension ecs:service:DesiredCount \
  --resource-id service/s2s-attribution-prod/s2s-server \
  --min-capacity 2 \
  --max-capacity 100
```

---

## Troubleshooting

### Issue: Redis Connection Timeout

**Solution**:
1. Check VPC connectivity
2. Verify security group rules
3. Test with `redis-cli` from server

### Issue: High Latency

**Solution**:
1. Check Redis memory usage
2. Enable Redis clustering
3. Increase server CPU allocation

### Issue: Low Attribution Rate

**Solution**:
1. Verify Redis TTL configuration
2. Check click_id format in postbacks
3. Query unmatched conversions in BigQuery

---

## Cost Optimization

1. **Use Spot Instances** (AWS) or Preemptible VMs (GCP) for dev/staging
2. **Set BigQuery Table Expiration** (365 days for GDPR compliance)
3. **Enable S3/GCS Lifecycle Policies** (move to cold storage after 90 days)
4. **Right-Size Redis** (start with 1GB, scale based on actual usage)

---

## Security Hardening

1. **Rotate API Keys** every 90 days
2. **Enable Cloud Armor** (GCP) or WAF (AWS) for DDoS protection
3. **Use VPC Service Controls** (GCP) or VPC Endpoints (AWS)
4. **Encrypt Sensitive Environment Variables** in Secret Manager

---

## Next Steps

1. Set up CI/CD pipeline (GitHub Actions / Cloud Build)
2. Configure automated backups
3. Create runbooks for common incidents
4. Set up performance testing with k6
