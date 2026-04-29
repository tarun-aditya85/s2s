// Test setup
process.env.NODE_ENV = 'test';
process.env.REDIS_HOST = 'localhost';
process.env.REDIS_PORT = '6379';
process.env.REDIS_TTL_DAYS = '90';
process.env.CLOUD_PROVIDER = 'gcp';

// Set test timeout
jest.setTimeout(10000);
