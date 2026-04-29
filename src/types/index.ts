export interface TenantConfig {
  tenant_id: string;
  api_key: string;
  name: string;
  active: boolean;
  created_at: Date;
  rate_limit?: number;
}

export interface ClickEvent {
  click_id: string;
  tenant_id: string;
  timestamp: number;
  ip_address: string;
  user_agent: string;
  referrer: string;
  target_url: string;
  utm_source?: string;
  utm_medium?: string;
  utm_campaign?: string;
  utm_term?: string;
  utm_content?: string;
  device_type?: string;
  device_brand?: string;
  os?: string;
  browser?: string;
  country?: string;
  region?: string;
  city?: string;
}

export interface PostbackEvent {
  click_id: string;
  tenant_id: string;
  timestamp: number;
  conversion_value: number;
  currency: string;
  order_id?: string;
  network_name?: string;
  payout?: number;
  commission?: number;
  latency_ms?: number;
  matched: boolean;
}

export interface ErrorEvent {
  tenant_id: string;
  timestamp: number;
  error_type: string;
  error_message: string;
  click_id?: string;
  request_path: string;
  ip_address?: string;
}

export interface RedisClickData {
  tenant_id: string;
  timestamp: number;
  ip_address: string;
  user_agent: string;
  referrer: string;
  target_url: string;
  utm_source?: string;
  utm_medium?: string;
  utm_campaign?: string;
  utm_term?: string;
  utm_content?: string;
  device_type?: string;
  device_brand?: string;
  os?: string;
  browser?: string;
  country?: string;
  region?: string;
  city?: string;
}

export interface AttributionMetrics {
  total_clicks: number;
  total_conversions: number;
  conversion_rate: number;
  average_latency_ms: number;
  attribution_accuracy: number;
  revenue_tracked: number;
}

export interface ClickRequest {
  url: string;
  utm_source?: string;
  utm_medium?: string;
  utm_campaign?: string;
  utm_term?: string;
  utm_content?: string;
}

export interface PostbackRequest {
  click_id: string;
  conversion_value: number;
  currency?: string;
  order_id?: string;
  network_name?: string;
  payout?: number;
  commission?: number;
}

export interface HealthCheckResponse {
  status: 'healthy' | 'degraded' | 'unhealthy';
  timestamp: number;
  uptime: number;
  redis: {
    connected: boolean;
    latency_ms?: number;
  };
  cloud: {
    provider: string;
    connected: boolean;
  };
}
