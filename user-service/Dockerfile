FROM node:20-alpine
WORKDIR /app

# Copy shared module
COPY shared/package.json ./shared/
COPY shared/ ./shared/

# Copy service files
COPY user-service/package.json ./user-service/
COPY user-service/ ./user-service/

# Copy root package files and install deps
COPY package*.json ./
RUN npm ci --omit=dev --ignore-scripts

# Set schema for database isolation
ENV DB_SCHEMA=users_svc
ENV PORT=3001

EXPOSE 3001

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD wget --no-verbose --tries=1 --spider http://localhost:3001/health || exit 1

CMD ["node", "user-service/index.js"]
