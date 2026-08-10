const express = require('express');
require('dotenv').config();

const config = require('./config/config');
const {
  database,
  corsMiddleware,
  errorHandler,
  notFoundHandler,
  createLogger,
  healthCheck,
  checkDatabase,
  eventBus
} = require('../shared');

// Import routes
const portfolioRoutes = require('./routes/portfolio.routes');
const exchangeRoutes = require('./routes/exchange.routes');
const manualHoldingRoutes = require('./routes/manualHolding.routes');

const logger = createLogger('Exchange-Connections-Service');
const { pool } = database;
const app = express();

// ======================
// Middleware
// ======================
app.use(corsMiddleware);
app.use(express.json({ limit: '50mb' }));
app.use(express.urlencoded({ extended: true, limit: '50mb' }));

// Logging middleware
app.use((req, res, next) => {
  logger.http(req.method, req.path);
  next();
});

// ======================
// Health Check
// ======================
app.get('/health', healthCheck('Portfolio & Exchange Service', '3.0.0', async () => {
  return await checkDatabase(pool);
}));

// ======================
// API Routes
// ======================
app.use('/api/v1/portfolios', portfolioRoutes);
app.use('/api/v1/exchanges', exchangeRoutes);
app.use('/api/v1/manual-holdings', manualHoldingRoutes);

// ======================
// Error Handlers
// ======================
app.use(notFoundHandler);
app.use(errorHandler);

// ======================
// Start Server
// ======================
const PORT = config.port || 5000;
const server = app.listen(PORT, () => {
  logger.info('Portfolio & Exchange Service started', {
    port: PORT,
    version: '3.0.0',
    features: [
      'Portfolio Management',
      'Transaction Tracking',
      'Spot Trading History',
      'Conversion History',
      'Wallet Address Display',
      'P&L Calculations',
      'Exchange Integration'
    ]
  });
  logger.info('API endpoints available', {
    api: `http://localhost:${PORT}/api/v1`,
    health: `http://localhost:${PORT}/health`
  });

  // Subscribe to inter-service events
  eventBus.subscribe('user.deleted', async (data) => {
    const { userId } = data;
    logger.info('Received user.deleted event', { userId });
    try {
      // Delete all portfolios for this user (CASCADE deletes holdings, transactions, etc.)
      const result = await pool.query('DELETE FROM portfolios WHERE user_id = $1', [userId]);
      // Also delete exchange connections
      await pool.query('DELETE FROM exchange_connections WHERE user_id = $1', [userId]);
      logger.info('Cleaned up user data', { userId, portfoliosDeleted: result.rowCount });
    } catch (err) {
      logger.error('Failed to clean up user data', { userId, error: err.message });
    }
  });
});

// ======================
// Graceful Shutdown
// ======================
const shutdown = () => {
  logger.info('Shutdown signal received, closing gracefully...');
  server.close(() => {
    pool.end(() => {
      logger.info('Database connection closed');
      process.exit(0);
    });
  });
};

process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);

module.exports = app;
