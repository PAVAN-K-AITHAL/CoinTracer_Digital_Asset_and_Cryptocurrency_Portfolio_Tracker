FROM node:20-alpine

ENV NODE_ENV=production
WORKDIR /app

# Copy only what the gateway needs
COPY package*.json ./
COPY shared/package.json ./shared/
RUN npm ci --omit=dev --ignore-scripts

# Copy gateway and shared module
COPY server.js ./
COPY shared/ ./shared/

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD wget --no-verbose --tries=1 --spider http://localhost:3000/health || exit 1

CMD ["node", "server.js"]
