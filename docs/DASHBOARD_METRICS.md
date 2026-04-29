# S2S Attribution Platform - Executive Metrics Dashboard

This document contains SQL queries for generating C-suite metrics that demonstrate the value and performance of the S2S attribution platform.

---

## 📊 CTO Metrics: System Reliability & Performance

### 1. System Uptime (SLA Compliance)

**What it measures**: Percentage of time the tracking server is operational and healthy.

**Target**: 99.95% uptime (SRE standard)

```sql
-- Calculate uptime over the last 30 days based on health check logs
WITH health_checks AS (
  SELECT
    DATE(timestamp) AS check_date,
    COUNTIF(status = 'healthy') AS healthy_checks,
    COUNT(*) AS total_checks
  FROM `${project_id}.s2s_monitoring.health_checks`
  WHERE timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 30 DAY)
  GROUP BY 1
)
SELECT
  AVG(SAFE_DIVIDE(healthy_checks, total_checks)) * 100 AS uptime_percentage,
  MIN(SAFE_DIVIDE(healthy_checks, total_checks)) * 100 AS worst_day_uptime,
  COUNT(DISTINCT check_date) AS days_monitored
FROM health_checks;
```

---

### 2. Redirect Latency (P99)

**What it measures**: 99th percentile latency for click redirect operations.

**Target**: <5ms (P99)

**Why it matters**: Slow redirects = poor user experience and lost conversions.

```sql
-- Calculate P99 latency for /click endpoint over the last 7 days
SELECT
  DATE(timestamp) AS date,
  APPROX_QUANTILES(latency_ms, 100)[OFFSET(50)] AS p50_latency_ms,
  APPROX_QUANTILES(latency_ms, 100)[OFFSET(95)] AS p95_latency_ms,
  APPROX_QUANTILES(latency_ms, 100)[OFFSET(99)] AS p99_latency_ms,
  MAX(latency_ms) AS max_latency_ms
FROM `${project_id}.s2s_monitoring.request_logs`
WHERE
  endpoint = '/click'
  AND timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 7 DAY)
GROUP BY 1
ORDER BY 1 DESC;
```

**Redis Performance**:
```sql
-- Redis lookup latency (critical path)
SELECT
  APPROX_QUANTILES(redis_lookup_ms, 100)[OFFSET(50)] AS p50_redis_ms,
  APPROX_QUANTILES(redis_lookup_ms, 100)[OFFSET(99)] AS p99_redis_ms,
  AVG(redis_lookup_ms) AS avg_redis_ms
FROM `${project_id}.s2s_monitoring.redis_metrics`
WHERE timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 1 DAY);
```

---

### 3. Mean Time to Recovery (MTTR)

**What it measures**: Average time to recover from service degradation or outages.

**Target**: <15 minutes

```sql
-- Calculate MTTR from incident logs
WITH incidents AS (
  SELECT
    incident_id,
    started_at,
    resolved_at,
    TIMESTAMP_DIFF(resolved_at, started_at, MINUTE) AS recovery_time_minutes
  FROM `${project_id}.s2s_monitoring.incidents`
  WHERE
    started_at >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 90 DAY)
    AND resolved_at IS NOT NULL
)
SELECT
  AVG(recovery_time_minutes) AS avg_mttr_minutes,
  APPROX_QUANTILES(recovery_time_minutes, 100)[OFFSET(50)] AS median_mttr_minutes,
  MAX(recovery_time_minutes) AS max_mttr_minutes,
  COUNT(*) AS total_incidents
FROM incidents;
```

---

### 4. Attribution Accuracy

**What it measures**: Percentage of conversions successfully matched to clicks.

**Target**: >95%

**Why it matters**: Low accuracy = revenue leakage and incorrect payouts.

```sql
-- Attribution match rate over the last 30 days
SELECT
  DATE(timestamp) AS date,
  tenant_id,
  COUNTIF(matched = TRUE) AS matched_conversions,
  COUNTIF(matched = FALSE) AS unmatched_conversions,
  COUNT(*) AS total_conversions,
  SAFE_DIVIDE(COUNTIF(matched = TRUE), COUNT(*)) * 100 AS accuracy_percentage
FROM `${project_id}.s2s_attribution.events`
WHERE
  event_type = 'postback'
  AND timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 30 DAY)
GROUP BY 1, 2
ORDER BY 1 DESC, 2;
```

