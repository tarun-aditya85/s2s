import express, { Application } from 'express';
import dotenv from 'dotenv';
import helmet from 'helmet';
import cors from 'cors';
import morgan from 'morgan';
import compression from 'compression';
import rateLimit from 'express-rate-limit';

import trackingRoutes from './routes/tracking.routes';
import healthRoutes from './routes/health.routes';
import { authenticateRequest, loadTenantsFromEnv } from './middleware/auth.middleware';

// Load environment variables
dotenv.config();

const app: Application = express();
const PORT = parseInt(process.env.PORT || '8080', 10);

// ============================================================================
// Middleware Configuration
// ============================================================================

// Security headers
if (process.env.HELMET_ENABLED !== 'false') {
  app.use(helmet());
}

// CORS
const corsOrigins = process.env.CORS_ORIGINS
  ? process.env.CORS_ORIGINS.split(',')
  : '*';
app.use(
  cors({
    origin: corsOrigins,
    credentials: true,
  })
);

// Request logging
if (process.env.NODE_ENV !== 'test') {
  app.use(morgan('combined'));
}

// Body parsing
app.use(express.json());
app.use(express.urlencoded({ extended: true }));

// Compression
app.use(compression());

// Rate limiting (per-IP)
const limiter = rateLimit({
  windowMs: parseInt(process.env.RATE_LIMIT_WINDOW_MS || '60000', 10),
  max: parseInt(process.env.RATE_LIMIT_MAX_REQUESTS || '1000', 10),
  standardHeaders: true,
  legacyHeaders: false,
  message: {
    error: 'Too Many Requests',
    message: 'Rate limit exceeded. Please try again later.',
  },
});

// Apply rate limiting to all routes except health checks
app.use(/^(?!\/health|\/readiness|\/liveness).*$/, limiter);

// ============================================================================
// Routes
// ============================================================================

// Health check routes (no authentication)
app.use('/', healthRoutes);

// Tracking routes (with authentication)
app.use('/', authenticateRequest, trackingRoutes);

// 404 handler
app.use((req, res) => {
  res.status(404).json({
    error: 'Not Found',
    message: `Route ${req.method} ${req.path} not found`,
  });
});

// Error handler
app.use((err: any, req: any, res: any, next: any) => {
  console.error('Unhandled error:', err);
  res.status(500).json({
    error: 'Internal Server Error',
    message: process.env.NODE_ENV === 'production'
      ? 'An unexpected error occurred'
      : err.message,
  });
});

// ============================================================================
// Server Initialization
// ============================================================================

async function startServer(): Promise<void> {
  try {
    // Load tenant configuration
    console.log('Loading tenant configuration...');
    loadTenantsFromEnv();

    // Start server
    app.listen(PORT, '0.0.0.0', () => {
      console.log('='.repeat(60));
      console.log('🚀 S2S Attribution Server Started');
      console.log('='.repeat(60));
      console.log(`Environment: ${process.env.NODE_ENV || 'development'}`);
      console.log(`Port: ${PORT}`);
      console.log(`Cloud Provider: ${process.env.CLOUD_PROVIDER || 'gcp'}`);
      console.log(`Redis: ${process.env.REDIS_HOST}:${process.env.REDIS_PORT}`);
      console.log('='.repeat(60));
      console.log('Endpoints:');
      console.log(`  POST /click      - Track click and redirect`);
      console.log(`  POST /postback   - Track conversion`);
      console.log(`  GET  /health     - Health check`);
      console.log(`  GET  /readiness  - Readiness probe`);
      console.log(`  GET  /liveness   - Liveness probe`);
      console.log('='.repeat(60));
    });
  } catch (error) {
    console.error('Failed to start server:', error);
    process.exit(1);
  }
}

// Graceful shutdown
process.on('SIGTERM', async () => {
  console.log('SIGTERM received. Shutting down gracefully...');
  process.exit(0);
});

process.on('SIGINT', async () => {
  console.log('SIGINT received. Shutting down gracefully...');
  process.exit(0);
});

// Handle unhandled rejections
process.on('unhandledRejection', (reason, promise) => {
  console.error('Unhandled Rejection at:', promise, 'reason:', reason);
});

// Start the server
if (require.main === module) {
  startServer();
}

export default app;
