# ── Common base with runtime deps ──────────────────────────────────────────
FROM node:24-trixie-slim AS base
WORKDIR /app

# `apt-get upgrade` pulls the security-patched versions of the Debian (trixie)
# base-image packages at build time — clears the subset of container-scan CVEs
# (perl / util-linux / systemd / ncurses / zlib / tar / sqlite / shadow / pam …)
# that already have a fix published in trixie. CVEs without an upstream fix yet
# (local-only TOCTOU, etc.) remain until the distro patches them and the image
# is rebuilt; none are reachable from the proxy's request surface at runtime.
RUN --mount=type=cache,id=cacheKey-omniroute-apt,target=/var/cache/apt,sharing=shared \
  --mount=type=cache,id=cacheKey-omniroute-apt-lists,target=/var/lib/apt/lists,sharing=shared \
  apt-get update \
  && apt-get upgrade -y \
  && apt-get install -y --no-install-recommends libsecret-1-0 ca-certificates \
  && rm -rf /var/lib/apt/lists/*

# Refresh the globally-installed npm so its *bundled* node_modules (undici, tar)
# ship the patched versions. These are npm's own internals — not application
# dependencies (our app already resolves undici@8.5.0 / tar@7.5.16, both fixed) —
# but the container scanner flags the stale copies under
# /usr/local/lib/node_modules/npm/node_modules. npm is not invoked at runtime in
# the runner stages, so this is hygiene, not an exploitable runtime path.
RUN npm install -g npm@latest \
  && npm cache clean --force

# ── Builder ────────────────────────────────────────────────────────────────
FROM base AS builder

# Build tools for native module compilation
# apt-get update needed here because base's rm -rf clears the shared cache
RUN --mount=type=cache,id=cacheKey-omniroute-builder-apt,target=/var/cache/apt,sharing=shared \
  --mount=type=cache,id=cacheKey-omniroute-builder-apt-lists,target=/var/lib/apt/lists,sharing=shared \
  apt-get update \
  && apt-get install -y --no-install-recommends python3 make g++ \
  && rm -rf /var/lib/apt/lists/*

COPY package*.json ./
# Workspace package manifests MUST be present before `npm ci` so npm materializes
# the workspace and installs its *workspace-only* deps (e.g. safe-regex,
# @toon-format/toon — declared in open-sse/package.json, not hoisted to root).
# Without this, `npm ci` skips them and `npm run build` fails with "Module not
# found" (root cause of the v3.8.39 Docker build break). workspaces = ["open-sse"].
COPY open-sse/package.json ./open-sse/package.json
COPY scripts/build/postinstall.mjs ./scripts/build/postinstall.mjs
COPY scripts/build/postinstallSupport.mjs ./scripts/build/postinstallSupport.mjs
COPY scripts/build/native-binary-compat.mjs ./scripts/build/native-binary-compat.mjs
ENV NPM_CONFIG_LEGACY_PEER_DEPS=true
# --ignore-scripts blocks broad dependency install/postinstall hooks, closing
# the supply-chain attack surface where a transitive dep can run arbitrary code
# at install time. better-sqlite3 still needs a native binding for the target
# platform, so rebuild and smoke-test only that known runtime dependency below.
#
# We REQUIRE a committed package-lock.json so resolved dependency versions
# are reproducible.
RUN test -f package-lock.json \
  || (echo "package-lock.json is required for reproducible Docker builds" >&2 && exit 1)
RUN --mount=type=cache,id=cacheKey-omniroute-npm,target=/root/.npm \
  npm ci --no-audit --no-fund --legacy-peer-deps --ignore-scripts \
  && npm rebuild better-sqlite3 \
  && node -e "require('better-sqlite3')(':memory:').close()"

# Build with webpack (stable). Turbopack hit a non-recoverable internal panic on this
# Next.js version during the v3.8.27 release build — TurbopackInternalError "entered
# unreachable code: there must be a path to a root" in ImportTracer::get_traces, on both
# linux/amd64 and linux/arm64. Webpack is the proven engine (build:release / VPS / CI Build
# all green). Re-enable Turbopack (=1) once the upstream tracer bug is fixed.
# See docs/ops/QUALITY_GATE_PLAYBOOK.md Parte 6.
ENV OMNIROUTE_USE_TURBOPACK=0

# Raise the V8 heap ceiling for the build. The webpack production optimization
# pass (forced above since Turbopack panics) needs more than V8's default ceiling
# (~2 GB) for a codebase this size; a memory-constrained Docker build otherwise
# dies with "FATAL ERROR: ... JavaScript heap out of memory" during the builder
# stage (#4076). NODE_OPTIONS propagates to the spawned `next build` child
# (build-next-isolated.mjs → resolveNextBuildEnv spreads process.env). Build-only;
# the runtime heap is set separately on the runner stage (OMNIROUTE_MEMORY_MB).
# Override for hosts with more/less RAM: `--build-arg OMNIROUTE_BUILD_MEMORY_MB=6144`.
ARG OMNIROUTE_BUILD_MEMORY_MB=4096
ENV NODE_OPTIONS="--max-old-space-size=${OMNIROUTE_BUILD_MEMORY_MB}"

COPY . ./
RUN --mount=type=cache,id=cacheKey-omniroute-next,target=/app/.build/next/cache \
  mkdir -p /app/data && npm run build

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

# Data directory inside Docker — must match the volume mount in docker-compose.yml
ENV DATA_DIR=/app/data
RUN mkdir -p /app/data

# `npm run build` (build-next-isolated → assembleStandalone) bundles ALL runtime
# files into .build/next/standalone/ — .next, node_modules, migrations, scripts,
# docs, and the previously hand-COPY'd modules below (@swc/helpers, pino-*, split2,
# migrations). assembleStandalone copies them straight from the builder's
# node_modules, so they are present regardless of NFT/Turbopack trace behaviour.
# The old per-module overrides were therefore pure duplication and were removed
# (build-output-isolation cleanup). See scripts/build/assembleStandalone.mjs
# (EXTRA_MODULE_ENTRIES) for the single source of truth.
COPY --from=builder /app/.build/next/standalone ./
# better-sqlite3 is the one exception still copied explicitly: assembleStandalone
# only syncs its native build/ dir; the JS wrapper (lib/, package.json) is left to
# Next.js tracing. bootstrap-env requires SQLite BEFORE the standalone server
# starts, so guarantee the complete package independent of trace behaviour.
COPY --from=builder /app/node_modules/better-sqlite3 ./node_modules/better-sqlite3
# migrations land at <standalone>/migrations via assembleStandalone; point the runtime at them.
ENV OMNIROUTE_MIGRATIONS_DIR=/app/migrations

# Docker healthcheck script — not traced by Next.js standalone output, so copy
# it explicitly. The HEALTHCHECK CMD references it as `node healthcheck.mjs`.
COPY --from=builder /app/scripts/dev/healthcheck.mjs ./healthcheck.mjs

# Hand /app over to the baked-in `node` non-root user (UID/GID 1000) so the
# runtime process never holds root privileges. The chown happens after all
# COPYs so it covers files originally owned by root in the builder stage.
RUN chown -R node:node /app

EXPOSE 20128

# Drop to non-root before ENTRYPOINT/CMD so every derived stage (runner-cli,
# runner-web) also runs as a non-root user unless they explicitly switch back.
USER node

# Warns if the mounted data volume has wrong ownership
COPY --chmod=755 scripts/check-permissions.sh /tmp/check-permissions.sh
ENTRYPOINT ["/tmp/check-permissions.sh"]

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD ["node", "healthcheck.mjs"]

CMD ["node", "dev/run-standalone.mjs"]
