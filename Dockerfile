# syntax = docker/dockerfile:1.27

ARG NODE_VERSION=26.10.0-trixie

# build assets & compile TypeScript

FROM --platform=$BUILDPLATFORM node:${NODE_VERSION} AS native-builder

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
	--mount=type=cache,target=/var/lib/apt,sharing=locked \
	rm -f /etc/apt/apt.conf.d/docker-clean \
	; echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' > /etc/apt/apt.conf.d/keep-cache \
	&& apt-get update \
	&& apt-get install -yqq --no-install-recommends \
	build-essential

WORKDIR /misskey

COPY --link ["pnpm-lock.yaml", "pnpm-workspace.yaml", "package.json", "./"]
COPY --link ["scripts", "./scripts"]
COPY --link ["patches", "./patches"]
COPY --link ["packages/backend/package.json", "./packages/backend/"]
COPY --link ["packages/frontend-shared/package.json", "./packages/frontend-shared/"]
COPY --link ["packages/frontend/package.json", "./packages/frontend/"]
COPY --link ["packages/frontend-embed/package.json", "./packages/frontend-embed/"]
COPY --link ["packages/frontend-builder/package.json", "./packages/frontend-builder/"]
COPY --link ["packages/i18n/package.json", "./packages/i18n/"]
COPY --link ["packages/icons-subsetter/package.json", "./packages/icons-subsetter/"]
COPY --link ["packages/sw/package.json", "./packages/sw/"]
COPY --link ["packages/misskey-js/package.json", "./packages/misskey-js/"]
COPY --link ["packages/misskey-reversi/package.json", "./packages/misskey-reversi/"]
COPY --link ["packages/misskey-bubble-game/package.json", "./packages/misskey-bubble-game/"]

ARG NODE_ENV=production

RUN node -e "console.log(JSON.parse(require('node:fs').readFileSync('./package.json')).packageManager)" | xargs npm install -g

RUN --mount=type=cache,target=/root/.local/share/pnpm/store,sharing=locked \
	pnpm i --frozen-lockfile --aggregate-output

COPY --link . ./

RUN pnpm build
RUN rm -rf .git/

# build native dependencies for target platform

FROM --platform=$TARGETPLATFORM node:${NODE_VERSION} AS target-builder

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
	--mount=type=cache,target=/var/lib/apt,sharing=locked \
	rm -f /etc/apt/apt.conf.d/docker-clean \
	; echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' > /etc/apt/apt.conf.d/keep-cache \
	&& apt-get update \
	&& apt-get install -yqq --no-install-recommends \
	build-essential

WORKDIR /misskey

COPY --link ["pnpm-lock.yaml", "pnpm-workspace.yaml", "package.json", "./"]
COPY --link ["scripts", "./scripts"]
COPY --link ["patches", "./patches"]
COPY --link ["packages/backend/package.json", "./packages/backend/"]
COPY --link ["packages/misskey-js/package.json", "./packages/misskey-js/"]
COPY --link ["packages/misskey-reversi/package.json", "./packages/misskey-reversi/"]
COPY --link ["packages/misskey-bubble-game/package.json", "./packages/misskey-bubble-game/"]

ARG NODE_ENV=production

RUN node -e "console.log(JSON.parse(require('node:fs').readFileSync('./package.json')).packageManager)" | xargs npm install -g

RUN --mount=type=cache,target=/root/.local/share/pnpm/store,sharing=locked \
	pnpm i --frozen-lockfile --aggregate-output

# static ffmpeg binary (no shared library dependencies needed)
FROM mwader/static-ffmpeg:latest AS ffmpeg

# extract libjemalloc.so.2 to a fixed arch-independent path
# (distroless has no shell so we cannot create symlinks in the runner stage)
FROM --platform=$TARGETPLATFORM node:${NODE_VERSION}-slim AS jemalloc-provider
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
	--mount=type=cache,target=/var/lib/apt,sharing=locked \
	rm -f /etc/apt/apt.conf.d/docker-clean \
	; echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' > /etc/apt/apt.conf.d/keep-cache \
	&& apt-get update \
	&& apt-get install -y --no-install-recommends libjemalloc2 \
	&& cp "$(find /usr/lib -name 'libjemalloc.so.2' | head -1)" /libjemalloc.so.2

# extract tini binary
FROM --platform=$TARGETPLATFORM node:${NODE_VERSION}-slim AS tini-provider
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
	--mount=type=cache,target=/var/lib/apt,sharing=locked \
	rm -f /etc/apt/apt.conf.d/docker-clean \
	; echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' > /etc/apt/apt.conf.d/keep-cache \
	&& apt-get update \
	&& apt-get install -y --no-install-recommends tini

