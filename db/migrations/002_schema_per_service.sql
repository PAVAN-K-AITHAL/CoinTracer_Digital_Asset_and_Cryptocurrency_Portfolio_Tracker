-- ============================================================================
-- CoinTracer — Migration 002: Schema-Per-Service Isolation
-- ============================================================================
-- Migrates from a single shared 'public' schema to isolated per-service schemas.
-- This enables true microservice data ownership.
--
-- Schema mapping:
--   users_svc           → user-service (users table)
--   portfolios_svc      → exchange-connections-service (portfolios, holdings, etc.)
--   personalization_svc → personalization-service (favorites)
--   alerts_svc          → alerts-service (alerts)
--
-- Safe to run multiple times (idempotent).
-- ============================================================================

-- 1. Create schemas
CREATE SCHEMA IF NOT EXISTS users_svc;
CREATE SCHEMA IF NOT EXISTS portfolios_svc;
CREATE SCHEMA IF NOT EXISTS personalization_svc;
CREATE SCHEMA IF NOT EXISTS alerts_svc;

-- ============================================================================
-- 2. Users Schema (user-service owns this)
-- ============================================================================

CREATE TABLE IF NOT EXISTS users_svc.users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email VARCHAR(255) UNIQUE NOT NULL,
    name VARCHAR(255),
    password_hash VARCHAR(255),
    reset_token VARCHAR(255),
    reset_token_expires TIMESTAMP,
    birthday DATE,
    phone_number VARCHAR(20),
    country VARCHAR(100),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_users_email ON users_svc.users(email);
CREATE INDEX IF NOT EXISTS idx_users_reset_token ON users_svc.users(reset_token);

-- ============================================================================
-- 3. Portfolios Schema (exchange-connections-service owns this)
-- ============================================================================
-- NOTE: user_id is a plain UUID — NO foreign key to users_svc.users.
--       This is the key microservice pattern: services own their own data.
--       User existence is validated via HTTP calls, not DB constraints.

