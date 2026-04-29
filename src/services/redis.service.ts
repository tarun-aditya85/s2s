import Redis from 'ioredis';
import { RedisClickData } from '../types';

export class RedisService {
  private client: Redis;
  private readonly TTL_SECONDS: number;
  private readonly KEY_PREFIX = 'click';

  constructor() {
    const ttlDays = parseInt(process.env.REDIS_TTL_DAYS || '90', 10);
    this.TTL_SECONDS = ttlDays * 24 * 60 * 60;

    this.client = new Redis({
      host: process.env.REDIS_HOST || 'localhost',
      port: parseInt(process.env.REDIS_PORT || '6379', 10),
      password: process.env.REDIS_PASSWORD || undefined,
      tls: process.env.REDIS_TLS_ENABLED === 'true' ? {} : undefined,
      retryStrategy: (times: number) => {
        const delay = Math.min(times * 50, 2000);
        return delay;
      },
      maxRetriesPerRequest: 3,
      enableReadyCheck: true,
      lazyConnect: false,
    });

    this.client.on('error', (err) => {
      console.error('Redis connection error:', err);
    });

    this.client.on('connect', () => {
      console.log('Redis connected successfully');
    });
  }

  /**
   * Generate tenant-specific Redis key
   * Format: click:{tenant_id}:{click_id}
   */
  private getKey(tenantId: string, clickId: string): string {
    return `${this.KEY_PREFIX}:${tenantId}:${clickId}`;
  }

  /**
   * Store click data in Redis with TTL
   * Uses JSON serialization for efficient storage
   */
  async storeClick(
    clickId: string,
    tenantId: string,
    data: RedisClickData
  ): Promise<void> {
    const key = this.getKey(tenantId, clickId);
    const serializedData = JSON.stringify(data);

    await this.client.setex(key, this.TTL_SECONDS, serializedData);
  }

  /**
   * Retrieve click data from Redis
   * Returns null if click_id not found or expired
   */
  async getClick(
    clickId: string,
    tenantId: string
  ): Promise<RedisClickData | null> {
    const key = this.getKey(tenantId, clickId);
    const data = await this.client.get(key);

    if (!data) {
      return null;
    }

    return JSON.parse(data) as RedisClickData;
  }

  /**
   * Delete click data (used after successful conversion)
   * This prevents duplicate postback processing
   */
  async deleteClick(clickId: string, tenantId: string): Promise<void> {
    const key = this.getKey(tenantId, clickId);
    await this.client.del(key);
  }

  /**
   * Check Redis connection health
   * Returns latency in milliseconds
   */
  async healthCheck(): Promise<{ connected: boolean; latency_ms?: number }> {
    try {
      const start = Date.now();
      await this.client.ping();
      const latency = Date.now() - start;

      return {
        connected: true,
        latency_ms: latency,
      };
    } catch (error) {
      return {
        connected: false,
      };
    }
  }

  /**
   * Get tenant-specific click count (useful for analytics)
   */
  async getTenantClickCount(tenantId: string): Promise<number> {
    const pattern = `${this.KEY_PREFIX}:${tenantId}:*`;
    const keys = await this.client.keys(pattern);
    return keys.length;
  }

  /**
   * Graceful shutdown
   */
  async disconnect(): Promise<void> {
    await this.client.quit();
  }

  /**
   * Get Redis client instance (for advanced operations)
   */
  getClient(): Redis {
    return this.client;
  }
}

export default new RedisService();