**Unmatched Conversion Analysis** (debugging):
```sql
-- Identify why conversions aren't matching
SELECT
  DATE(timestamp) AS date,
  CASE
    WHEN latency_ms > 7776000000 THEN 'expired_90_days' -- 90 days in ms
    WHEN click_id IS NULL THEN 'missing_click_id'
    ELSE 'click_id_not_found'
  END AS unmatch_reason,
  COUNT(*) AS count
FROM `${project_id}.s2s_attribution.events`
WHERE
  event_type = 'postback'
  AND matched = FALSE
  AND timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 7 DAY)
GROUP BY 1, 2
ORDER BY 1 DESC, 3 DESC;
```

---

## 💰 CFO Metrics: Financial Performance

### 5. ROI per Campaign

**What it measures**: Return on ad spend for each marketing campaign.

**Formula**: (Revenue - Cost) / Cost

```sql
-- Calculate ROI for each campaign over the last 30 days
WITH campaign_performance AS (
  SELECT
    tenant_id,
    utm_campaign,
    COUNT(DISTINCT CASE WHEN event_type = 'click' THEN click_id END) AS total_clicks,
    COUNT(DISTINCT CASE WHEN event_type = 'postback' AND matched = TRUE THEN click_id END) AS total_conversions,
    SUM(CASE WHEN event_type = 'postback' AND matched = TRUE THEN conversion_value ELSE 0 END) AS total_revenue,
    SUM(CASE WHEN event_type = 'postback' AND matched = TRUE THEN payout ELSE 0 END) AS total_payout
  FROM `${project_id}.s2s_attribution.events`
  WHERE
    timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 30 DAY)
    AND utm_campaign IS NOT NULL
  GROUP BY 1, 2
)
SELECT
  tenant_id,
  utm_campaign,
  total_clicks,
  total_conversions,
  SAFE_DIVIDE(total_conversions, total_clicks) * 100 AS conversion_rate,
  total_revenue,
  total_payout,
  total_revenue - total_payout AS net_profit,
  SAFE_DIVIDE(total_revenue - total_payout, total_payout) * 100 AS roi_percentage
FROM campaign_performance
WHERE total_clicks > 100 -- Filter out low-volume campaigns
ORDER BY roi_percentage DESC;
```

---

### 6. Payout Integrity (Fraud Prevention)

**What it measures**: Percentage of payouts that match verified conversions.

**Target**: 100% (no unauthorized payouts)

**Why it matters**: Prevents affiliate fraud and postback spoofing.

```sql
-- Detect suspicious conversion patterns
WITH conversion_patterns AS (
  SELECT
    tenant_id,
    click_id,
    COUNT(*) AS postback_count,
    SUM(conversion_value) AS total_value,
    ARRAY_AGG(DISTINCT network_name IGNORE NULLS) AS networks
  FROM `${project_id}.s2s_attribution.events`
  WHERE
    event_type = 'postback'
    AND timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 7 DAY)
  GROUP BY 1, 2
)
SELECT
  tenant_id,
  click_id,
  postback_count,
  total_value,
  networks,
  CASE
    WHEN postback_count > 1 THEN 'duplicate_postback'
    WHEN total_value > 10000 THEN 'high_value_conversion'
    ELSE 'normal'
  END AS fraud_risk
FROM conversion_patterns
WHERE postback_count > 1 OR total_value > 10000
ORDER BY postback_count DESC, total_value DESC;
```

**Payout Reconciliation**:
```sql
-- Compare expected vs. actual payouts by network
SELECT
  tenant_id,
  network_name,
  DATE_TRUNC(DATE(timestamp), MONTH) AS month,
  COUNT(*) AS conversion_count,
  SUM(conversion_value) AS total_revenue,
  SUM(payout) AS total_payout,
  SUM(commission) AS total_commission,
  SAFE_DIVIDE(SUM(payout), SUM(conversion_value)) * 100 AS payout_percentage
FROM `${project_id}.s2s_attribution.events`
WHERE
  event_type = 'postback'
  AND matched = TRUE
  AND timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 6 MONTH)
GROUP BY 1, 2, 3
ORDER BY 3 DESC, 2;
```

---

### 7. Customer Acquisition Cost (CAC) vs. Lifetime Value (LTV)

**What it measures**: Cost to acquire a customer vs. their long-term value.

**Target**: LTV:CAC ratio > 3:1