# distroless has no shell/useradd, so we cannot create a "misskey" user in the runner
# stage directly like upstream does. Instead, pre-render /etc/passwd and /etc/group
# here (where a shell is available) with a build-arg-configurable UID/GID, defaulting
# to 991 to match upstream and pre-existing bind-mounted data directories. Naming the
# user "misskey" (same as upstream) lets COPY --chown=misskey:misskey lines merge from
# upstream verbatim, without rewriting the UID/GID on every sync.
FROM --platform=$BUILDPLATFORM node:${NODE_VERSION}-slim AS passwd-provider
ARG UID="991"
ARG GID="991"
RUN printf '%s\n' \
	'root:x:0:0:root:/root:/sbin/nologin' \
	'nobody:x:65534:65534:nobody:/nonexistent:/sbin/nologin' \
	'nonroot:x:65532:65532:nonroot:/home/nonroot:/sbin/nologin' \
	"misskey:x:${UID}:${GID}:misskey:/misskey:/sbin/nologin" \
	> /passwd \
	&& printf '%s\n' \
	'root:x:0:' \
	'nobody:x:65534:' \
	'tty:x:5:' \
	'staff:x:50:' \
	'nonroot:x:65532:' \
	"misskey:x:${GID}:" \
	> /group \
	&& mkdir -p /misskey \
	&& touch /misskey/.keep \
	&& chown -R "${UID}:${GID}" /misskey

# Must match NODE_VERSION in both the Node major (native modules are built against its ABI)
# and the Debian release (tini / jemalloc / native modules are linked against its glibc).
# NODE_VERSION=26.x-trixie -> nodejs26-debian13. Bump this together with NODE_VERSION.
FROM gcr.io/distroless/nodejs26-debian13:nonroot AS runner

COPY --from=passwd-provider /passwd /etc/passwd
COPY --from=passwd-provider /group  /etc/group

USER misskey

COPY --from=tini-provider     /usr/bin/tini     /tini
COPY --from=ffmpeg            /ffmpeg           /usr/local/bin/ffmpeg
COPY --from=ffmpeg            /ffprobe          /usr/local/bin/ffprobe
COPY --from=jemalloc-provider /libjemalloc.so.2 /usr/lib/libjemalloc.so.2

# create the application root before WORKDIR does, so that it is owned by the
# runtime user (distroless has no shell, so it cannot be chowned afterwards)
COPY --chown=misskey:misskey --from=passwd-provider /misskey/ /misskey/

WORKDIR /misskey

COPY --chown=misskey:misskey --from=target-builder /misskey/node_modules                              ./node_modules
COPY --chown=misskey:misskey --from=target-builder /misskey/packages/backend/node_modules             ./packages/backend/node_modules
COPY --chown=misskey:misskey --from=target-builder /misskey/packages/misskey-js/node_modules          ./packages/misskey-js/node_modules
COPY --chown=misskey:misskey --from=target-builder /misskey/packages/misskey-reversi/node_modules     ./packages/misskey-reversi/node_modules
COPY --chown=misskey:misskey --from=target-builder /misskey/packages/misskey-bubble-game/node_modules ./packages/misskey-bubble-game/node_modules
COPY --chown=misskey:misskey --from=native-builder /misskey/built                                     ./built
COPY --chown=misskey:misskey --from=native-builder /misskey/packages/misskey-js/built                 ./packages/misskey-js/built
COPY --chown=misskey:misskey --from=native-builder /misskey/packages/misskey-reversi/built            ./packages/misskey-reversi/built
COPY --chown=misskey:misskey --from=native-builder /misskey/packages/misskey-bubble-game/built        ./packages/misskey-bubble-game/built
COPY --chown=misskey:misskey --from=native-builder /misskey/packages/backend/built                    ./packages/backend/built
COPY --chown=misskey:misskey --from=native-builder /misskey/packages/i18n/built                       ./packages/i18n/built
COPY --chown=misskey:misskey --from=native-builder /misskey/packages/frontend/assets ./packages/frontend/assets
COPY --chown=misskey:misskey ["packages/backend/ormconfig.js",              "./packages/backend/"]
COPY --chown=misskey:misskey ["packages/backend/package.json",             "./packages/backend/"]
COPY --chown=misskey:misskey ["packages/backend/migration",                 "./packages/backend/migration"]
COPY --chown=misskey:misskey ["packages/backend/assets",                    "./packages/backend/assets"]
COPY --chown=misskey:misskey ["packages/backend/src/server/assets",         "./packages/backend/src/server/assets"]
COPY --chown=misskey:misskey ["packages/backend/scripts/compile_config.js", "./packages/backend/scripts/"]
COPY --chown=misskey:misskey ["scripts/docker-start.js",                    "./scripts/"]
COPY --chown=misskey:misskey ["healthcheck.js",                             "./"]

ENV LD_PRELOAD=/usr/lib/libjemalloc.so.2
ENV NODE_ENV=production
HEALTHCHECK --interval=5s --retries=20 CMD ["/nodejs/bin/node", "/misskey/healthcheck.js"]
ENTRYPOINT ["/tini", "--"]
CMD ["/nodejs/bin/node", "/misskey/scripts/docker-start.js"]
