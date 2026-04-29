# 🎯 S2S Attribution Server - Privacy-First Multi-Tenant Tracking

**Production-ready Server-to-Server (S2S) attribution platform for B2B SaaS and Finance clients.**

![License](https://img.shields.io/badge/license-MIT-blue.svg)
![Node](https://img.shields.io/badge/node-%3E%3D18.0.0-brightgreen.svg)
![TypeScript](https://img.shields.io/badge/typescript-5.1-blue.svg)

---

## 🚀 Why S2S Attribution?

Traditional pixel-based tracking is **broken**:
- ❌ Apple's ITP blocks third-party cookies (30%+ data loss)
- ❌ Ad blockers strip tracking pixels
- ❌ GDPR/CCPA restrict client-side tracking
- ❌ Mobile in-app tracking is unreliable

**S2S attribution solves this** by tracking events server-side, ensuring:
- ✅ **100% data integrity** (immune to ad blockers)
- ✅ **Privacy-first** (no client-side cookies)
- ✅ **Sub-5ms latency** (Redis-powered redirects)
- ✅ **Multi-tenant isolation** (enterprise-grade security)

---

## 🏗️ Architecture

```
┌─────────────┐    302 Redirect     ┌─────────────┐
│   User      │ ──────────────────> │   Partner   │
│   Click     │  (with click_id)    │   Website   │
└─────────────┘                     └─────────────┘
      │                                     │
      │ POST /click                         │ Conversion
      ▼                                     ▼
┌─────────────────────────────────────────────────┐
│           S2S Attribution Server                 │
│  ┌──────────────┐    ┌──────────────┐          │
│  │ Redis Cache  │    │ Event Stream │          │
│  │ (click_id)   │───>│ (Pub/Sub/    │          │
│  │ TTL: 90 days │    │  Kinesis)    │          │
│  └──────────────┘    └──────────────┘          │
└─────────────────────────────────────────────────┘
                              │
                              ▼
                    ┌──────────────────┐
                    │  Parquet Files   │
                    │  (GCS / S3)      │
                    └──────────────────┘
                              │
                              ▼
                    ┌──────────────────┐
                    │   BigQuery /     │
                    │   Athena         │
                    └──────────────────┘
```

**Flow**:
1. **Click Tracking**: User clicks ad → Server generates `click_id` → Stores metadata in Redis → Redirects to partner site
2. **Conversion Tracking**: Partner sends postback with `click_id` → Server matches in Redis → Logs conversion event
3. **Data Pipeline**: Events stream to Cloud Storage as Parquet → BigQuery for analytics

---

## 📦 Features

### Core Capabilities
- ⚡ **Sub-5ms redirects** (P99) using Redis
- 🔐 **Multi-tenancy** with API key authentication
- 🌍 **Geo-location & device detection** (IP → country, UA → device type)
- 📊 **Real-time event streaming** (GCP Pub/Sub or AWS Kinesis)
- 🗄️ **Parquet storage** (columnar format for efficient queries)
- 🔍 **BigQuery warehouse** with tenant-specific authorized views
- 📈 **Executive dashboards** (CTO, CFO, CMO metrics)

### Security & Compliance
- 🔒 **Tenant isolation** at every layer (Redis keys, storage prefixes, BigQuery views)
- 🛡️ **Fraud prevention** (duplicate postback detection)
- 🔑 **API key rotation** support
- 📝 **Audit logging** for all events

---

## 🚀 Quick Start (10-Minute Deployment)

### Prerequisites
- Node.js 18+
- Redis (local or cloud)
- GCP account (with billing enabled) **OR** AWS account
- Terraform 1.0+

### Step 1: Clone & Install

```bash
git clone https://github.com/your-org/s2s-attribution-server.git
cd s2s-attribution-server
npm install
```

### Step 2: Configure Environment

```bash
cp .env.example .env
```

Edit `.env` with your settings:

```bash
# Server
NODE_ENV=production
PORT=8080

# Redis (use managed service in production)
REDIS_HOST=your-redis-host
REDIS_PORT=6379
REDIS_PASSWORD=your-redis-password
REDIS_TLS_ENABLED=true

# Cloud Provider (gcp or aws)
CLOUD_PROVIDER=gcp

# GCP Configuration
GCP_PROJECT_ID=your-project-id
GCP_PUBSUB_TOPIC_CLICKS=s2s-clicks
GCP_PUBSUB_TOPIC_POSTBACKS=s2s-postbacks

# Multi-Tenancy (JSON format)
TENANTS='[
  {
    "tenant_id": "client_001",
    "api_key": "sk_live_abc123",
    "name": "Acme Corp",
    "active": true
  }
]'
```

### Step 3: Deploy Infrastructure (GCP Example)

```bash
cd infra/terraform/gcp

# Initialize Terraform
terraform init

# Preview changes
terraform plan -var="project_id=your-project-id"

# Deploy
terraform apply -var="project_id=your-project-id" -auto-approve
```

**Output**:
```
cloud_run_url = "https://s2s-attribution-prod-xxx.run.app"
redis_host = "10.0.0.3"
storage_bucket = "your-project-s2s-parquet-prod"
bigquery_dataset = "s2s_attribution_prod"
```

### Step 4: Build & Deploy Server

```bash
# Build TypeScript
npm run build

# Deploy to Cloud Run (GCP)
gcloud run deploy s2s-attribution-prod \
  --source . \
  --region us-central1 \
  --platform managed \
  --allow-unauthenticated

# OR Deploy to ECS Fargate (AWS)
# (See AWS deployment guide)
```

### Step 5: Initialize BigQuery Schema

```bash
# Replace ${project_id} in schema.sql
sed -i '' 's/${project_id}/your-project-id/g' infra/bigquery/schema.sql

# Load schema
bq query --use_legacy_sql=false < infra/bigquery/schema.sql
```

### Step 6: Test the Endpoints

```bash
# Test health check
curl https://your-server-url/health

# Test click tracking
curl -X POST https://your-server-url/click \
  -H "X-API-Key: sk_live_abc123" \
  -H "Content-Type: application/json" \
  -d '{
    "url": "https://partner.com/landing-page",
    "utm_source": "google",
    "utm_campaign": "summer_sale"
  }'

# Response: 302 Redirect to https://partner.com/landing-page?click_id=123e4567-e89b-12d3-a456-426614174000

# Test conversion tracking
curl -X POST https://your-server-url/postback \
  -H "X-API-Key: sk_live_abc123" \
  -H "Content-Type: application/json" \
  -d '{
    "click_id": "123e4567-e89b-12d3-a456-426614174000",
    "conversion_value": 99.99,
    "currency": "USD",
    "order_id": "ORDER-12345"
  }'

# Response: {"success": true, "matched": true, "latency_ms": 234}
```

---

## 📚 API Reference

### POST /click

Track a click and redirect to partner site.

**Headers**:
```
X-API-Key: sk_live_abc123
Content-Type: application/json
```

**Request Body**:
```json
{
  "url": "https://partner.com/product",
  "utm_source": "facebook",
  "utm_medium": "cpc",
  "utm_campaign": "q4_promo",
  "utm_term": "running_shoes",
  "utm_content": "ad_variant_a"
}
```

**Response**: `302 Redirect` to `https://partner.com/product?click_id=<uuid>`

**Performance**: <5ms (P99)

---

### POST /postback

Track a conversion (called by affiliate network or partner server).

**Headers**:
```
X-API-Key: sk_live_abc123
Content-Type: application/json
```

**Request Body**:
```json
{
  "click_id": "123e4567-e89b-12d3-a456-426614174000",
  "conversion_value": 149.99,
  "currency": "USD",
  "order_id": "ORD-789",
  "network_name": "Impact.com",
  "payout": 15.00,
  "commission": 10.00
}
```

**Response**:
```json
{
  "success": true,
  "matched": true,
  "click_id": "123e4567-e89b-12d3-a456-426614174000",
  "latency_ms": 234,
  "processing_time_ms": 8
}
```

**Edge Cases**:
- `matched: false` → Click not found (expired or invalid)
- `404` → Click ID not in Redis (TTL expired after 90 days)

---

### GET /health

Health check for load balancers.

**Response**:
```json
{
  "status": "healthy",
  "timestamp": 1703001234567,
  "uptime": 86400,
  "redis": {
    "connected": true,
    "latency_ms": 1
  },
  "cloud": {
    "provider": "gcp",
    "connected": true
  }
}
```

---

## 📊 Analytics & Dashboards

### Executive Metrics

See [DASHBOARD_METRICS.md](docs/DASHBOARD_METRICS.md) for SQL queries.

**CTO Metrics**:
- System uptime (99.95% SLA)
- P99 redirect latency (<5ms)
- Mean time to recovery (MTTR)
- Attribution accuracy (>95%)

**CFO Metrics**:
- ROI per campaign
- Payout integrity (fraud detection)
- CAC vs. LTV cohorts

**CMO Metrics**:
- Multi-touch attribution weights
- Conversion rate by device/geo
- Funnel velocity (time-to-conversion)

### BigQuery Schema

```sql
-- Base table (all events)
s2s_attribution.events
  - Partitioned by: partition_date
  - Clustered by: tenant_id, event_type, utm_campaign

-- Pre-aggregated metrics (materialized view)
s2s_attribution.daily_metrics
  - Refreshes every 4 hours

-- Tenant-specific views (row-level security)
s2s_attribution.tenant_client_001_view
```

**Example Query** (conversion rate by source):
```sql
SELECT
  utm_source,
  COUNT(DISTINCT CASE WHEN event_type = 'click' THEN click_id END) AS clicks,
  COUNT(DISTINCT CASE WHEN event_type = 'postback' THEN click_id END) AS conversions,
  SAFE_DIVIDE(
    COUNT(DISTINCT CASE WHEN event_type = 'postback' THEN click_id END),
    COUNT(DISTINCT CASE WHEN event_type = 'click' THEN click_id END)
  ) * 100 AS conversion_rate
FROM `your-project.s2s_attribution.events`
WHERE partition_date >= CURRENT_DATE() - 30
GROUP BY 1
ORDER BY 4 DESC;
```

---

## 🔧 Advanced Configuration

### Redis Tuning

For high-volume deployments (>10K RPS):

```bash
# Redis config
maxmemory-policy allkeys-lru
maxmemory 10gb
save "" # Disable RDB snapshots (use AOF)
appendonly yes
appendfsync everysec
```

### Rate Limiting

Default: 1000 requests/minute per IP. Adjust in `.env`:

```bash
RATE_LIMIT_WINDOW_MS=60000
RATE_LIMIT_MAX_REQUESTS=5000
```

### Multi-Region Deployment

For global scale, deploy to multiple regions:

1. **GCP**: Use Global Load Balancer with Cloud Run in 3+ regions
2. **AWS**: Use Route 53 with latency-based routing to ECS clusters
3. **Redis**: Use Memorystore Global Replication (GCP) or ElastiCache Global Datastore (AWS)

---

## 🧪 Testing

### Unit Tests

```bash
npm run test:unit
```

### Integration Tests

```bash
# Start local Redis
docker run -d -p 6379:6379 redis:7

# Run integration tests
npm run test:integration
```

### Load Testing

```bash
# Install k6
brew install k6

# Run load test (10K RPS for 1 minute)
k6 run --vus 100 --duration 1m tests/load/click-test.js
```

**Expected Results**:
- P99 latency: <10ms
- Success rate: >99.9%
- Redis memory: ~500MB for 1M click_ids

---

## 🛡️ Security Best Practices

1. **API Key Management**:
   - Rotate keys every 90 days
   - Use prefix `sk_live_` for production, `sk_test_` for staging
   - Store in Secret Manager (GCP) or Secrets Manager (AWS)

2. **Network Security**:
   - Use VPC for Redis (private subnet)
   - Enable TLS for all Redis connections
   - Restrict Cloud Run/ECS ingress to HTTPS only

3. **Data Privacy**:
   - Hash IP addresses before storage (GDPR compliance)
   - Implement tenant data deletion API
   - Enable audit logging for all API calls

---

## 📈 Scaling Guidelines

| Traffic Volume | Redis Instance | Server Config | Estimated Cost |
|----------------|----------------|---------------|----------------|
| <1K RPS | 1GB Standard | 1 vCPU, 512MB | $50/month |
| 1K-10K RPS | 5GB HA | 2 vCPU, 1GB | $200/month |
| 10K-50K RPS | 20GB HA | 4 vCPU, 2GB | $800/month |
| >50K RPS | Multi-region | Auto-scale 10-100 | $3K+/month |

**Cost Breakdown** (GCP, 10K RPS):
- Cloud Run: $80/month
- Memorystore Redis (5GB HA): $150/month
- Pub/Sub: $40/month
- Cloud Storage: $10/month
- BigQuery: $20/month
- **Total**: ~$300/month

---

## 🐛 Troubleshooting

### Slow Redirects (>10ms)

1. Check Redis latency:
   ```bash
   redis-cli --latency-history
   ```
2. Verify network proximity (server and Redis in same region)
3. Enable Redis connection pooling

### Low Attribution Accuracy (<90%)

1. Check Redis TTL configuration (default: 90 days)
2. Verify postback `click_id` format (must be valid UUID)
3. Review unmatched conversions:
   ```sql
   SELECT * FROM events WHERE event_type = 'postback' AND matched = FALSE LIMIT 100;
   ```

### High Memory Usage

Redis memory grows by ~500 bytes per click_id. For 10M active click_ids:
- Expected memory: ~5GB
- Enable `maxmemory-policy allkeys-lru` to auto-evict old keys

---

## 🤝 Contributing

Contributions welcome! Please open an issue or PR.

---

## 📄 License

MIT License - See [LICENSE](LICENSE) for details.

---

## 🙌 Credits

Built by **Lalitha M V** for production-scale affiliate attribution.

Inspired by:
- Shopify's S2S tracking architecture
- Impact.com's postback protocol
- Stripe's multi-tenant API design

---

## 📞 Support

- **Issues**: [GitHub Issues](https://github.com/your-org/s2s-attribution-server/issues)
- **Documentation**: [docs/](docs/)
- **Email**: support@yourcompany.com

---

**⭐ Star this repo if you found it useful!**
