const { Pool } = require('pg');
require('dotenv').config();

// Build pool config — prefer DATABASE_URL for cloud deployments (Neon, etc.)
let poolConfig;

if (process.env.DATABASE_URL) {
  poolConfig = {
    connectionString: process.env.DATABASE_URL,
    ssl: { rejectUnauthorized: false },
    max: parseInt(process.env.DB_POOL_MAX, 10) || 5,
    idleTimeoutMillis: 30000,
    connectionTimeoutMillis: 5000,
  };
} else {
  poolConfig = {};  // Falls back to PG* env vars for local dev
}

const pool = new Pool(poolConfig);
const dbSchema = process.env.DB_SCHEMA;

pool.on('connect', async (client) => {
  if (dbSchema) {
    await client.query(`SET search_path TO ${dbSchema}, public`);
  }
});

pool.on('error', (err) => {
  console.error('Unexpected error on idle database client:', err);
});

module.exports = {
  query: (text, params) => pool.query(text, params),
  pool,
  end: () => pool.end()
};
