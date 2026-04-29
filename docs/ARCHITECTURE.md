# S2S Attribution Platform - Architecture

## System Overview

The S2S Attribution Platform is a high-performance, privacy-first tracking system designed for B2B SaaS and Finance clients. It provides server-side click and conversion tracking with sub-5ms latency and 99.95% uptime.

---

## Core Components

### 1. Attribution Server (Node.js + Express)

**Responsibilities**:
- Handle `/click` requests (generate UUID, store in Redis, redirect)
- Handle `/postback` requests (match click_id, log conversion)
- Authentication and tenant isolation
- Event streaming to cloud services

**Performance Targets**:
- `/click` endpoint: <5ms (P99)
- `/postback` endpoint: <10ms (P99)
- Throughput: 10K+ RPS per instance

**Key Technologies**:
- Express.js for HTTP routing
- ioredis for Redis connectivity
- ua-parser-js for device detection
- geoip-lite for geo-location

---

### 2. Redis Cache (Memorystore / ElastiCache)

**Purpose**: Fast click_id storage with automatic expiration.

**Data Structure**:
```
Key: click:{tenant_id}:{click_id}
Value: JSON serialized click metadata
TTL: 90 days (configurable)
```

**Why Redis?**:
- 1ms read latency (vs 50ms for PostgreSQL)
- Automatic TTL expiration (no cleanup jobs needed)
- High availability with replication

**Memory Estimation**:
- 500 bytes per click_id
- 1M clicks = ~500MB
- 10M clicks = ~5GB

---

### 3. Event Streaming Layer

#### GCP Architecture
```
Attribution Server
      │
      ▼
  Pub/Sub Topics (clicks, postbacks, errors)
      │
      ▼
  Dataflow (JSON → Parquet conversion)
      │
      ▼
  Cloud Storage (partitioned Parquet files)
      │
      ▼
  BigQuery (data warehouse)
```

#### AWS Architecture
```
Attribution Server
      │
      ▼
  Kinesis Firehose (auto Parquet conversion)
      │
      ▼
  S3 (partitioned Parquet files)
      │
      ▼
  Athena / Redshift (data warehouse)
```

**Why Parquet?**:
- Columnar format (10x faster queries than JSON)
- Snappy compression (5x smaller than uncompressed JSON)
- Schema evolution support
- Direct BigQuery/Athena integration

---

### 4. Data Warehouse (BigQuery)

**Schema Design**:

```sql
-- Base table (all events)
events (
  event_id STRING,
  event_type STRING, -- 'click' or 'postback'
  tenant_id STRING,
  timestamp TIMESTAMP,
  click_id STRING,
  -- ... 25+ columns
)
PARTITION BY partition_date
CLUSTER BY tenant_id, event_type, utm_campaign
```

**Tenant Isolation**:
- Authorized Views: Each tenant gets a view filtered by `tenant_id`
- Row-level security enforced at BigQuery layer
- No raw table access for clients

**Query Performance**:
- Partitioning: Reduce scan size by 100x
- Clustering: 5-10x faster queries on filtered columns
- Materialized views: Pre-aggregate daily metrics

---

## Data Flow

### Click Tracking Flow

```
1. User clicks ad
   └─> POST /click {url, utm_params}

2. Server generates click_id (UUID v4)

3. Capture metadata:
   - IP → country/city (geoip-lite)
   - User-Agent → device type (ua-parser-js)
   - Referrer, UTM params

4. Store in Redis:
   Key: click:client_001:abc-123-def
   Value: {...metadata}
   TTL: 90 days

5. Publish to Pub/Sub/Kinesis (async, non-blocking)

6. Redirect to partner URL:
   302 → https://partner.com?click_id=abc-123-def
```

**Latency Breakdown**:
- Request parsing: 0.5ms
- Redis write: 1ms
- Redirect response: 0.5ms
- **Total: 2ms** (P50)

---

### Conversion Tracking Flow

```
1. User completes purchase on partner site

2. Partner sends postback:
   POST /postback {
     click_id: "abc-123-def",
     conversion_value: 99.99
   }

3. Server looks up click_id in Redis

4. If found:
   - Calculate latency (conversion_time - click_time)
   - Mark as matched
   - Delete from Redis (prevent duplicates)

5. Publish to Pub/Sub/Kinesis

6. Return success:
   {matched: true, latency_ms: 234}
```

**Attribution Accuracy**:
- Matched conversions: >95%
- Common unmatch reasons:
  - Click_id expired (>90 days)
  - Invalid click_id format
  - Postback received before click (race condition)