```sql
-- Calculate CAC by cohort (month of first purchase)
WITH first_purchase AS (
  SELECT
    tenant_id,
    click_id,
    MIN(timestamp) AS first_purchase_date,
    SUM(conversion_value) AS first_order_value,
    AVG(payout) AS cac
  FROM `${project_id}.s2s_attribution.events`
  WHERE event_type = 'postback' AND matched = TRUE
  GROUP BY 1, 2
),
repeat_purchases AS (
  SELECT
    fp.tenant_id,
    fp.click_id,
    DATE_TRUNC(DATE(fp.first_purchase_date), MONTH) AS cohort_month,
    fp.cac,
    SUM(e.conversion_value) AS ltv
  FROM first_purchase fp
  LEFT JOIN `${project_id}.s2s_attribution.events` e
    ON fp.click_id = e.click_id
    AND e.event_type = 'postback'
    AND e.matched = TRUE
  WHERE e.timestamp <= TIMESTAMP_ADD(fp.first_purchase_date, INTERVAL 90 DAY)
  GROUP BY 1, 2, 3, 4
)
SELECT
  tenant_id,
  cohort_month,
  COUNT(*) AS customers,
  AVG(cac) AS avg_cac,
  AVG(ltv) AS avg_ltv_90_days,
  SAFE_DIVIDE(AVG(ltv), AVG(cac)) AS ltv_cac_ratio
FROM repeat_purchases
GROUP BY 1, 2
ORDER BY 2 DESC;
```

---

## 📈 CMO Metrics: Marketing Performance

### 8. Multi-Touch Attribution Weight

**What it measures**: Contribution of each touchpoint in the conversion funnel.

**Why it matters**: Helps allocate budget to high-performing channels.

```sql
-- Time-decay attribution model (more recent clicks get higher weight)
WITH click_sequence AS (
  SELECT
    tenant_id,
    click_id,
    utm_source,
    utm_medium,
    utm_campaign,
    timestamp AS click_timestamp,
    ROW_NUMBER() OVER (PARTITION BY click_id ORDER BY timestamp) AS click_position,
    COUNT(*) OVER (PARTITION BY click_id) AS total_clicks
  FROM `${project_id}.s2s_attribution.events`
  WHERE event_type = 'click'
),
conversions AS (
  SELECT
    click_id,
    conversion_value
  FROM `${project_id}.s2s_attribution.events`
  WHERE event_type = 'postback' AND matched = TRUE
)
SELECT
  cs.tenant_id,
  cs.utm_source,
  cs.utm_medium,
  COUNT(*) AS total_touches,
  SUM(c.conversion_value * POW(2, cs.click_position - 1) / (POW(2, cs.total_clicks) - 1)) AS weighted_revenue,
  AVG(c.conversion_value) AS avg_order_value
FROM click_sequence cs
INNER JOIN conversions c ON cs.click_id = c.click_id
WHERE cs.click_position <= 5 -- Limit to 5 touchpoints
GROUP BY 1, 2, 3
ORDER BY 5 DESC;
```

---

### 9. Conversion Rate by Device/Location Heuristics

**What it measures**: Which device types and geo-locations convert best.

**Use case**: "Cold start" bidding strategy (bid higher on high-converting segments).

```sql
-- Conversion rate heatmap by device type and country
SELECT
  device_type,
  country,
  COUNT(DISTINCT CASE WHEN event_type = 'click' THEN click_id END) AS clicks,
  COUNT(DISTINCT CASE WHEN event_type = 'postback' AND matched = TRUE THEN click_id END) AS conversions,
  SAFE_DIVIDE(
    COUNT(DISTINCT CASE WHEN event_type = 'postback' AND matched = TRUE THEN click_id END),
    COUNT(DISTINCT CASE WHEN event_type = 'click' THEN click_id END)
  ) * 100 AS conversion_rate,
  AVG(CASE WHEN event_type = 'postback' AND matched = TRUE THEN conversion_value END) AS avg_order_value
FROM `${project_id}.s2s_attribution.events`
WHERE
  timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 30 DAY)
  AND device_type IS NOT NULL
  AND country IS NOT NULL
GROUP BY 1, 2
HAVING clicks > 50 -- Filter out low-volume segments
ORDER BY conversion_rate DESC;
```

**Time-of-Day Heuristics**:
```sql
-- Best performing hours for conversions
SELECT
  EXTRACT(HOUR FROM timestamp) AS hour_of_day,
  EXTRACT(DAYOFWEEK FROM timestamp) AS day_of_week,
  COUNT(DISTINCT CASE WHEN event_type = 'click' THEN click_id END) AS clicks,
  COUNT(DISTINCT CASE WHEN event_type = 'postback' AND matched = TRUE THEN click_id END) AS conversions,
  SAFE_DIVIDE(
    COUNT(DISTINCT CASE WHEN event_type = 'postback' AND matched = TRUE THEN click_id END),
    COUNT(DISTINCT CASE WHEN event_type = 'click' THEN click_id END)
  ) * 100 AS conversion_rate
FROM `${project_id}.s2s_attribution.events`
WHERE timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 30 DAY)
GROUP BY 1, 2
ORDER BY 5 DESC;
```

