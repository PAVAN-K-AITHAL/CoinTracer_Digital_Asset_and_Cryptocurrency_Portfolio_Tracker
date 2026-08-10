/**
 * CoinTracer — Inter-Service HTTP Client
 *
 * Provides a resilient HTTP client for service-to-service communication
 * with retry logic, circuit breaker pattern, and timeout handling.
 *
 * Usage:
 *   const { ServiceClient } = require('@cointracer/shared');
 *   const userClient = new ServiceClient(process.env.USER_SERVICE_URL || 'http://localhost:3001');
 *   const user = await userClient.get('/api/v1/auth/validate/some-uuid');
 */

const http = require('http');
const https = require('https');
const { URL } = require('url');

// Circuit breaker states
const STATES = { CLOSED: 'CLOSED', OPEN: 'OPEN', HALF_OPEN: 'HALF_OPEN' };

class ServiceClient {
  /**
   * @param {string} baseURL - Base URL of the target service
   * @param {Object} options - Configuration options
   * @param {number} options.timeout - Request timeout in ms (default: 5000)
   * @param {number} options.retries - Max retry attempts (default: 2)
   * @param {number} options.retryDelay - Initial retry delay in ms (default: 500)
   * @param {number} options.failureThreshold - Circuit breaker failure threshold (default: 5)
   * @param {number} options.resetTimeout - Circuit breaker reset time in ms (default: 30000)
   */
  constructor(baseURL, options = {}) {
    this.baseURL = baseURL.replace(/\/$/, '');
    this.timeout = options.timeout || 5000;
    this.retries = options.retries || 2;
    this.retryDelay = options.retryDelay || 500;

    // Circuit breaker
    this.state = STATES.CLOSED;
    this.failureCount = 0;
    this.failureThreshold = options.failureThreshold || 5;
    this.resetTimeout = options.resetTimeout || 30000;
    this.lastFailureTime = null;
    this.serviceName = new URL(baseURL).hostname || baseURL;
  }

  /**
   * Make a GET request
   */
  async get(path, options = {}) {
    return this._request('GET', path, null, options);
  }

  /**
   * Make a POST request
   */
  async post(path, body, options = {}) {
    return this._request('POST', path, body, options);
  }

  /**
   * Make a DELETE request
   */
  async delete(path, options = {}) {
    return this._request('DELETE', path, null, options);
  }

  /**
   * Core request method with retries and circuit breaker
   */
  async _request(method, path, body, options = {}) {
    // Circuit breaker check
    if (this.state === STATES.OPEN) {
      if (Date.now() - this.lastFailureTime > this.resetTimeout) {
        this.state = STATES.HALF_OPEN;
        console.log(`[ServiceClient] ${this.serviceName}: Circuit half-open, trying request...`);
      } else {
        throw new Error(`[ServiceClient] Circuit OPEN for ${this.serviceName} — service unavailable`);
      }
    }

    let lastError;
    const maxAttempts = (this.state === STATES.HALF_OPEN) ? 1 : this.retries + 1;

    for (let attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        const result = await this._doRequest(method, path, body, options);
        this._onSuccess();
        return result;
      } catch (err) {
        lastError = err;
        if (attempt < maxAttempts) {
          const delay = this.retryDelay * Math.pow(2, attempt - 1); // Exponential backoff
          console.warn(`[ServiceClient] ${this.serviceName} ${method} ${path} — Retry ${attempt}/${this.retries} in ${delay}ms`);
          await new Promise(resolve => setTimeout(resolve, delay));
        }
      }
    }

    this._onFailure();
    throw lastError;
  }

  /**
   * Execute a single HTTP request
   */
  _doRequest(method, path, body, options) {
    return new Promise((resolve, reject) => {
      const url = new URL(path, this.baseURL);
      const isHttps = url.protocol === 'https:';
      const client = isHttps ? https : http;

      const reqOptions = {
        hostname: url.hostname,
        port: url.port || (isHttps ? 443 : 80),
        path: url.pathname + url.search,
        method,
        timeout: options.timeout || this.timeout,
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
          'X-Service-Client': 'cointracer-internal',
          ...(options.headers || {}),
        },
      };

      // Forward auth token if provided
      if (options.authToken) {
        reqOptions.headers['Authorization'] = `Bearer ${options.authToken}`;
      }

      const req = client.request(reqOptions, (res) => {
        let data = '';
        res.on('data', chunk => { data += chunk; });
        res.on('end', () => {
          try {
            const parsed = data ? JSON.parse(data) : {};

            if (res.statusCode >= 200 && res.statusCode < 300) {
              resolve(parsed);
            } else {
              const err = new Error(parsed.message || parsed.error || `HTTP ${res.statusCode}`);
              err.statusCode = res.statusCode;
              err.response = parsed;
              reject(err);
            }
          } catch (parseErr) {
            reject(new Error(`Failed to parse response from ${this.serviceName}: ${parseErr.message}`));
          }
        });
      });

      req.on('timeout', () => {
        req.destroy();
        reject(new Error(`Request to ${this.serviceName} timed out after ${reqOptions.timeout}ms`));
      });

      req.on('error', (err) => {
        reject(new Error(`Request to ${this.serviceName} failed: ${err.message}`));
      });

      if (body) {
        req.write(JSON.stringify(body));
      }

      req.end();
    });
  }

  _onSuccess() {
    if (this.state === STATES.HALF_OPEN) {
      console.log(`[ServiceClient] ${this.serviceName}: Circuit CLOSED (recovered)`);
    }
    this.failureCount = 0;
    this.state = STATES.CLOSED;
  }

  _onFailure() {
    this.failureCount++;
    this.lastFailureTime = Date.now();

    if (this.failureCount >= this.failureThreshold || this.state === STATES.HALF_OPEN) {
      this.state = STATES.OPEN;
      console.error(`[ServiceClient] ${this.serviceName}: Circuit OPEN after ${this.failureCount} failures`);
    }
  }

  /**
   * Get circuit breaker status
   */
  getStatus() {
    return {
      service: this.serviceName,
      state: this.state,
      failureCount: this.failureCount,
      lastFailure: this.lastFailureTime ? new Date(this.lastFailureTime).toISOString() : null,
    };
  }
}

module.exports = { ServiceClient };
