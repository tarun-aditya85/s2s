import UAParser from 'ua-parser-js';
import geoip from 'geoip-lite';

export interface DeviceInfo {
  device_type?: string;
  device_brand?: string;
  os?: string;
  browser?: string;
}

export interface GeoInfo {
  country?: string;
  region?: string;
  city?: string;
}

/**
 * Parse User-Agent string to extract device information
 */
export function parseUserAgent(userAgent: string): DeviceInfo {
  const parser = new UAParser(userAgent);
  const result = parser.getResult();

  return {
    device_type: result.device.type || 'desktop',
    device_brand: result.device.vendor || 'unknown',
    os: result.os.name
      ? `${result.os.name} ${result.os.version || ''}`.trim()
      : undefined,
    browser: result.browser.name
      ? `${result.browser.name} ${result.browser.version || ''}`.trim()
      : undefined,
  };
}

/**
 * Extract geo-location from IP address
 * Uses geoip-lite for local lookup (no external API calls)
 */
export function parseGeoLocation(ipAddress: string): GeoInfo {
  const geo = geoip.lookup(ipAddress);

  if (!geo) {
    return {};
  }

  return {
    country: geo.country,
    region: geo.region,
    city: geo.city,
  };
}

/**
 * Extract UTM parameters from URL or query string
 */
export function extractUTMParams(url: string): {
  utm_source?: string;
  utm_medium?: string;
  utm_campaign?: string;
  utm_term?: string;
  utm_content?: string;
} {
  try {
    const parsedUrl = new URL(url);
    const params = parsedUrl.searchParams;

    return {
      utm_source: params.get('utm_source') || undefined,
      utm_medium: params.get('utm_medium') || undefined,
      utm_campaign: params.get('utm_campaign') || undefined,
      utm_term: params.get('utm_term') || undefined,
      utm_content: params.get('utm_content') || undefined,
    };
  } catch {
    return {};
  }
}

/**
 * Sanitize and validate URL
 */
export function sanitizeUrl(url: string): string {
  try {
    const parsed = new URL(url);
    // Only allow http and https protocols
    if (!['http:', 'https:'].includes(parsed.protocol)) {
      throw new Error('Invalid protocol');
    }
    return parsed.toString();
  } catch {
    throw new Error('Invalid URL format');
  }
}

/**
 * Get client IP from request headers (handles proxies)
 */
export function getClientIP(
  headers: Record<string, string | string[] | undefined>
): string {
  // Check common proxy headers
  const xForwardedFor = headers['x-forwarded-for'];
  if (xForwardedFor) {
    const ips = Array.isArray(xForwardedFor)
      ? xForwardedFor[0]
      : xForwardedFor;
    return ips.split(',')[0].trim();
  }

  const xRealIp = headers['x-real-ip'];
  if (xRealIp) {
    return Array.isArray(xRealIp) ? xRealIp[0] : xRealIp;
  }

  return 'unknown';
}
