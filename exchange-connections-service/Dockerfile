FROM node:20-alpine
WORKDIR /app

# Copy shared module
COPY shared/package.json ./shared/
COPY shared/ ./shared/

# Copy service files
COPY exchange-connections-service/package.json ./exchange-connections-service/
COPY exchange-connections-service/ ./exchange-connections-service/

# Copy root package files and install deps
COPY package*.json ./
RUN npm ci --omit=dev --ignore-scripts

# Set schema for database isolation
ENV DB_SCHEMA=portfolios_svc
ENV PORT=5000

EXPOSE 5000

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD wget --no-verbose --tries=1 --spider http://localhost:5000/health || exit 1

CMD ["node", "exchange-connections-service/server.js"]
