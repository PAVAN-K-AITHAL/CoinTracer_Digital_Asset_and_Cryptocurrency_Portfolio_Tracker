FROM node:20-alpine
WORKDIR /app

# Copy shared module
COPY shared/package.json ./shared/
COPY shared/ ./shared/

# Copy service files
COPY personalization-service/package.json ./personalization-service/
COPY personalization-service/ ./personalization-service/

# Copy root package files and install deps
COPY package*.json ./
RUN npm ci --omit=dev --ignore-scripts

# Set schema for database isolation
ENV DB_SCHEMA=personalization_svc
ENV PORT=3004

EXPOSE 3004

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD wget --no-verbose --tries=1 --spider http://localhost:3004/health || exit 1

CMD ["node", "personalization-service/index.js"]
