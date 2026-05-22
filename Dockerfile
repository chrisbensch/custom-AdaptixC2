# syntax=docker/dockerfile:1.7
#
# Unified AdaptixC2 build: server + default extenders + Kharon (agent + HTTP listener)
# + Extension-Kit BOFs + PostEx-Arsenal BOFs, all wired through profile.kharon.yaml.
#
# Build context: workspace root containing AdaptixC2/, Extension-Kit/, Kharon/, PostEx-Arsenal/.
# Builds for the host architecture. Windows artifacts (beacon agent, Kharon beacon,
# Gopher agent) are still cross-compiled to x86/x64 PE via mingw-w64 / clang regardless
# of host arch. To force a specific arch, pass --platform=linux/amd64 to docker build,
# or set DOCKER_DEFAULT_PLATFORM in the environment.

# ============================================
# Stage: base — toolchains for every component
# ============================================
# Pinned by digest, not just tag. Tags are mutable; digests aren't. Bump alongside
# the version when refreshing — see BLUEPRINT.md §3 for the lookup procedure.
FROM golang:1.25.10-bookworm@sha256:154bd7001b6eb339e88c964442c0ad6ed5e53f09844cc818a41ce4ecb3ce3b43 AS base

ENV DEBIAN_FRONTEND=noninteractive
ENV GOEXPERIMENT=jsonv2,greenteagc

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        git \
        wget \
        make \
        build-essential \
        gcc \
        g++ \
        mingw-w64 \
        g++-mingw-w64 \
        libssl-dev \
        zlib1g-dev \
        nasm \
        clang \
        llvm \
        python3 \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# go-win7: Windows 7 / Server 2008 R2 compatible Go runtime, required by Gopher Agent
# and consumed by Kharon's beacon build chain.
# Pinned to a specific commit so the build is reproducible. Bump the SHA when
# refreshing — see BLUEPRINT.md upgrade flow.
ARG GO_WIN7_SHA=15ad42baf018e90cd5a56a4d5886e8cf6a75065e
RUN git clone https://github.com/Adaptix-Framework/go-win7 /usr/lib/go-win7 && \
    git -C /usr/lib/go-win7 checkout "$GO_WIN7_SHA" && \
    mkdir -p /usr/lib/go-win7/pkg/include && \
    cd /usr/lib/go-win7/src/runtime && \
    for f in *.h; do ln -sf /usr/lib/go-win7/src/runtime/$f /usr/lib/go-win7/pkg/include/$f; done

WORKDIR /src

# ============================================
# Stage: build-bofs — Extension-Kit + PostEx-Arsenal BOFs
# ============================================
FROM base AS build-bofs

# Extension-Kit: 10 BOF subdirectories, each emits .x64.o / .x32.o into its _bin/.
# patches/extension-kit-*.patch fixes upstream Makefile bugs that surface on arm64
# hosts (see patches/ for details). Applied via `git apply` (works without .git).
COPY Extension-Kit /src/Extension-Kit
COPY patches /src/patches
RUN cd /src/Extension-Kit && \
    git apply --verbose /src/patches/extension-kit-nanodump-host-strip.patch

# Build the offline-safe BOF subdirs first (strict failure).
# Hard-coded list rather than `make -k` so a real bug in any of these still fails
# the build. If upstream adds a new BOF subdir, add it here (CI catches drift).
RUN set -eux; \
    for d in AD-BOF Creds-BOF Elevation-BOF Execution-BOF Injection-BOF \
             LateralMovement-BOF Postex-BOF Process-BOF SAR-BOF; do \
        make -C /src/Extension-Kit/$d; \
    done

# SAL-BOF fetches a vulnerable-driver list via python3 over the network at build
# time. Offline builds tolerate its failure — every other BOF has already shipped
# above. To force a clean failure when offline-building, drop the `|| echo …`.
RUN make -C /src/Extension-Kit/SAL-BOF || \
    echo "[!] SAL-BOF build failed (likely offline) — continuing"

# PostEx-Arsenal: cross-compiles .cc → bofs/dist/*.x64.o.
# postex_sc/*/bin/*.bin are committed pre-built per plan; carried through unchanged.
COPY PostEx-Arsenal /src/PostEx-Arsenal
RUN make -C /src/PostEx-Arsenal/bofs

# ============================================
# Stage: build-server — AdaptixC2 + Kharon extenders
# ============================================
FROM base AS build-server

COPY AdaptixC2 /src/AdaptixC2

# Inline what Kharon/setup_kharon.sh does (without --ax indirection):
# drop the agent + listener extender directories into AdaptixServer/extenders/,
# register them in go.work, then let AdaptixC2's Makefile auto-discover them.
COPY Kharon/agent_kharon         /src/AdaptixC2/AdaptixServer/extenders/agent_kharon
COPY Kharon/listener_kharon_http /src/AdaptixC2/AdaptixServer/extenders/listener_kharon_http