---

### 10. Funnel Velocity

**What it measures**: Time from click to conversion (purchase decision speed).

**Use case**: Optimize retargeting windows based on conversion latency.

```sql
-- Distribution of time-to-conversion by campaign
SELECT
  tenant_id,
  utm_campaign,
  CASE
    WHEN latency_ms < 3600000 THEN 'under_1_hour'
    WHEN latency_ms < 86400000 THEN '1_to_24_hours'
    WHEN latency_ms < 604800000 THEN '1_to_7_days'
    WHEN latency_ms < 2592000000 THEN '7_to_30_days'
    ELSE 'over_30_days'
  END AS latency_bucket,
  COUNT(*) AS conversions,
  AVG(conversion_value) AS avg_order_value
FROM `${project_id}.s2s_attribution.events`
WHERE
  event_type = 'postback'
  AND matched = TRUE
  AND timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 30 DAY)
GROUP BY 1, 2, 3
ORDER BY 1, 2, 4 DESC;
```

**Median Time to Conversion** (by source):
```sql
-- Median latency by traffic source
SELECT
  utm_source,
  utm_medium,
  COUNT(*) AS conversions,
  APPROX_QUANTILES(latency_ms, 100)[OFFSET(50)] / 1000 AS median_latency_seconds,
  APPROX_QUANTILES(latency_ms, 100)[OFFSET(50)] / 3600000 AS median_latency_hours
FROM `${project_id}.s2s_attribution.events`
WHERE
  event_type = 'postback'
  AND matched = TRUE
  AND timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 30 DAY)
GROUP BY 1, 2
HAVING conversions > 20
ORDER BY 4;
```

---

## 🎯 Bonus Metric: Market Thickness

**What it measures**: Average number of advertisers competing for the same user impression.

**Why it matters**: Indicates auction competitiveness and bidding strategy effectiveness.

```sql
-- Calculate auction overlap (multiple clicks from same IP in short timeframe)
WITH click_windows AS (
  SELECT
    ip_address,
    TIMESTAMP_TRUNC(timestamp, HOUR) AS click_hour,
    COUNT(DISTINCT tenant_id) AS competing_advertisers,
    COUNT(*) AS total_clicks
  FROM `${project_id}.s2s_attribution.events`
  WHERE
    event_type = 'click'
    AND timestamp >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 7 DAY)
    AND ip_address IS NOT NULL
  GROUP BY 1, 2
)
SELECT
  AVG(competing_advertisers) AS avg_market_thickness,
  APPROX_QUANTILES(competing_advertisers, 100)[OFFSET(50)] AS median_thickness,
  MAX(competing_advertisers) AS max_competing_advertisers,
  COUNT(*) AS total_auction_instances
FROM click_windows
WHERE total_clicks > 1;
```

---

## 📊 Visualization Recommendations

### Grafana/Looker Studio Dashboards

1. **CTO Dashboard**: Real-time uptime, P99 latency line charts, MTTR trend
2. **CFO Dashboard**: ROI bar charts by campaign, LTV:CAC cohort analysis, fraud alerts
3. **CMO Dashboard**: Conversion funnel visualization, device heatmap, attribution waterfall

### Alerts

- P99 latency > 10ms for 5 minutes → Page on-call engineer
- Attribution accuracy < 90% → Investigate Redis expiration policy
- Conversion rate drop > 20% day-over-day → Marketing team notification

---

## 🔍 How to Use These Queries

1. **Replace `${project_id}`** with your GCP project ID
2. **Set up scheduled queries** in BigQuery to run daily
3. **Export results** to Google Sheets or BI tools
4. **Create alerts** using BigQuery Data Transfer Service or Cloud Functions

---

## 📝 Notes

- All queries use **partitioned tables** for performance (filter on `timestamp` or `partition_date`)
- **Materialized views** pre-aggregate common metrics (refresh every 4 hours)
- **Authorized views** enforce tenant isolation (clients only see their own data)
- Queries are optimized for **BigQuery SQL** (use `APPROX_QUANTILES` for P99, `SAFE_DIVIDE` for null safety)
