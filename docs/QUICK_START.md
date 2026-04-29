# Quick Start Guide - S2S Attribution Server

Get your S2S attribution platform running in under 10 minutes.

---

## Prerequisites

- Node.js 18+ installed
- Redis running locally or access to cloud Redis
- GCP or AWS account (for production deployment)

---

## Local Development Setup

### 1. Clone and Install

```bash
git clone https://github.com/your-org/s2s-attribution-server.git
cd s2s-attribution-server
npm install
```

### 2. Start Local Redis

**Using Docker**:
```bash
docker run -d -p 6379:6379 --name redis redis:7-alpine
```

**Using Homebrew (macOS)**:
```bash
brew install redis
brew services start redis
```

### 3. Configure Environment

```bash
cp .env.example .env
```

Edit `.env`:
```bash
NODE_ENV=development
PORT=8080
REDIS_HOST=localhost
REDIS_PORT=6379
CLOUD_PROVIDER=gcp
TENANTS='[{"tenant_id":"demo","api_key":"sk_test_demo_key_12345","name":"Demo Tenant","active":true}]'
```

### 4. Start Server

```bash
npm run dev
```

You should see:
```
🚀 S2S Attribution Server Started
Port: 8080
Redis: localhost:6379
```

### 5. Test the API

**Health Check**:
```bash
curl http://localhost:8080/health
```

**Track a Click**:
```bash
curl -X POST http://localhost:8080/click \
  -H "X-API-Key: sk_test_demo_key_12345" \
  -H "Content-Type: application/json" \
  -d '{
    "url": "https://example.com/product",
    "utm_source": "google",
    "utm_campaign": "test_campaign"
  }'
```

Server will redirect with a `click_id`:
```
HTTP/1.1 302 Found
Location: https://example.com/product?click_id=abc-123-def-456
```

**Track a Conversion**:
```bash
curl -X POST http://localhost:8080/postback \
  -H "X-API-Key: sk_test_demo_key_12345" \
  -H "Content-Type: application/json" \
  -d '{
    "click_id": "abc-123-def-456",
    "conversion_value": 99.99,
    "currency": "USD",
    "order_id": "ORDER-12345"
  }'
```

Response:
```json
{
  "success": true,
  "matched": true,
  "click_id": "abc-123-def-456",
  "latency_ms": 234,
  "processing_time_ms": 8
}
```

---

## Production Deployment (GCP)

### Option A: Automated Script (Recommended)

```bash
# Set your GCP project ID
export GCP_PROJECT_ID="your-project-id"

# Run deployment script
chmod +x scripts/deploy-gcp.sh
./scripts/deploy-gcp.sh
```

That's it! The script will:
1. Enable required GCP APIs
2. Deploy infrastructure with Terraform
3. Build and push Docker image
4. Deploy to Cloud Run
5. Initialize BigQuery schema

### Option B: Manual Steps

See [DEPLOYMENT.md](DEPLOYMENT.md) for detailed instructions.

---

## Adding a New Tenant

```bash
export GCP_PROJECT_ID="your-project-id"

chmod +x scripts/setup-tenant.sh
./scripts/setup-tenant.sh client_001 "Acme Corp" client@acme.com
```

This will:
1. Create a BigQuery authorized view for the tenant
2. Grant access to the client's email
3. Generate an API key
4. Save configuration to Secret Manager

---

## Generating Test Data

```bash
# Generate 100 test clicks and 30 conversions
chmod +x scripts/generate-test-data.sh
./scripts/generate-test-data.sh 100
```

---

## Viewing Your Data

### BigQuery Console

```sql
-- Total events today
SELECT
  event_type,
  COUNT(*) as count
FROM `your-project.s2s_attribution.events`
WHERE partition_date = CURRENT_DATE()
GROUP BY 1;

-- Conversion rate by campaign
SELECT
  utm_campaign,
  COUNTIF(event_type = 'click') as clicks,
  COUNTIF(event_type = 'postback' AND matched = TRUE) as conversions,
  SAFE_DIVIDE(
    COUNTIF(event_type = 'postback' AND matched = TRUE),
    COUNTIF(event_type = 'click')
  ) * 100 as conversion_rate
FROM `your-project.s2s_attribution.events`
WHERE partition_date >= CURRENT_DATE() - 7
GROUP BY 1
ORDER BY 4 DESC;
```

### Redis CLI

```bash
# View all click IDs for demo tenant
redis-cli KEYS "click:demo:*"

# Get click data
redis-cli GET "click:demo:abc-123-def-456"
```

---

## Common Issues

### "Redis connection refused"

**Solution**: Start Redis locally:
```bash
docker run -d -p 6379:6379 redis:7-alpine
```

### "Invalid API key"

**Solution**: Check your `.env` file. The API key must match what's in the `TENANTS` variable.

### "Click ID not found" (404 on postback)

**Possible reasons**:
1. Click ID expired (90-day TTL)
2. Click ID never existed (typo in click_id)
3. Wrong tenant (API key doesn't match)

**Debug**:
```bash
redis-cli GET "click:demo:YOUR_CLICK_ID"
```

---

## Next Steps

1. **Set up monitoring**: See [DEPLOYMENT.md](DEPLOYMENT.md#monitoring-setup)
2. **Review metrics**: See [DASHBOARD_METRICS.md](DASHBOARD_METRICS.md)
3. **Understand architecture**: See [ARCHITECTURE.md](ARCHITECTURE.md)
4. **Integrate with your app**: Use the API endpoints in your tracking code

---

## API Reference Summary

| Endpoint | Method | Auth | Purpose |
|----------|--------|------|---------|
| `/health` | GET | None | Health check |
| `/click` | POST | API Key | Track click, get redirect |
| `/postback` | POST | API Key | Track conversion |

**Authentication Header**: `X-API-Key: sk_live_your_key`

---

## Performance Benchmarks

On a single Cloud Run instance (2 vCPU, 512MB):
- **Throughput**: 10,000 RPS
- **P50 Latency**: 2ms
- **P99 Latency**: 8ms
- **Redis Memory**: ~500MB per 1M click_ids

---

## Support

- **Issues**: [GitHub Issues](https://github.com/your-org/s2s-attribution-server/issues)
- **Documentation**: [docs/](.)
- **Examples**: [tests/](../tests)

---

**Ready to scale?** See [DEPLOYMENT.md](DEPLOYMENT.md) for production setup.
