# syntax=docker/dockerfile:1
# InstaMealie — production image (wayfinder ticket #15)
#
# Decisions locked inline (see issue #15):
#  - Build stage: cgr.dev/chainguard/wolfi-base (free; the same base the runtime
#    uses), with Elixir 1.20.3 installed from the official Elixir precompiled
#    `elixir-otp-28.zip` on Wolfi's `erlang-28` (OTP 28) apk. The cgr.dev/chainguard/elixir
#    image is PREMIUM (paid) and Wolfi's own `elixir` apk is only 1.19 (too old for
#    mix.exs ~> 1.20), hence the zip install. Building OTP on Wolfi compiles the crypto
#    NIF against the same no-sm4 libcrypto the runtime ships, fixing the EVP_sm4_cbc
#    load failure that a Debian build caused (see ADR 0007).
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
FROM cgr.dev/chainguard/wolfi-base:latest AS build

# wolfi-base defaults to a non-root user; apk requires root to install the Erlang
# toolchain. The build stage is ephemeral - only the compiled release
# (COPY --chown=65532:65532 below) reaches the runtime, so running the build as
# root does not ship root.
USER root

ENV MIX_ENV=prod \
    PHX_HOST=example.com

# Wolfi's free apk provides OTP 28 (erlang-28) but no Elixir >= 1.20 (only 1.19).
# So: install the OTP toolchain via apk, then Elixir 1.20.3 from the official
# precompiled release zip. openssl is required because erlang-28 links against
# libcrypto3/libssl3 at runtime but does not declare them as apk deps. No C
# toolchain or openssl-dev is needed: the crypto NIF ships prebuilt in the
# erlang-28 apk (compiled against Wolfi's no-sm4 libcrypto), and this app's hex
# deps are pure-Elixir or prebuilt binaries (esbuild/tailwind download platform
# binaries).
RUN apk add --no-cache erlang-28 git curl ca-certificates openssl

# Install Elixir 1.20.3 (official precompiled build paired with OTP 28). Wolfi's
# prebuilt `elixir` apk is only 1.19.5, which does not satisfy mix.exs `~> 1.20`.
ARG ELIXIR_VERSION=1.20.3
RUN curl -fSL -o /tmp/elixir.zip https://github.com/elixir-lang/elixir/releases/download/v${ELIXIR_VERSION}/elixir-otp-28.zip \
 && mkdir -p /opt/elixir \
 && unzip -q /tmp/elixir.zip -d /opt/elixir \
 && ln -sf /opt/elixir/bin/elixir /usr/local/bin/elixir \
 && ln -sf /opt/elixir/bin/elixirc /usr/local/bin/elixirc \
 && ln -sf /opt/elixir/bin/mix /usr/local/bin/mix \
 && ln -sf /opt/elixir/bin/iex /usr/local/bin/iex \
 && chmod +x /opt/elixir/bin/* \
 && rm -f /tmp/elixir.zip

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
 && mkdir -p /usr/local/bin \
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