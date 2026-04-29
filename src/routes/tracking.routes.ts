import { Router, Request, Response } from 'express';
import { v4 as uuidv4 } from 'uuid';
import redisService from '../services/redis.service';
import eventStreamService from '../services/event-stream.service';
import {
  parseUserAgent,
  parseGeoLocation,
  extractUTMParams,
  sanitizeUrl,
  getClientIP,
} from '../utils/device-parser';
import { ClickEvent, PostbackEvent, RedisClickData } from '../types';

const router = Router();

/**
 * POST /click
 * Core click tracking endpoint
 *
 * Flow:
 * 1. Generate unique click_id (UUID)
 * 2. Capture metadata (IP, UA, Referrer, UTMs)
 * 3. Store in Redis with 90-day TTL
 * 4. Publish to event stream (GCP Pub/Sub or AWS Kinesis)
 * 5. Issue 302 redirect to target URL with click_id appended
 *
 * Performance Target: <5ms (P99)
 */
router.post('/click', async (req: Request, res: Response) => {
  const startTime = Date.now();
  const tenant_id = (req as any).tenant_id;

  try {
    const { url, utm_source, utm_medium, utm_campaign, utm_term, utm_content } =
      req.body;

    // Validate required fields
    if (!url) {
      res.status(400).json({
        error: 'Bad Request',
        message: 'Missing required field: url',
      });
      return;
    }

    // Sanitize and validate URL
    let targetUrl: string;
    try {
      targetUrl = sanitizeUrl(url);
    } catch (error) {
      res.status(400).json({
        error: 'Bad Request',
        message: 'Invalid URL format',
      });
      return;
    }

    // Generate unique click_id
    const click_id = uuidv4();

    // Extract metadata
    const ip_address = getClientIP(req.headers as any);
    const user_agent = req.headers['user-agent'] || 'unknown';
    const referrer = req.headers['referer'] || req.headers['referrer'] || '';

    // Parse device and geo info
    const deviceInfo = parseUserAgent(user_agent);
    const geoInfo = parseGeoLocation(ip_address);

    // Extract UTM parameters (from body or URL)
    const utmParams =
      utm_source || utm_medium || utm_campaign || utm_term || utm_content
        ? { utm_source, utm_medium, utm_campaign, utm_term, utm_content }
        : extractUTMParams(targetUrl);

    // Prepare Redis data
    const redisData: RedisClickData = {
      tenant_id,
      timestamp: Date.now(),
      ip_address,
      user_agent,
      referrer,
      target_url: targetUrl,
      ...utmParams,
      ...deviceInfo,
      ...geoInfo,
    };

    // Store in Redis (critical path - must be fast)
    await redisService.storeClick(click_id, tenant_id, redisData);

    // Prepare click event for streaming
    const clickEvent: ClickEvent = {
      click_id,
      tenant_id,
      timestamp: Date.now(),
      ip_address,
      user_agent,
      referrer,
      target_url: targetUrl,
      ...utmParams,
      ...deviceInfo,
      ...geoInfo,
    };

    // Publish to event stream (non-blocking - fire and forget)
    eventStreamService.publishClickEvent(clickEvent).catch((error) => {
      console.error('Failed to publish click event:', error);
    });

    // Construct redirect URL with click_id
    const redirectUrl = new URL(targetUrl);
    redirectUrl.searchParams.set('click_id', click_id);

    const latency = Date.now() - startTime;

    // Issue 302 redirect
    res.redirect(302, redirectUrl.toString());

    // Log performance (for monitoring)
    if (latency > 10) {
      console.warn(`Slow click processing: ${latency}ms for ${click_id}`);
    }
  } catch (error) {
    const latency = Date.now() - startTime;
    console.error('Click endpoint error:', error);

    // Log error event
    eventStreamService
      .publishErrorEvent({
        tenant_id,
        timestamp: Date.now(),
        error_type: 'click_processing_error',
        error_message:
          error instanceof Error ? error.message : 'Unknown error',
        request_path: '/click',
        ip_address: getClientIP(req.headers as any),
      })
      .catch(console.error);

    res.status(500).json({
      error: 'Internal Server Error',
      message: 'Failed to process click',
    });
  }
});

/**
 * POST /postback
 * Conversion tracking endpoint (ingress from affiliate networks)
 *
 * Flow:
 * 1. Receive conversion signal with click_id
 * 2. Lookup click_id in Redis
 * 3. If found, calculate latency and publish conversion event
 * 4. Delete click_id from Redis (prevent duplicate postbacks)
 * 5. Return success response
 *
 * Performance Target: <10ms (P99)
 */
router.post('/postback', async (req: Request, res: Response) => {
  const startTime = Date.now();
  const tenant_id = (req as any).tenant_id;

  try {
    const {
      click_id,
      conversion_value,
      currency = 'USD',
      order_id,
      network_name,
      payout,
      commission,
    } = req.body;

    // Validate required fields
    if (!click_id || conversion_value === undefined) {
      res.status(400).json({
        error: 'Bad Request',
        message: 'Missing required fields: click_id, conversion_value',
      });
      return;
    }

    // Lookup click_id in Redis
    const clickData = await redisService.getClick(click_id, tenant_id);

    if (!clickData) {
      // Click not found or expired
      const postbackEvent: PostbackEvent = {
        click_id,
        tenant_id,
        timestamp: Date.now(),
        conversion_value: parseFloat(conversion_value),
        currency,
        order_id,
        network_name,
        payout: payout ? parseFloat(payout) : undefined,
        commission: commission ? parseFloat(commission) : undefined,
        matched: false,
      };

      // Still publish the event for analytics (unmatched conversions)
      eventStreamService.publishPostbackEvent(postbackEvent).catch((error) => {
        console.error('Failed to publish postback event:', error);
      });

      res.status(404).json({
        error: 'Not Found',
        message: 'Click ID not found or expired',
        matched: false,
      });
      return;
    }

    // Calculate attribution latency
    const latency_ms = Date.now() - clickData.timestamp;

    // Prepare postback event
    const postbackEvent: PostbackEvent = {
      click_id,
      tenant_id,
      timestamp: Date.now(),
      conversion_value: parseFloat(conversion_value),
      currency,
      order_id,
      network_name,
      payout: payout ? parseFloat(payout) : undefined,
      commission: commission ? parseFloat(commission) : undefined,
      latency_ms,
      matched: true,
    };

    // Publish to event stream
    eventStreamService.publishPostbackEvent(postbackEvent).catch((error) => {
      console.error('Failed to publish postback event:', error);
    });

    // Delete click from Redis (prevent duplicate postbacks)
    await redisService.deleteClick(click_id, tenant_id);

    const processingTime = Date.now() - startTime;

    res.status(200).json({
      success: true,
      matched: true,
      click_id,
      latency_ms,
      processing_time_ms: processingTime,
    });
  } catch (error) {
    const processingTime = Date.now() - startTime;
    console.error('Postback endpoint error:', error);

    // Log error event
    eventStreamService
      .publishErrorEvent({
        tenant_id,
        timestamp: Date.now(),
        error_type: 'postback_processing_error',
        error_message:
          error instanceof Error ? error.message : 'Unknown error',
        request_path: '/postback',
        click_id: req.body.click_id,
      })
      .catch(console.error);

    res.status(500).json({
      error: 'Internal Server Error',
      message: 'Failed to process postback',
    });
  }
});

export default router;
