-- ============================================================================
-- BigQuery Schema for S2S Attribution Platform
-- ============================================================================
--
-- This schema supports:
-- - Multi-tenant data isolation
-- - Click and postback event tracking
-- - Device and geo attribution
-- - Conversion funnel analysis
-- - Time-series partitioning for efficient queries
--
-- ============================================================================

-- ============================================================================
-- Base Table: events
-- Stores all events (clicks and conversions) with tenant isolation
-- ============================================================================

CREATE TABLE IF NOT EXISTS `${project_id}.s2s_attribution.events`
(
  -- Primary identifiers
  event_id STRING NOT NULL OPTIONS(description="Unique event identifier (UUID)"),
  event_type STRING NOT NULL OPTIONS(description="Event type: click, postback, error"),
  tenant_id STRING NOT NULL OPTIONS(description="Tenant identifier for multi-tenancy"),

  -- Timestamps
  timestamp TIMESTAMP NOT NULL OPTIONS(description="Event timestamp (UTC)"),
  ingestion_timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP() OPTIONS(description="Data ingestion timestamp"),

  -- Click tracking fields
  click_id STRING OPTIONS(description="Unique click identifier (UUID)"),
  ip_address STRING OPTIONS(description="Client IP address (anonymized for GDPR)"),
  user_agent STRING OPTIONS(description="User agent string"),
  referrer STRING OPTIONS(description="HTTP referrer"),
  target_url STRING OPTIONS(description="Destination URL for click redirect"),

  -- UTM parameters
  utm_source STRING OPTIONS(description="Traffic source (e.g., google, facebook)"),
  utm_medium STRING OPTIONS(description="Marketing medium (e.g., cpc, email)"),
  utm_campaign STRING OPTIONS(description="Campaign name"),
  utm_term STRING OPTIONS(description="Campaign keyword term"),
  utm_content STRING OPTIONS(description="Campaign content variant"),

  -- Device information
  device_type STRING OPTIONS(description="Device type: mobile, tablet, desktop"),
  device_brand STRING OPTIONS(description="Device manufacturer"),
  os STRING OPTIONS(description="Operating system"),
  browser STRING OPTIONS(description="Browser name and version"),

  -- Geo-location
  country STRING OPTIONS(description="Country code (ISO 3166-1 alpha-2)"),
  region STRING OPTIONS(description="Region/state"),
  city STRING OPTIONS(description="City name"),

  -- Conversion tracking fields
  conversion_value FLOAT64 OPTIONS(description="Conversion value in currency"),
  currency STRING OPTIONS(description="Currency code (ISO 4217)"),
  order_id STRING OPTIONS(description="Merchant order ID"),
  network_name STRING OPTIONS(description="Affiliate network name"),
  payout FLOAT64 OPTIONS(description="Affiliate payout amount"),
  commission FLOAT64 OPTIONS(description="Commission amount"),

  -- Performance metrics
  latency_ms INT64 OPTIONS(description="Attribution latency (click to conversion)"),
  matched BOOL OPTIONS(description="Whether click_id was matched in Redis"),

  -- Metadata
  processing_timestamp TIMESTAMP OPTIONS(description="Server processing timestamp"),
  partition_date DATE OPTIONS(description="Partition key for time-based partitioning")
)
PARTITION BY partition_date
CLUSTER BY tenant_id, event_type, utm_campaign
OPTIONS(
  description="S2S attribution events - unified table for clicks and conversions",
  require_partition_filter=TRUE,
  partition_expiration_days=365
);

-- ============================================================================
-- Authorized View: clicks_view
-- Pre-filtered view showing only click events
-- ============================================================================

CREATE OR REPLACE VIEW `${project_id}.s2s_attribution.clicks_view` AS
SELECT
  event_id,
  tenant_id,
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
  partition_date
FROM `${project_id}.s2s_attribution.events`
WHERE event_type = 'click';

-- ============================================================================
-- Authorized View: conversions_view
-- Pre-filtered view showing only conversion events
-- ============================================================================

CREATE OR REPLACE VIEW `${project_id}.s2s_attribution.conversions_view` AS
SELECT
  event_id,
  tenant_id,
  timestamp,
  click_id,
  conversion_value,
  currency,
  order_id,
  network_name,
  payout,
  commission,
  latency_ms,
  matched,
  partition_date
FROM `${project_id}.s2s_attribution.events`
WHERE event_type = 'postback';

-- ============================================================================
-- Tenant-Specific Authorized Views
-- These views enforce row-level security for each tenant
-- Replace 'client_001' with actual tenant IDs
-- ============================================================================

