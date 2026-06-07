# ── Common base with runtime deps ──────────────────────────────────────────
FROM node:24-trixie-slim AS base
WORKDIR /app

RUN apt-get update \
    && apt-get install -y --no-install-recommends libsecret-1-0 ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# ── Builder ────────────────────────────────────────────────────────────────
FROM base AS builder

RUN apt-get update \
    && apt-get install -y --no-install-recommends python3 make g++ \
    && rm -rf /var/lib/apt/lists/*

COPY package*.json ./
COPY scripts/build/postinstall.mjs ./scripts/build/postinstall.mjs
COPY scripts/build/postinstallSupport.mjs ./scripts/build/postinstallSupport.mjs
COPY scripts/build/native-binary-compat.mjs ./scripts/build/native-binary-compat.mjs

ENV NPM_CONFIG_LEGACY_PEER_DEPS=true

RUN test -f package-lock.json \
  || (echo "package-lock.json is required for reproducible Docker builds" >&2 && exit 1)

RUN npm ci --no-audit --no-fund --legacy-peer-deps --ignore-scripts \
    && npm rebuild better-sqlite3 \
    && node -e "require('better-sqlite3')(':memory:').close()"

ENV OMNIROUTE_USE_TURBOPACK=1

COPY . ./
RUN mkdir -p /app/data && npm run build

# ── Runner base ────────────────────────────────────────────────────────────
FROM base AS runner-base

LABEL org.opencontainers.image.title="omniroute" \
      org.opencontainers.image.description="Unified AI proxy — route any LLM through one endpoint" \
      org.opencontainers.image.url="https://omniroute.online" \
      org.opencontainers.image.source="https://github.com/diegosouzapw/OmniRoute" \
      org.opencontainers.image.licenses="MIT"

ENV NODE_ENV=production
ENV PORT=20128
ENV HOSTNAME=0.0.0.0
ENV OMNIROUTE_MEMORY_MB=1024
ENV NODE_OPTIONS="--max-old-space-size=${OMNIROUTE_MEMORY_MB}"

# ── Production dependencies ────────────────────────────────────────────────
FROM runner-base AS production-deps

COPY package*.json ./

RUN apt-get update \
    && apt-get install -y --no-install-recommends python3 make g++ \
    && rm -rf /var/lib/apt/lists/*

RUN npm ci --omit=dev --no-audit --no-fund --legacy-peer-deps --ignore-scripts \
    && npm rebuild better-sqlite3 \
    && node -e "require('better-sqlite3')(':memory:').close()"

# ── Runner ─────────────────────────────────────────────────────────────────
FROM runner-base AS runner

COPY --from=production-deps /app/node_modules ./node_modules
COPY --from=builder /app/.next/standalone ./
COPY --from=builder /app/.next/static ./.next/static
COPY --from=builder /app/public ./public

EXPOSE ${PORT}

CMD ["node", "server.js"]
