/**
 * CoinTracer — Redis Event Bus
 *
 * Provides pub/sub event system for inter-service communication.
 * Services publish domain events (e.g., user.deleted) and subscribe
 * to events from other services for eventual consistency.
 *
 * Usage:
 *   const { eventBus } = require('@cointracer/shared');
 *
 *   // Publish an event
 *   await eventBus.publish('user.deleted', { userId: '...' });
 *
 *   // Subscribe to events
 *   eventBus.subscribe('user.deleted', async (data) => {
 *     await deleteUserData(data.userId);
 *   });
 */

const Redis = require('ioredis');

const REDIS_URL = process.env.REDIS_URL || 'redis://localhost:6379';
const CHANNEL_PREFIX = 'cointracer:events:';

let publisher = null;
let subscriber = null;
const handlers = new Map(); // channel -> [handler1, handler2, ...]
let isConnected = false;

/**
 * Create a Redis connection with error handling
 */
function createConnection(name) {
  const conn = new Redis(REDIS_URL, {
    maxRetriesPerRequest: 3,
    retryStrategy(times) {
      if (times > 10) {
        console.error(`[EventBus] ${name}: Max retries reached, giving up`);
        return null; // Stop retrying
      }
      const delay = Math.min(times * 200, 5000);
      console.warn(`[EventBus] ${name}: Retry #${times} in ${delay}ms`);
      return delay;
    },
    lazyConnect: true,
  });

  conn.on('connect', () => {
    console.log(`[EventBus] ${name}: Connected to Redis`);
  });

  conn.on('error', (err) => {
    // Don't crash the process — Redis is optional for basic operation
    if (err.code !== 'ECONNREFUSED') {
      console.error(`[EventBus] ${name}: Redis error:`, err.message);
    }
  });

  conn.on('close', () => {
    console.warn(`[EventBus] ${name}: Connection closed`);
  });

  return conn;
}

/**
 * Initialize Redis connections (lazy — called on first publish/subscribe)
 */
async function ensureConnected() {
  if (isConnected) return true;

  try {
    if (!publisher) {
      publisher = createConnection('publisher');
      await publisher.connect();
    }
    if (!subscriber) {
      subscriber = createConnection('subscriber');
      await subscriber.connect();

      // Set up message handler
      subscriber.on('message', (channel, message) => {
        const eventName = channel.replace(CHANNEL_PREFIX, '');
        const eventHandlers = handlers.get(eventName) || [];

        let data;
        try {
          data = JSON.parse(message);
        } catch (e) {
          console.error(`[EventBus] Failed to parse message on ${eventName}:`, e.message);
          return;
        }

        console.log(`[EventBus] Received event: ${eventName}`, { dataKeys: Object.keys(data) });

        eventHandlers.forEach(async (handler) => {
          try {
            await handler(data);
          } catch (err) {
            console.error(`[EventBus] Handler error for ${eventName}:`, err.message);
          }
        });
      });
    }

    isConnected = true;
    return true;
  } catch (err) {
    console.warn('[EventBus] Redis not available, events will be skipped:', err.message);
    isConnected = false;
    return false;
  }
}

const eventBus = {
  /**
   * Publish an event to all subscribers
   * @param {string} eventName - Event name (e.g., 'user.deleted')
   * @param {Object} data - Event payload
   */
  async publish(eventName, data) {
    const connected = await ensureConnected();
    if (!connected) {
      console.warn(`[EventBus] Skipping publish for ${eventName} (Redis unavailable)`);
      return false;
    }

    const channel = `${CHANNEL_PREFIX}${eventName}`;
    const message = JSON.stringify({
      event: eventName,
      timestamp: new Date().toISOString(),
      ...data,
    });

    try {
      await publisher.publish(channel, message);
      console.log(`[EventBus] Published: ${eventName}`);
      return true;
    } catch (err) {
      console.error(`[EventBus] Publish error for ${eventName}:`, err.message);
      return false;
    }
  },

  /**
   * Subscribe to an event
   * @param {string} eventName - Event name to listen for
   * @param {Function} handler - Async function called with event data
   */
  async subscribe(eventName, handler) {
    const connected = await ensureConnected();
    if (!connected) {
      console.warn(`[EventBus] Skipping subscribe for ${eventName} (Redis unavailable)`);
      return;
    }

    const channel = `${CHANNEL_PREFIX}${eventName}`;

    // Register handler
    if (!handlers.has(eventName)) {
      handlers.set(eventName, []);
      // Only subscribe to Redis channel once per event name
      await subscriber.subscribe(channel);
      console.log(`[EventBus] Subscribed to: ${eventName}`);
    }

    handlers.get(eventName).push(handler);
  },

  /**
   * Gracefully close Redis connections
   */
  async shutdown() {
    try {
      if (subscriber) {
        await subscriber.unsubscribe();
        subscriber.disconnect();
      }
      if (publisher) {
        publisher.disconnect();
      }
      isConnected = false;
      console.log('[EventBus] Shut down cleanly');
    } catch (err) {
      console.error('[EventBus] Shutdown error:', err.message);
    }
  },

  /**
   * Check if Redis is available
   */
  isAvailable() {
    return isConnected;
  },
};

module.exports = { eventBus };
