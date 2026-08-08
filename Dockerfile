# syntax=docker/dockerfile:1
# InstaMealie — production image (wayfinder ticket #15)
#
# Decisions locked inline (see issue #15):
#  - Base image: debian:bookworm-slim (glibc). curl_cffi — required by yt-dlp's
#    --impersonate — ships only manylinux/glibc prebuilt wheels; Alpine/musl has
#    no prebuilt wheel and building is fragile. So glibc is mandatory here.
#  - ffmpeg: distro package (apt) — simplest, meets yt-dlp's merge requirement.
#  - Runtime: Elixir release via `mix release` (not `mix phx.server`) — production grade,
#    bundles ERTS, smaller attack surface, proper config/runtime.exs evaluation.
#  - Layer order: deps cached before source copy; yt-dlp verified at build time so a
#    degraded install fails the build loudly (satisfies #10's `ready` tier contract).

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
FROM debian:bookworm-slim AS runtime

ENV MIX_ENV=prod \
    PHX_SERVER=true \
    PORT=4000 \
    HOME=/root \
    PATH="/root/.local/bin:${PATH}"

# Shared libs for the bundled ERTS + TLS, plus the yt-dlp / ffmpeg stack.
RUN apt-get update && apt-get install -y --no-install-recommends \
        libssl3 \
        libncurses6 \
        libsctp1 \
        libstdc++6 \
        ca-certificates \
        python3 \
        python3-pip \
        python3-venv \
        pipx \
        ffmpeg \
    && rm -rf /var/lib/apt/lists/*

# Install yt-dlp exactly per #10's canonical command. The [default,curl-cffi]
# extra is non-optional — a bare `pipx install yt-dlp` yields a degraded install.
RUN pipx install "yt-dlp[default,curl-cffi]" \
    && ln -sf /root/.local/bin/yt-dlp /usr/local/bin/yt-dlp

# Build-time gate: fail loudly if yt-dlp cannot impersonate. This mirrors the
# boot preflight in lib/insta_mealie/ytdlp_real.ex (T3 / #22): impersonation is
# treated as unavailable when `--list-impersonate-targets` prints "(unavailable)"
# OR returns no targets at all (e.g. curl-cffi not importable). A degraded install
# must never ship, so the build fails here rather than degrading at runtime.
RUN yt-dlp --version && \
    targets=$(yt-dlp --list-impersonate-targets 2>/dev/null) && \
    if [ -z "$targets" ] || echo "$targets" | grep -q "(unavailable)"; then \
        echo "FAIL: yt-dlp impersonation unavailable (curl-cffi missing or no targets); cannot build." >&2; \
        echo "Fix with: pipx install \"yt-dlp[default,curl-cffi]\"" >&2; \
        exit 1; \
    fi

WORKDIR /app

# Bring over the compiled release from the build stage
COPY --from=build /app/_build/prod/rel/insta_mealie ./

EXPOSE 4000

# Runtime env contract (config/runtime.exs):
#   SECRET_KEY_BASE - REQUIRED (release will not boot without it; generate with `mix phx.gen.secret`)
#   PHX_HOST        - optional, defaults to example.com (endpoint URL / cookie domain)
#   PHX_SERVER/PORT - defaulted above; override as needed
# Optional client activation (auto-detected when present):
#   MEALIE_API_TOKEN            -> activates the real Mealie client
#   OPENAI_API_KEY              -> activates the real LLM client (routing/format/merge)
#   yt-dlp is baked in via pipx (above); the real YtDlp client auto-activates and runs the boot preflight.
# No database is required (jobs live in ETS per ADR 0001), so DATABASE_URL is NOT used.
CMD ["/app/bin/insta_mealie", "start"]