RUN cd /src/AdaptixC2/AdaptixServer && \
    go work use ./extenders/agent_kharon ./extenders/listener_kharon_http && \
    go work sync

# Build adaptixserver + every extender plugin (default 7 + Kharon 2 = 9).
RUN make -C /src/AdaptixC2 server-ext

# Build the Kharon beacon itself (clang + nasm). Plugin already built via 'make extenders';
# this target compiles the PIC beacon source under src_beacon/ and stages it into the
# extender's dist/ for runtime payload generation.
RUN make -C /src/AdaptixC2/AdaptixServer/extenders/agent_kharon agent

# Two-pass dist reconciliation (intentional — do not collapse without verifying):
#   - `make server-ext` (above) builds the Go plugin and moves the extender's
#     dist into /src/AdaptixC2/dist/extenders/agent_kharon.
#   - `make agent` (above, in the extender source tree) compiles the PIC beacon
#     under src_beacon/ and re-stages it into the *source* dist/ directory.
# We copy the second-pass artifacts back over the first-pass layout so the
# runtime image ships the beacon binaries alongside the plugin .so.
RUN if [ -d /src/AdaptixC2/AdaptixServer/extenders/agent_kharon/dist ]; then \
        cp -r /src/AdaptixC2/AdaptixServer/extenders/agent_kharon/dist/. \
              /src/AdaptixC2/dist/extenders/agent_kharon/; \
    fi

# ============================================
# Stage: runtime — minimal server image
# ============================================
# Pinned by digest. Same rationale as the base stage above; bump on refresh.
FROM debian:bookworm-slim@sha256:0104b334637a5f19aa9c983a91b54c89887c0984081f2068983107a6f6c21eeb AS runtime

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get upgrade -y && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        openssl \
        curl \
        gosu \
        libcap2-bin \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# `apt-get upgrade -y` above pulls Debian security updates into the base
# image's pre-existing packages (e.g. libgnutls30 was at +deb12u6 in the
# pinned base; +deb12u7 fixes a critical CVE). Pairing the digest pin (for
# a reproducible starting point) with an upgrade pass (for security patches
# available on build day) is the Debian convention; Trivy in CI surfaces
# when a new patch is available and not yet picked up.

# Unprivileged runtime account. The entrypoint stays root long enough to chown
# the /app/data bind mount and render the profile, then drops to `adaptix` via
# `gosu` before exec'ing the server. /app itself is left root-owned + world-
# readable so even a write-capable container can't modify the server binary.
RUN groupadd --system --gid 10001 adaptix && \
    useradd  --system --uid 10001 --gid adaptix \
             --no-create-home --shell /usr/sbin/nologin adaptix

WORKDIR /app

# Server binary + default extenders + Kharon extenders + ssl_gen.sh + 404page.html.
COPY --from=build-server /src/AdaptixC2/dist/ /app/

# Built BOFs and AxScript bundles. Paths mirror the layout the .axs files expect:
# kh_modules.axs uses ax.script_dir() + "bofs/dist/<name>.<arch>.o"
# extension-kit.axs uses ax.script_dir() + "<Subdir>/<name>.axs"
COPY --from=build-bofs /src/Extension-Kit  /app/Extension-Kit
COPY --from=build-bofs /src/PostEx-Arsenal /app/PostEx-Arsenal

# Profile template + Kharon listener template. The runtime profile is rendered
# from profile.yaml.tmpl into /app/data/profile.yaml on first start, with
# credentials taken from env (ADAPTIX_TEAMSERVER_PASSWORD, ADAPTIX_OPERATORS)
# or randomly generated. See docker/entrypoint.sh.
COPY profile.kharon.yaml                              /app/profile.yaml.tmpl
COPY Kharon/listener_kharon_http/profiles/template.json /app/kharon-template.json

# First-start bootstrap: TLS cert generation + profile rendering.
COPY docker/entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

# File capability on the server binary so beacon listeners can bind <1024
# (typically :80 / :443 / :53) after gosu drops privileges. setuid(0 → 10001)
# clears the process cap sets, but execve re-derives them from file caps —
# only NET_BIND_SERVICE travels with the binary; everything else stays dropped.
# Requires the container's bounding set to include NET_BIND_SERVICE
# (see docker-compose.yml `cap_add`).
RUN setcap cap_net_bind_service=+ep /app/adaptixserver

# EXPOSE is a no-op under network_mode: host (the compose runtime default).
# Kept for `docker run -P` users: 4321 is the teamserver. Beacon listener ports
# are operator-defined at runtime and not knowable at image-build time.
EXPOSE 4321

# Confirms TLS handshake + HTTP layer up; curl exits non-zero on connect/TLS/timeout
# failure. `/endpoint` is a WebSocket upgrade and won't 2xx on a plain GET — we
# only care that the server *responded*, so no `-f`.
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD curl -sk --max-time 5 -o /dev/null https://127.0.0.1:4321/endpoint || exit 1

ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["/app/adaptixserver", "-profile", "/app/data/profile.yaml"]