-- Example: Tenant-specific view for client_001
CREATE OR REPLACE VIEW `${project_id}.s2s_attribution.tenant_client_001_view` AS
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
FROM `${project_id}.s2s_attribution.events`
WHERE tenant_id = 'client_001';

-- Grant access: Only this view is shared with the client
-- GRANT `roles/bigquery.dataViewer` ON TABLE `${project_id}.s2s_attribution.tenant_client_001_view` TO "user:client@example.com";

-- ============================================================================
-- Attribution Join View
-- Joins clicks with conversions for full funnel analysis
-- ============================================================================

CREATE OR REPLACE VIEW `${project_id}.s2s_attribution.attribution_funnel` AS
WITH clicks AS (
  SELECT
    click_id,
    tenant_id,
    timestamp AS click_timestamp,
    utm_source,
    utm_medium,
    utm_campaign,
    device_type,
    country,
    partition_date
  FROM `${project_id}.s2s_attribution.events`
  WHERE event_type = 'click'
),
conversions AS (
  SELECT
    click_id,
    tenant_id,
    timestamp AS conversion_timestamp,
    conversion_value,
    currency,
    latency_ms,
    matched,
    partition_date
  FROM `${project_id}.s2s_attribution.events`
  WHERE event_type = 'postback' AND matched = TRUE
)
SELECT
  c.click_id,
  c.tenant_id,
  c.click_timestamp,
  cv.conversion_timestamp,
  c.utm_source,
  c.utm_medium,
  c.utm_campaign,
  c.device_type,
  c.country,
  cv.conversion_value,
  cv.currency,
  cv.latency_ms,
  TIMESTAMP_DIFF(cv.conversion_timestamp, c.click_timestamp, SECOND) AS time_to_conversion_seconds
FROM clicks c
LEFT JOIN conversions cv
  ON c.click_id = cv.click_id
  AND c.tenant_id = cv.tenant_id
  AND c.partition_date = cv.partition_date;

-- ============================================================================
-- Materialized View: Daily Metrics (Pre-aggregated for Performance)
-- ============================================================================

CREATE MATERIALIZED VIEW IF NOT EXISTS `${project_id}.s2s_attribution.daily_metrics`
PARTITION BY partition_date
CLUSTER BY tenant_id, utm_campaign
AS
SELECT
  tenant_id,
  DATE(timestamp) AS partition_date,
  utm_source,
  utm_medium,
  utm_campaign,
  country,
  device_type,

  -- Click metrics
  COUNTIF(event_type = 'click') AS total_clicks,

  -- Conversion metrics
  COUNTIF(event_type = 'postback' AND matched = TRUE) AS total_conversions,
  COUNTIF(event_type = 'postback' AND matched = FALSE) AS unmatched_conversions,

  -- Conversion rate
  SAFE_DIVIDE(
    COUNTIF(event_type = 'postback' AND matched = TRUE),
    COUNTIF(event_type = 'click')
  ) AS conversion_rate,

  -- Revenue metrics
  SUM(IF(event_type = 'postback' AND matched = TRUE, conversion_value, 0)) AS total_revenue,
  AVG(IF(event_type = 'postback' AND matched = TRUE, conversion_value, NULL)) AS avg_order_value,

  -- Performance metrics
  AVG(IF(event_type = 'postback' AND matched = TRUE, latency_ms, NULL)) AS avg_latency_ms,
  APPROX_QUANTILES(IF(event_type = 'postback' AND matched = TRUE, latency_ms, NULL), 100)[OFFSET(99)] AS p99_latency_ms,

  -- Attribution accuracy
  SAFE_DIVIDE(
    COUNTIF(event_type = 'postback' AND matched = TRUE),
    COUNTIF(event_type = 'postback')
  ) AS attribution_accuracy

FROM `${project_id}.s2s_attribution.events`
WHERE partition_date >= DATE_SUB(CURRENT_DATE(), INTERVAL 90 DAYS)
GROUP BY 1, 2, 3, 4, 5, 6, 7;

-- ============================================================================
-- Indexes for Performance (BigQuery Search Indexes)
-- Available in BigQuery Enterprise/Enterprise Plus editions
-- ============================================================================

-- CREATE SEARCH INDEX click_id_index ON `${project_id}.s2s_attribution.events`(click_id);
-- CREATE SEARCH INDEX tenant_id_index ON `${project_id}.s2s_attribution.events`(tenant_id);