CREATE TABLE IF NOT EXISTS portfolios_svc.portfolios (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL,  -- No FK to users_svc.users (microservice boundary)
    name VARCHAR(255) NOT NULL,
    description TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_portfolios_user_id ON portfolios_svc.portfolios(user_id);

CREATE TABLE IF NOT EXISTS portfolios_svc.exchange_connections (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL,  -- No FK to users
    portfolio_id UUID NOT NULL REFERENCES portfolios_svc.portfolios(id) ON DELETE CASCADE,
    exchange VARCHAR(50) NOT NULL,
    api_key_encrypted TEXT NOT NULL,
    api_secret_encrypted TEXT NOT NULL,
    passphrase_encrypted TEXT,
    api_key_hash VARCHAR(64),
    is_active BOOLEAN DEFAULT TRUE,
    last_sync_at TIMESTAMP,
    transactions_synced INTEGER DEFAULT 0,
    sync_status VARCHAR(50) DEFAULT 'idle',
    error_message TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_ec_user_id ON portfolios_svc.exchange_connections(user_id);
CREATE INDEX IF NOT EXISTS idx_ec_portfolio_id ON portfolios_svc.exchange_connections(portfolio_id);
CREATE INDEX IF NOT EXISTS idx_ec_exchange ON portfolios_svc.exchange_connections(exchange);

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'uniq_ec_api_key_hash') THEN
        CREATE UNIQUE INDEX uniq_ec_api_key_hash
            ON portfolios_svc.exchange_connections (exchange, api_key_hash)
            WHERE api_key_hash IS NOT NULL;
    END IF;
END;
$$;

CREATE TABLE IF NOT EXISTS portfolios_svc.holdings (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    portfolio_id UUID NOT NULL REFERENCES portfolios_svc.portfolios(id) ON DELETE CASCADE,
    asset_symbol VARCHAR(50) NOT NULL,
    total_quantity NUMERIC(30,10) DEFAULT 0,
    average_cost NUMERIC(30,10) DEFAULT 0,
    total_invested NUMERIC(30,10) DEFAULT 0,
    current_price NUMERIC(30,10),
    current_value NUMERIC(30,10),
    unrealized_pnl NUMERIC(30,10),
    pnl_percentage NUMERIC(10,2),
    deposit_address VARCHAR(255),
    deposit_tag VARCHAR(100),
    network VARCHAR(50),
    last_updated TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_holdings_portfolio_id ON portfolios_svc.holdings(portfolio_id);
CREATE INDEX IF NOT EXISTS idx_holdings_symbol ON portfolios_svc.holdings(asset_symbol);
CREATE INDEX IF NOT EXISTS idx_holdings_pnl ON portfolios_svc.holdings(unrealized_pnl);

CREATE TABLE IF NOT EXISTS portfolios_svc.manual_holdings (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    portfolio_id UUID NOT NULL REFERENCES portfolios_svc.portfolios(id) ON DELETE CASCADE,
    asset_symbol VARCHAR(50) NOT NULL,
    quantity NUMERIC(30,10) NOT NULL DEFAULT 0,
    average_cost NUMERIC(30,10) DEFAULT NULL,
    notes TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(portfolio_id, asset_symbol)
);
CREATE INDEX IF NOT EXISTS idx_mh_portfolio_id ON portfolios_svc.manual_holdings(portfolio_id);
CREATE INDEX IF NOT EXISTS idx_mh_symbol ON portfolios_svc.manual_holdings(asset_symbol);

CREATE TABLE IF NOT EXISTS portfolios_svc.transactions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    portfolio_id UUID NOT NULL REFERENCES portfolios_svc.portfolios(id) ON DELETE CASCADE,
    connection_id UUID REFERENCES portfolios_svc.exchange_connections(id) ON DELETE CASCADE,
    exchange VARCHAR(50) NOT NULL DEFAULT 'manual',
    type VARCHAR(50) NOT NULL CHECK (
        type IN ('buy','sell','deposit','withdraw','transfer','convert','spot_trade')
    ),
    symbol VARCHAR(50) NOT NULL,
    asset_id VARCHAR(50),
    quantity NUMERIC(30,10) DEFAULT 0,
    price NUMERIC(30,10) DEFAULT 0,
    total_value NUMERIC(30,10) GENERATED ALWAYS AS (quantity * price) STORED,
    fee NUMERIC(30,10) DEFAULT 0,
    fee_currency VARCHAR(10),
    order_id VARCHAR(100),
    trade_id VARCHAR(100),
    wallet_address VARCHAR(255),
    network VARCHAR(50),
    quote_asset VARCHAR(50),
    quote_quantity NUMERIC(30,10),
    conversion_rate NUMERIC(30,10),
    status VARCHAR(50) DEFAULT 'completed',
    transaction_date TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    imported_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_tx_portfolio_id ON portfolios_svc.transactions(portfolio_id);
CREATE INDEX IF NOT EXISTS idx_tx_connection_id ON portfolios_svc.transactions(connection_id);
CREATE INDEX IF NOT EXISTS idx_tx_exchange ON portfolios_svc.transactions(exchange);
CREATE INDEX IF NOT EXISTS idx_tx_symbol ON portfolios_svc.transactions(symbol);
CREATE INDEX IF NOT EXISTS idx_tx_date ON portfolios_svc.transactions(transaction_date);

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'unique_tx_svc' AND connamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'portfolios_svc')
    ) THEN
        ALTER TABLE portfolios_svc.transactions
            ADD CONSTRAINT unique_tx_svc UNIQUE (portfolio_id, trade_id);
    END IF;
EXCEPTION WHEN OTHERS THEN
    NULL;
END;
$$;

CREATE TABLE IF NOT EXISTS portfolios_svc.sync_logs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    connection_id UUID REFERENCES portfolios_svc.exchange_connections(id) ON DELETE CASCADE,
    started_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    ended_at TIMESTAMP,
    status VARCHAR(50) DEFAULT 'started',
    message TEXT
);
CREATE INDEX IF NOT EXISTS idx_sl_connection_id ON portfolios_svc.sync_logs(connection_id);

-- Views & Functions in portfolios_svc schema
CREATE OR REPLACE VIEW portfolios_svc.portfolio_pnl_view AS
SELECT
    h.portfolio_id,
    h.asset_symbol,
    h.total_quantity,
    h.average_cost,
    h.total_invested,
    h.current_price,
    COALESCE(h.current_value, h.total_quantity * COALESCE(h.current_price, h.average_cost, 0)) AS current_value,
    COALESCE(h.unrealized_pnl, (h.total_quantity * COALESCE(h.current_price, h.average_cost, 0)) - h.total_invested) AS unrealized_pnl,
    CASE
        WHEN h.total_invested > 0 THEN
            ((COALESCE(h.unrealized_pnl, (h.total_quantity * COALESCE(h.current_price, h.average_cost, 0)) - h.total_invested) / h.total_invested) * 100)
        ELSE 0
    END AS pnl_percentage,
    h.last_updated,
    p.name AS portfolio_name,
    p.user_id
