FROM node:20-alpine
WORKDIR /app

# Copy shared module
COPY shared/package.json ./shared/
COPY shared/ ./shared/

# Copy service files
COPY market-data-service/package.json ./market-data-service/
COPY market-data-service/ ./market-data-service/

# Copy root package files and install deps
COPY package*.json ./
RUN npm ci --omit=dev --ignore-scripts

# Market data service is stateless — no DB_SCHEMA needed
ENV PORT=5001

EXPOSE 5001

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD wget --no-verbose --tries=1 --spider http://localhost:5001/health || exit 1

CMD ["node", "market-data-service/index.js"]
