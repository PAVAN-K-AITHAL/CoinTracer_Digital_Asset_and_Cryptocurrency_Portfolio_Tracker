/**
 * CoinTracer — API Gateway (Reverse Proxy)
 *
 * True microservices API Gateway that proxies requests to upstream service
 * containers. Each service runs independently in its own container with
 * its own database schema.
 *
 * In Docker Compose, services are addressed by container name:
 *   http://user-svc:3001, http://portfolio-svc:5000, etc.
 *
 * In local development (without Docker), services run on localhost ports.
 *
 * Routes:
 *   /api/v1/auth/*           → user-service        (:3001)
 *   /api/v1/portfolios/*     → portfolio-service    (:5000)
 *   /api/v1/exchanges/*      → portfolio-service    (:5000)
 *   /api/v1/manual-holdings/* → portfolio-service   (:5000)
 *   /api/v1/market/*         → market-data-service  (:5001)
 *   /api/v1/dashboard/*      → market-data-service  (:5001)
 *   /api/v1/news/*           → market-data-service  (:5001)
 *   /api/v1/favorites/*      → personalization-svc  (:3004)
 *   /api/v1/alerts/*         → alerts-service       (:5002)
 *   /health                  → consolidated health check
 */

require('dotenv').config();

const express = require('express');
const { createProxyMiddleware } = require('http-proxy-middleware');
const {
  corsMiddleware,
  createLogger,
  ServiceClient,
} = require('./shared');

const logger = createLogger('API-Gateway');
const app = express();

// ==========================================================================
// Service URLs (Docker Compose names or localhost fallback)
// ==========================================================================
const SERVICES = {
  user:            process.env.USER_SERVICE_URL            || 'http://localhost:3001',
  portfolio:       process.env.PORTFOLIO_SERVICE_URL       || 'http://localhost:5000',
  market:          process.env.MARKET_SERVICE_URL          || 'http://localhost:5001',
  personalization: process.env.PERSONALIZATION_SERVICE_URL || 'http://localhost:3004',
  alerts:          process.env.ALERTS_SERVICE_URL          || 'http://localhost:5002',
};

// Service clients for health checks
const serviceClients = {
  user:            new ServiceClient(SERVICES.user),
  portfolio:       new ServiceClient(SERVICES.portfolio),
  market:          new ServiceClient(SERVICES.market),
  personalization: new ServiceClient(SERVICES.personalization),
  alerts:          new ServiceClient(SERVICES.alerts),
};

// ==========================================================================
// Global Middleware
// ==========================================================================
app.use(corsMiddleware);

// Request logging
app.use((req, res, next) => {
  logger.http(req.method, req.path);
  next();
});

// ==========================================================================
// Proxy Configuration Helper
// ==========================================================================
function createServiceProxy(target, pathRewrite) {
  return createProxyMiddleware({
    target,
    changeOrigin: true,
    pathRewrite,
    timeout: 30000,
    proxyTimeout: 30000,
    on: {
      proxyReq: (proxyReq, req) => {
        // Forward the original host
        proxyReq.setHeader('X-Forwarded-Host', req.headers.host || '');
        proxyReq.setHeader('X-Forwarded-Proto', req.protocol);
      },
      error: (err, req, res) => {
        logger.error('Proxy error', { target, path: req.path, error: err.message });
        if (!res.headersSent) {
          res.status(502).json({
            error: 'Service unavailable',
            message: `Could not connect to upstream service`,
            path: req.path,
          });
        }
      },
    },
  });
}

// ==========================================================================
// Health Check — Consolidated (checks all upstream services)
// ==========================================================================
app.get('/health', async (req, res) => {
  const checks = {};
  let allHealthy = true;

  for (const [name, client] of Object.entries(serviceClients)) {
    try {
      await client.get('/health');
      checks[name] = 'healthy';
    } catch (err) {
      checks[name] = `unhealthy: ${err.message}`;
      allHealthy = false;
    }
  }

  const status = allHealthy ? 'healthy' : 'degraded';
  res.status(allHealthy ? 200 : 207).json({
    status,
    service: 'CoinTracer API Gateway',
    version: '2.0.0',
    architecture: 'microservices',
    uptime: process.uptime(),
    timestamp: new Date().toISOString(),
    environment: process.env.NODE_ENV || 'development',
    services: checks,
  });
});

// ==========================================================================
// Service Proxies
// ==========================================================================

// --- User Service (auth) ---
app.use('/api/v1/auth', createServiceProxy(SERVICES.user));

// --- Portfolio Service (exchange-connections) ---
app.use('/api/v1/portfolios', createServiceProxy(SERVICES.portfolio));
app.use('/api/v1/exchanges', createServiceProxy(SERVICES.portfolio));
app.use('/api/v1/manual-holdings', createServiceProxy(SERVICES.portfolio));

// --- Market Data Service ---
app.use('/api/v1/market', createServiceProxy(SERVICES.market));
app.use('/api/v1/dashboard', createServiceProxy(SERVICES.market));
app.use('/api/v1/news', createServiceProxy(SERVICES.market));

// --- Personalization Service (favorites) ---
app.use('/api/v1/favorites', createServiceProxy(SERVICES.personalization));

// --- Alerts Service ---
app.use('/api/v1/alerts', createServiceProxy(SERVICES.alerts));

// ==========================================================================
// Fallback — 404 for unmatched routes
// ==========================================================================
app.use((req, res) => {
  res.status(404).json({
    error: 'Not Found',
    message: `Route ${req.method} ${req.path} does not exist`,
    availableRoutes: [
      '/health',
      '/api/v1/auth/*',
      '/api/v1/portfolios/*',
      '/api/v1/exchanges/*',
      '/api/v1/manual-holdings/*',
      '/api/v1/market/*',
      '/api/v1/dashboard/*',
      '/api/v1/news/*',
      '/api/v1/favorites/*',
      '/api/v1/alerts/*',
    ],
  });
});

// ==========================================================================
// Start Server
// ==========================================================================
const PORT = process.env.PORT || 3000;
const server = app.listen(PORT, () => {
  logger.info('CoinTracer API Gateway started', {
    port: PORT,
    architecture: 'microservices (reverse proxy)',
    environment: process.env.NODE_ENV || 'development',
    pid: process.pid,
    upstreamServices: SERVICES,
  });
});

// ==========================================================================
// Graceful Shutdown
// ==========================================================================
const shutdown = (signal) => {
  logger.info(`${signal} received, shutting down gracefully...`);

  server.close(() => {
    logger.info('Gateway shut down cleanly');
    process.exit(0);
  });

  // Force shutdown after 10 seconds
  setTimeout(() => {
    logger.error('Forced shutdown after timeout');
    process.exit(1);
  }, 10000);
};

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));

module.exports = app;
