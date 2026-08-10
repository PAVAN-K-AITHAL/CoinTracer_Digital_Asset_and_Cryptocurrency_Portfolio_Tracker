#!/bin/bash
# ============================================================================
# CoinTracer — OCI Server Setup Script (Microservices Edition)
# ============================================================================
# Run this script on a fresh Oracle Cloud Ubuntu VM to set up the full stack.
#
# Usage:
#   chmod +x deploy/setup.sh
#   sudo ./deploy/setup.sh
#
# Prerequisites:
#   - Ubuntu 22.04 (Oracle Cloud free tier ARM VM)
#   - Root/sudo access
#   - Ports 80 and 443 open in OCI Security List
# ============================================================================

set -euo pipefail

echo "============================================"
echo "  CoinTracer Microservices Server Setup"
echo "============================================"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ============================================================================
# 1. System Updates
# ============================================================================
log_info "Updating system packages..."
apt-get update -y && apt-get upgrade -y

# ============================================================================
# 2. Install Docker & Docker Compose
# ============================================================================
if command -v docker &> /dev/null; then
    log_info "Docker already installed: $(docker --version)"
else
    log_info "Installing Docker..."
    curl -fsSL https://get.docker.com | sh
    usermod -aG docker "$SUDO_USER" 2>/dev/null || true
    systemctl enable docker
    systemctl start docker
    log_info "Docker installed: $(docker --version)"
fi

# Docker Compose v2 comes with Docker, verify it
if docker compose version &> /dev/null; then
    log_info "Docker Compose available: $(docker compose version)"
else
    log_error "Docker Compose not available. Please install Docker CE."
    exit 1
fi

# ============================================================================
# 3. Install Nginx
# ============================================================================
if command -v nginx &> /dev/null; then
    log_info "Nginx already installed: $(nginx -v 2>&1)"
else
    log_info "Installing Nginx..."
    apt-get install -y nginx
    systemctl enable nginx
    systemctl start nginx
    log_info "Nginx installed"
fi

# ============================================================================
# 4. Install Certbot (Let's Encrypt SSL)
# ============================================================================
if command -v certbot &> /dev/null; then
    log_info "Certbot already installed: $(certbot --version)"
else
    log_info "Installing Certbot..."
    apt-get install -y certbot python3-certbot-nginx
    log_info "Certbot installed"
fi

# ============================================================================
# 5. Configure Firewall (iptables)
# ============================================================================
log_info "Configuring firewall rules..."

# Allow HTTP
iptables -C INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || \
    iptables -I INPUT -p tcp --dport 80 -j ACCEPT

# Allow HTTPS
iptables -C INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null || \
    iptables -I INPUT -p tcp --dport 443 -j ACCEPT

# Save rules
if command -v netfilter-persistent &> /dev/null; then
    netfilter-persistent save
else
    apt-get install -y iptables-persistent
    netfilter-persistent save
fi

log_info "Firewall configured (ports 80, 443 open)"

# ============================================================================
# 6. Create Application Directory
# ============================================================================
APP_DIR="/opt/cointracer"
log_info "Creating application directory at ${APP_DIR}..."
mkdir -p "${APP_DIR}"
mkdir -p "${APP_DIR}/logs"

# ============================================================================
# 7. Summary
# ============================================================================
echo ""
echo "============================================"
echo "  Setup Complete!"
echo "============================================"
echo ""
log_info "Next steps:"
echo ""
echo "  1. Clone your repo:"
echo "     cd ${APP_DIR} && git clone <your-repo-url> ."
echo ""
echo "  2. Create .env with your production secrets:"
echo "     nano ${APP_DIR}/.env"
echo ""
echo "     Required variables:"
echo "       DATABASE_URL=postgresql://...@neon.tech/..."
echo "       JWT_SECRET=<generate: openssl rand -hex 32>"
echo "       ENCRYPTION_KEY=<generate: openssl rand -hex 32>"
echo "       API_KEY_HASH_SECRET=<generate: openssl rand -hex 32>"
echo "       CMC_API_KEY=<your coinmarketcap api key>"
echo "       CMC_BASE_URL=https://pro-api.coinmarketcap.com"
echo "       FRONTEND_URL=https://your-app.vercel.app"
echo ""
echo "  3. Start all microservices:"
echo "     docker compose up -d"
echo ""
echo "  4. Verify services are running:"
echo "     docker compose ps"
echo "     curl http://localhost:3000/health"
echo ""
echo "  5. Setup Nginx reverse proxy:"
echo "     sudo cp deploy/nginx.conf /etc/nginx/sites-available/cointracer"
echo "     sudo ln -s /etc/nginx/sites-available/cointracer /etc/nginx/sites-enabled/"
echo "     sudo nginx -t && sudo systemctl reload nginx"
echo ""
echo "  6. Setup SSL:"
echo "     sudo certbot --nginx -d your-domain.com"
echo ""
log_warn "Remember to replace 'your-domain.com' in deploy/nginx.conf with your actual domain!"
echo ""