---

## Multi-Tenancy

### Tenant Isolation Layers

1. **API Authentication**:
   - Each tenant has unique API key (`sk_live_*`)
   - Validated on every request via middleware
   - Keys stored in Secret Manager (GCP/AWS)

2. **Redis Key Prefixing**:
   ```
   click:tenant_001:abc-123
   click:tenant_002:def-456
   ```
   - Prevents cross-tenant access
   - Simplifies debugging (tenant visible in key)

3. **Cloud Storage Partitioning**:
   ```
   clicks/year=2024/month=01/day=15/tenant_id=client_001/
   clicks/year=2024/month=01/day=15/tenant_id=client_002/
   ```
   - Physical data separation
   - Efficient tenant-specific queries

4. **BigQuery Authorized Views**:
   ```sql
   CREATE VIEW tenant_001_view AS
   SELECT * FROM events WHERE tenant_id = 'client_001';
   ```
   - Client only sees their own data
   - No access to base table

---

## Scaling Strategy

### Horizontal Scaling

**Server Layer**:
- Cloud Run / ECS Fargate: Auto-scale 1-100 instances
- Load balancer distributes traffic
- Stateless design (all state in Redis)

**Redis Layer**:
- Single-region: HA cluster with replication
- Multi-region: Global replication (Memorystore Global / ElastiCache Global Datastore)

**Data Pipeline**:
- Pub/Sub: Auto-scales to millions of messages/sec
- Dataflow: Auto-scaling workers
- BigQuery: Fully managed, scales automatically

### Vertical Scaling

| Traffic | Server | Redis | Monthly Cost |
|---------|--------|-------|--------------|
| 1K RPS | 1 vCPU | 1GB | $50 |
| 10K RPS | 2 vCPU | 5GB | $300 |
| 100K RPS | 4 vCPU | 20GB | $2,000 |

---

## Reliability & Monitoring

### SLOs (Service Level Objectives)

- **Availability**: 99.95% (21 minutes downtime/month)
- **Latency**: P99 < 10ms
- **Error Rate**: < 0.1%

### Monitoring Stack

1. **Health Checks**:
   - `/health`: Load balancer probe (30s interval)
   - `/readiness`: Kubernetes probe
   - `/liveness`: Basic ping

2. **Metrics**:
   - Request latency (P50, P95, P99)
   - Redis connection pool status
   - Attribution match rate
   - Error rate by endpoint

3. **Logging**:
   - Structured JSON logs
   - Cloud Logging / CloudWatch
   - Error tracking with stack traces

4. **Alerting**:
   - PagerDuty integration
   - Alerts: P99 > 10ms for 5 min, Error rate > 1%

---

## Security

### Authentication
- API keys with prefix (`sk_live_`, `sk_test_`)
- Key rotation every 90 days
- Secret Manager for key storage

### Network Security
- Redis in private subnet (VPC)
- TLS for all Redis connections
- HTTPS-only for server endpoints

### Data Privacy
- IP address hashing (GDPR compliance)
- 90-day data retention (configurable)
- Tenant data deletion API

---

## Disaster Recovery

### Backup Strategy

1. **Redis**:
   - AOF persistence enabled
   - Daily snapshots to Cloud Storage
   - RPO: 1 hour, RTO: 15 minutes

2. **BigQuery**:
   - Automatic 7-day time travel
   - Daily exports to GCS for long-term storage

3. **Parquet Files**:
   - Cross-region replication
   - Lifecycle policy: 365 days retention

### Failover Procedure

1. Redis cluster failover: Automatic (HA setup)
2. Server failover: Load balancer auto-detects unhealthy instances
3. Region failover: Manual DNS switch (if multi-region)

---

## Future Enhancements

1. **Real-time Analytics**:
   - Pub/Sub → Dataflow → BigQuery Streaming
   - Live dashboards (refresh every 1 minute)

2. **Machine Learning**:
   - Conversion probability scoring
   - Fraud detection models
   - Budget optimization recommendations

3. **Advanced Attribution**:
   - Multi-touch attribution (linear, time-decay, U-shaped)
   - Cross-device tracking (device graph)
   - Incrementality testing (holdout groups)

---

## References

- [BigQuery Best Practices](https://cloud.google.com/bigquery/docs/best-practices)
- [Redis Memory Optimization](https://redis.io/docs/management/optimization/memory-optimization/)
- [Parquet Format Specification](https://parquet.apache.org/docs/)
