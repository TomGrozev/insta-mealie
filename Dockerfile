# syntax=docker/dockerfile:1
# InstaMealie — production image (wayfinder ticket #15)
#
# Decisions locked inline (see issue #15):
#  - Runtime base: cgr.dev/chainguard/wolfi-base (glibc). yt-dlp's --impersonate
#    depends on curl_cffi, which only ships manylinux/glibc prebuilt wheels;
#    Alpine/musl has no prebuilt wheel and building is fragile, so glibc is
#    mandatory here. Wolfi preserves that constraint (it is glibc-based, like
#    the original debian:bookworm-slim choice) while delivering a much smaller,
#    actively-CVE-patched base than Debian slim.
#  - ffmpeg: distro apk package — simplest, meets yt-dlp's merge requirement.
#  - Runtime: Elixir release via `mix release` (not `mix phx.server`) — production grade,
#    bundles ERTS, smaller attack surface, proper config/runtime.exs evaluation.
#  - Layer order: deps cached before source copy; yt-dlp verified at build time so a
#    degraded install fails the build loudly (satisfies #10's `ready` tier contract).
#  - Hardening (ADR 0007): rootless USER 65532:65532, tini as PID 1, no Linux
#    capabilities, unprivileged port 4000, all ephemeral writes consolidated under
#    /tmp so the image runs under Kubernetes `restricted` PSS with
#    `readOnlyRootFilesystem: true` and a single emptyDir on /tmp.

# ---------- Build stage ----------
FROM elixir:1.17 AS build

ENV MIX_ENV=prod \
    PHX_HOST=example.com

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        git \
        curl \
        ca-certificates \
        libssl-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

# Cache dependencies: only mix.exs/mix.lock change rarely
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod
RUN mix deps.compile

# Copy the rest of the source
COPY . .

# Frontend assets are built by hex packages (esbuild + tailwind), no Node.js required
RUN mix assets.setup
RUN mix assets.deploy

# Build the OTP release
RUN mix release

# ---------- Runtime stage ----------
FROM cgr.dev/chainguard/wolfi-base:latest AS runtime

# Runtime env (config/runtime.exs):
#   MIX_ENV/PHX_SERVER/PORT — match the Debian-stage defaults
#   SECRET_KEY_BASE         — REQUIRED at runtime; release will not boot without it
#   PHX_HOST                — optional, defaults to example.com
#   RELEASE_TMP             — Elixir release scratch dir; routed into /tmp so the
#                              image remains writable-free at the root fs level
#   HOME                    — routed into /tmp for the BEAM VM's ~/.erlang.cookie;
#                              ephemeral across restarts, which is fine for a
#                              single-user app with no clustering (ADR 0004)
ENV MIX_ENV=prod \
    PHX_SERVER=true \
    PORT=4000 \
    RELEASE_TMP=/tmp/insta_mealie/release_tmp \
    HOME=/tmp/bedrock/home

LABEL org.opencontainers.image.source="https://github.com/TomGrozev/insta-mealie"

# Shared libs for the bundled ERTS + TLS + yt-dlp / ffmpeg / pip stack.
#   openssl        — pulls libssl3 + libcrypto3 (TLS for the BEAM crypto NIF + Python)
#   ncurses        — Erlang runtime (needed for any code path that touches a TTY)
#   libsctp        — Erlang SCTP transport (optional but cheap; mirrors the
#                    original libsctp1 install)
#   libstdc++      — Erlang VM and any C++ extensions
#   ca-certificates— TLS trust store for both BEAM and yt-dlp / curl_cffi
#   python-3.12    — runtime for yt-dlp (Wolfi pins the major version)
#   py3-pip        — pip module installed alongside python-3.12 (needed for the venv)
#   ffmpeg         — yt-dlp's audio/video merge dependency
#   tini           — PID 1 init / signal forwarding / zombie reaping
RUN apk add --no-cache \
        openssl \
        ncurses \
        libsctp \
        libstdc++ \
        ca-certificates \
        python-3.12 \
        py3-pip \
        ffmpeg \
        tini

# Install yt-dlp exactly per #10's canonical command. The [default,curl-cffi]
# extra is non-optional — a bare `pip install yt-dlp` yields a degraded install.
# pipx is NOT used here because Wolfi's Python is externally-managed (PEP 668)
# and pipx is not guaranteed to be a clean apk package; a venv is the cleanest
# alternative that keeps the install isolated and bypasses PEP 668.
RUN python3 -m venv /opt/yt-dlp-venv \
 && /opt/yt-dlp-venv/bin/pip install --no-cache-dir "yt-dlp[default,curl-cffi]" \
 && ln -sf /opt/yt-dlp-venv/bin/yt-dlp /usr/local/bin/yt-dlp

# Build-time gate: fail loudly if yt-dlp cannot impersonate. This mirrors the
# boot preflight in lib/insta_mealie/ytdlp_real.ex (T3 / #22): impersonation is
# treated as unavailable when `--list-impersonate-targets` prints "(unavailable)"
# OR returns no targets at all (e.g. curl-cffi not importable). A degraded install
# must never ship, so the build fails here rather than degrading at runtime.
RUN yt-dlp --version && \
    targets=$(yt-dlp --list-impersonate-targets 2>/dev/null) && \
    if [ -z "$targets" ] || echo "$targets" | grep -q "(unavailable)"; then \
        echo "FAIL: yt-dlp impersonation unavailable (curl-cffi missing or no targets); cannot build." >&2; \
        echo "Fix with: pip install \"yt-dlp[default,curl-cffi]\"" >&2; \
        exit 1; \
    fi

WORKDIR /app

# Bring over the compiled release from the build stage, owned by the runtime
# user so nothing requires root to read at runtime.
COPY --chown=65532:65532 --from=build /app/_build/prod/rel/insta_mealie ./

# entrypoint.sh materializes the writable dirs (yt-dlp fetch base + RELEASE_TMP
# + Erlang cookie home) at startup, all under /tmp so a single emptyDir on /tmp
# covers every runtime write path. .erlang.cookie contents are ephemeral across
# restarts, which is acceptable for a single-node, non-clustered release.
COPY --chown=65532:65532 entrypoint.sh /app/entrypoint.sh
RUN chmod 0755 /app/entrypoint.sh

# Listen on an unprivileged port (>1024) so CAP_NET_BIND_SERVICE is never
# required. With USER 65532:65532 the process has no capabilities either way.
EXPOSE 4000

USER 65532:65532
ENTRYPOINT ["/usr/bin/tini", "--", "/app/entrypoint.sh"]
CMD ["/app/bin/insta_mealie", "start"]