FROM portfolios_svc.holdings h
JOIN portfolios_svc.portfolios p ON h.portfolio_id = p.id
WHERE h.total_quantity > 0
ORDER BY COALESCE(h.unrealized_pnl, (h.total_quantity * COALESCE(h.current_price, h.average_cost, 0)) - h.total_invested) DESC;

CREATE OR REPLACE FUNCTION portfolios_svc.calculate_portfolio_summary(p_portfolio_id UUID)
RETURNS TABLE (
    total_value NUMERIC,
    total_invested NUMERIC,
    total_pnl NUMERIC,
    total_pnl_percentage NUMERIC,
    asset_count INTEGER
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        COALESCE(SUM(total_quantity * COALESCE(current_price, average_cost, 0)), 0),
        COALESCE(SUM(h.total_invested), 0),
        COALESCE(SUM((total_quantity * COALESCE(current_price, average_cost, 0)) - h.total_invested), 0),
        CASE
            WHEN SUM(h.total_invested) > 0 THEN
                (SUM((total_quantity * COALESCE(current_price, average_cost, 0)) - h.total_invested) / SUM(h.total_invested)) * 100
            ELSE 0
        END,
        COUNT(*)::INTEGER
    FROM portfolios_svc.holdings h
    WHERE h.portfolio_id = p_portfolio_id AND h.total_quantity > 0;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION portfolios_svc.recalculate_holdings_from_transactions(p_portfolio_id UUID)
RETURNS VOID AS $$
DECLARE
  stablecoins TEXT[] := ARRAY['USDT', 'USDC', 'BUSD', 'DAI', 'FDUSD', 'TUSD', 'USDP'];
BEGIN
  DELETE FROM portfolios_svc.holdings WHERE portfolio_id = p_portfolio_id;

  INSERT INTO portfolios_svc.holdings (
    portfolio_id, asset_symbol, total_quantity, average_cost, total_invested, last_updated
  )
  SELECT
    p_portfolio_id, asset_symbol,
    SUM(total_quantity),
    CASE
      WHEN asset_symbol = ANY(stablecoins) THEN NULL
      WHEN SUM(CASE WHEN total_quantity > 0 AND average_cost > 0 THEN total_quantity END) > 0
      THEN SUM(CASE WHEN total_quantity > 0 AND average_cost > 0 THEN total_quantity * average_cost END) /
           SUM(CASE WHEN total_quantity > 0 AND average_cost > 0 THEN total_quantity END)
      ELSE NULL
    END,
    SUM(total_invested),
    NOW()
  FROM (
    SELECT
      COALESCE(NULLIF(t.symbol, ''), t.asset_id) AS asset_symbol,
      SUM(CASE
            WHEN t.type IN ('buy', 'deposit', 'convert') THEN t.quantity
            WHEN t.type IN ('sell', 'withdraw') THEN -t.quantity
            ELSE 0
          END) AS total_quantity,
      CASE
        WHEN SUM(CASE WHEN t.type IN ('buy', 'deposit', 'convert') AND t.price > 0 THEN t.quantity END) > 0
        THEN SUM(CASE WHEN t.type IN ('buy', 'deposit', 'convert') AND t.price > 0 THEN t.quantity * t.price END) /
             SUM(CASE WHEN t.type IN ('buy', 'deposit', 'convert') AND t.price > 0 THEN t.quantity END)
        ELSE NULL
      END AS average_cost,
      COALESCE(SUM(CASE WHEN t.type IN ('buy', 'deposit', 'convert') AND t.price > 0 THEN (t.quantity * t.price) + COALESCE(t.fee, 0) END), 0) AS total_invested
    FROM portfolios_svc.transactions t
    WHERE t.portfolio_id = p_portfolio_id
    GROUP BY COALESCE(NULLIF(t.symbol, ''), t.asset_id)
    UNION ALL
    SELECT
      mh.asset_symbol, mh.quantity,
      COALESCE(mh.average_cost, 0),
      CASE WHEN mh.average_cost > 0 THEN mh.quantity * mh.average_cost ELSE 0 END
    FROM portfolios_svc.manual_holdings mh
    WHERE mh.portfolio_id = p_portfolio_id
  ) combined
  GROUP BY asset_symbol
  HAVING SUM(total_quantity) > 0.00000001;
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- 4. Personalization Schema
-- ============================================================================

CREATE TABLE IF NOT EXISTS personalization_svc.favorites (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id VARCHAR(255) NOT NULL,  -- No FK to users (microservice boundary)
    asset_id VARCHAR(100) NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(user_id, asset_id)
);
CREATE INDEX IF NOT EXISTS idx_fav_user_id ON personalization_svc.favorites(user_id);

-- ============================================================================
-- 5. Alerts Schema
-- ============================================================================

CREATE TABLE IF NOT EXISTS alerts_svc.alerts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id VARCHAR(255) NOT NULL,  -- No FK to users (microservice boundary)
    asset_id VARCHAR(100) NOT NULL,
    asset_symbol VARCHAR(50),
    type VARCHAR(50) NOT NULL CHECK (type IN ('price_target', 'percentage_change')),
    condition VARCHAR(50) NOT NULL CHECK (
        (type = 'price_target' AND condition IN ('above', 'below')) OR
        (type = 'percentage_change' AND condition IN ('increase', 'decrease'))
    ),
    value NUMERIC(20, 8) NOT NULL,
    percentage_timeframe VARCHAR(20) DEFAULT '24h' CHECK (percentage_timeframe IN ('1h', '24h', '7d', '30d')),
    active BOOLEAN NOT NULL DEFAULT true,
    triggered BOOLEAN NOT NULL DEFAULT false,
    triggered_at TIMESTAMP WITH TIME ZONE,
    trigger_count INTEGER DEFAULT 0,
    last_checked_at TIMESTAMP WITH TIME ZONE,
    notification_sent BOOLEAN DEFAULT false,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_alert_user_id ON alerts_svc.alerts(user_id);
CREATE INDEX IF NOT EXISTS idx_alert_active ON alerts_svc.alerts(active, asset_id);
CREATE INDEX IF NOT EXISTS idx_alert_type ON alerts_svc.alerts(type, active);
CREATE INDEX IF NOT EXISTS idx_alert_triggered ON alerts_svc.alerts(triggered, active);

-- ============================================================================
-- 6. Migrate existing data from public schema to service schemas
-- ============================================================================

-- Migrate users
INSERT INTO users_svc.users
SELECT * FROM public.users
ON CONFLICT (id) DO NOTHING;

-- Migrate portfolios (drop FK, keep user_id as plain UUID)
INSERT INTO portfolios_svc.portfolios
SELECT * FROM public.portfolios
ON CONFLICT (id) DO NOTHING;

-- Migrate exchange_connections
INSERT INTO portfolios_svc.exchange_connections
SELECT * FROM public.exchange_connections
ON CONFLICT (id) DO NOTHING;

-- Migrate holdings
INSERT INTO portfolios_svc.holdings
SELECT * FROM public.holdings
ON CONFLICT (id) DO NOTHING;

-- Migrate manual_holdings
INSERT INTO portfolios_svc.manual_holdings
SELECT * FROM public.manual_holdings
ON CONFLICT (id) DO NOTHING;

-- Migrate transactions (skip total_value since it's GENERATED ALWAYS)
INSERT INTO portfolios_svc.transactions (
    id, portfolio_id, connection_id, exchange, type, symbol, asset_id,
    quantity, price, fee, fee_currency, order_id, trade_id,
    wallet_address, network, quote_asset, quote_quantity,
    conversion_rate, status, transaction_date, imported_at
)
SELECT
    id, portfolio_id, connection_id, exchange, type, symbol, asset_id,
    quantity, price, fee, fee_currency, order_id, trade_id,
    wallet_address, network, quote_asset, quote_quantity,
    conversion_rate, status, transaction_date, imported_at
FROM public.transactions
ON CONFLICT (id) DO NOTHING;

-- Migrate sync_logs
INSERT INTO portfolios_svc.sync_logs
SELECT * FROM public.sync_logs
ON CONFLICT (id) DO NOTHING;

-- Migrate favorites
INSERT INTO personalization_svc.favorites
SELECT * FROM public.favorites
ON CONFLICT (id) DO NOTHING;

-- Migrate alerts
INSERT INTO alerts_svc.alerts
SELECT * FROM public.alerts
ON CONFLICT (id) DO NOTHING;

-- ============================================================================
-- Done! The public schema tables remain as a safety net.
-- They can be dropped after verifying everything works:
--   DROP TABLE IF EXISTS public.alerts, public.favorites, public.sync_logs,
--     public.transactions, public.manual_holdings, public.holdings,
--     public.exchange_connections, public.portfolios, public.users CASCADE;
-- ============================================================================
