FROM node:20-alpine
WORKDIR /app

# Copy shared module
COPY shared/package.json ./shared/
COPY shared/ ./shared/

# Copy service files
COPY alerts-service/package.json ./alerts-service/
COPY alerts-service/ ./alerts-service/

# Copy root package files and install deps
COPY package*.json ./
RUN npm ci --omit=dev --ignore-scripts

# Set schema for database isolation
ENV DB_SCHEMA=alerts_svc
ENV PORT=5002

EXPOSE 5002

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD wget --no-verbose --tries=1 --spider http://localhost:5002/health || exit 1

CMD ["node", "alerts-service/index.js"]
