import { RedisService } from '../../src/services/redis.service';
import { RedisClickData } from '../../src/types';

describe('RedisService', () => {
  let redisService: RedisService;
  const mockTenantId = 'test_tenant';
  const mockClickId = 'test-click-123';

  beforeAll(() => {
    process.env.REDIS_HOST = 'localhost';
    process.env.REDIS_PORT = '6379';
    process.env.REDIS_TTL_DAYS = '90';
    redisService = new RedisService();
  });

  afterAll(async () => {
    await redisService.disconnect();
  });

  describe('storeClick', () => {
    it('should store click data in Redis', async () => {
      const clickData: RedisClickData = {
        tenant_id: mockTenantId,
        timestamp: Date.now(),
        ip_address: '192.168.1.1',
        user_agent: 'Mozilla/5.0',
        referrer: 'https://google.com',
        target_url: 'https://partner.com',
        utm_source: 'google',
        utm_campaign: 'test',
      };

      await expect(
        redisService.storeClick(mockClickId, mockTenantId, clickData)
      ).resolves.not.toThrow();
    });
  });

  describe('getClick', () => {
    it('should retrieve stored click data', async () => {
      const clickData: RedisClickData = {
        tenant_id: mockTenantId,
        timestamp: Date.now(),
        ip_address: '192.168.1.1',
        user_agent: 'Mozilla/5.0',
        referrer: 'https://google.com',
        target_url: 'https://partner.com',
      };

      await redisService.storeClick(mockClickId, mockTenantId, clickData);
      const retrieved = await redisService.getClick(mockClickId, mockTenantId);

      expect(retrieved).toEqual(clickData);
    });

    it('should return null for non-existent click', async () => {
      const retrieved = await redisService.getClick('non-existent', mockTenantId);
      expect(retrieved).toBeNull();
    });
  });

  describe('deleteClick', () => {
    it('should delete click data', async () => {
      const clickData: RedisClickData = {
        tenant_id: mockTenantId,
        timestamp: Date.now(),
        ip_address: '192.168.1.1',
        user_agent: 'Mozilla/5.0',
        referrer: 'https://google.com',
        target_url: 'https://partner.com',
      };

      await redisService.storeClick(mockClickId, mockTenantId, clickData);
      await redisService.deleteClick(mockClickId, mockTenantId);

      const retrieved = await redisService.getClick(mockClickId, mockTenantId);
      expect(retrieved).toBeNull();
    });
  });

  describe('healthCheck', () => {
    it('should return connection status', async () => {
      const health = await redisService.healthCheck();

      expect(health).toHaveProperty('connected');
      expect(health.connected).toBe(true);
      expect(health).toHaveProperty('latency_ms');
      expect(typeof health.latency_ms).toBe('number');
    });
  });
});
