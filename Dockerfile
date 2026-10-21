FROM node:24-alpine AS deps
WORKDIR /app
RUN corepack enable && corepack prepare pnpm@11.9.0 --activate
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml .npmrc ./
RUN pnpm install --frozen-lockfile
COPY apps/cloud-api apps/cloud-api
COPY packages packages
COPY database database
COPY scripts/migrate.ts scripts/migrate.ts
ENV NODE_ENV=production NEURA_CLOUD_HOST=0.0.0.0 NEURA_CLOUD_PORT=4318
USER node
EXPOSE 4318
CMD ["node","--import","tsx","apps/cloud-api/src/main.ts"]
