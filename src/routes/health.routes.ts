import { Router, Request, Response } from 'express';
import redisService from '../services/redis.service';
import eventStreamService from '../services/event-stream.service';
import { HealthCheckResponse } from '../types';

const router = Router();

const startTime = Date.now();

/**
 * GET /health
 * Health check endpoint for load balancers and monitoring
 * No authentication required
 */
router.get('/health', async (req: Request, res: Response) => {
  try {
    // Check Redis connection
    const redisHealth = await redisService.healthCheck();

    // Check cloud services connection
    const cloudHealth = await eventStreamService.healthCheck();

    // Determine overall health status
    let status: 'healthy' | 'degraded' | 'unhealthy';
    if (redisHealth.connected && cloudHealth.connected) {
      status = 'healthy';
    } else if (redisHealth.connected || cloudHealth.connected) {
      status = 'degraded';
    } else {
      status = 'unhealthy';
    }

    const healthResponse: HealthCheckResponse = {
      status,
      timestamp: Date.now(),
      uptime: Math.floor((Date.now() - startTime) / 1000),
      redis: redisHealth,
      cloud: cloudHealth,
    };

    const httpStatus = status === 'healthy' ? 200 : status === 'degraded' ? 503 : 503;

    res.status(httpStatus).json(healthResponse);
  } catch (error) {
    console.error('Health check error:', error);
    res.status(503).json({
      status: 'unhealthy',
      timestamp: Date.now(),
      uptime: Math.floor((Date.now() - startTime) / 1000),
      error: error instanceof Error ? error.message : 'Unknown error',
    });
  }
});

/**
 * GET /readiness
 * Readiness probe for Kubernetes
 * Returns 200 if server is ready to accept traffic
 */
router.get('/readiness', async (req: Request, res: Response) => {
  try {
    const redisHealth = await redisService.healthCheck();

    if (redisHealth.connected) {
      res.status(200).json({
        ready: true,
        timestamp: Date.now(),
      });
    } else {
      res.status(503).json({
        ready: false,
        timestamp: Date.now(),
        reason: 'Redis not connected',
      });
    }
  } catch (error) {
    res.status(503).json({
      ready: false,
      timestamp: Date.now(),
      reason: error instanceof Error ? error.message : 'Unknown error',
    });
  }
});

/**
 * GET /liveness
 * Liveness probe for Kubernetes
 * Returns 200 if server is alive (doesn't check dependencies)
 */
router.get('/liveness', (req: Request, res: Response) => {
  res.status(200).json({
    alive: true,
    timestamp: Date.now(),
    uptime: Math.floor((Date.now() - startTime) / 1000),
  });
});

export default router;
