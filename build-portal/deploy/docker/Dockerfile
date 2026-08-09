# syntax=docker/dockerfile:1.7
FROM node:22.22.0-bookworm-slim AS build
WORKDIR /src
RUN corepack enable && corepack prepare pnpm@10.17.1 --activate
COPY package.json pnpm-lock.yaml .npmrc tsconfig.json tsconfig.base.json ./
RUN pnpm install --frozen-lockfile
COPY apps apps
COPY packages packages
RUN pnpm build

FROM node:22.22.0-bookworm-slim AS runtime
ARG GH_VERSION=2.97.0
ARG GLAB_VERSION=1.101.0
RUN apt-get update && apt-get install -y --no-install-recommends bash ca-certificates curl git jq openssh-client python3 tar tini \
 && curl -fsSL "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_amd64.tar.gz" | tar -xz \
 && mv "gh_${GH_VERSION}_linux_amd64/bin/gh" /usr/local/bin/gh \
 && curl -fsSL "https://gitlab.com/gitlab-org/cli/-/releases/v${GLAB_VERSION}/downloads/glab_${GLAB_VERSION}_linux_amd64.tar.gz" | tar -xz -C /usr/local/bin bin/glab --strip-components=1 \
 && groupadd --gid 10001 zhanlu && useradd --uid 10001 --gid 10001 --create-home zhanlu \
 && mkdir -p /app /var/lib/zhanlu-build/state /var/lib/zhanlu-build/git-cache /var/lib/zhanlu-build/backups /var/lib/zhanlu-build/work /run/zhanlu-credentials \
 && chown -R 10001:10001 /app /var/lib/zhanlu-build /run/zhanlu-credentials \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /app
ENV NODE_ENV=production NEXT_TELEMETRY_DISABLED=1
COPY --from=build --chown=10001:10001 /src/apps/web/.next/standalone ./
COPY --from=build --chown=10001:10001 /src/apps/web/.next/static ./apps/web/.next/static
COPY --from=build --chown=10001:10001 /src/dist ./dist
COPY --chown=10001:10001 deploy/scripts/gitlab-credential-helper.sh /usr/local/bin/zhanlu-gitlab-credential
RUN chmod 0755 /usr/local/bin/zhanlu-gitlab-credential
USER 10001:10001
ENTRYPOINT ["/usr/bin/tini","--"]
CMD ["node","apps/web/server.js"]
