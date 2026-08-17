# InstaMealie

> An Instagram-reel → Mealie recipe importer.

[![CI](https://github.com/TomGrozev/insta-mealie/actions/workflows/ci.yml/badge.svg)](https://github.com/TomGrozev/insta-mealie/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-Apache_2.0-blue.svg)](LICENSE)

InstaMealie is a personal pipeline that turns Instagram reels into recipes in
your [Mealie](https://mealie.io/) instance. Paste a reel URL (or the caption as
a fallback), and the app extracts the recipe from the caption, comments, or
audio transcription; an LLM formats the result into Mealie's schema; unknown
ingredients get a low-burden human confirmation; and the recipe imports to
Mealie with a deep link out.

It is single-user, has no accounts, and is ephemeral — jobs live in-memory
(ETS, not a database) and are lost on restart. Mealie is the system of record.

## Features

- **Reel → recipe pipeline** — paste an Instagram reel URL; the app fetches the
  reel, extracts the recipe, and imports it to Mealie.
- **Caption and transcription fallback** — uses the reel's caption, then its
  comments, then Whisper transcription of the audio when the text is
  incomplete. A paste-caption fallback covers cases where reel fetching fails.
- **LLM formatting** — an OpenAI-compatible model turns the extracted text
  into Mealie's recipe schema, with a separate merge model used to refine the
  draft against transcription and any linked recipe page.
- **Ingredient review** — ingredients the parser can't confidently classify
  are surfaced in a single pre-import review screen with a candidate picker.
- **Mealie import with deep link** — once confirmed, the recipe is posted to
  Mealie and a deep link (view/edit) into Mealie is returned.
- **Single-user, no accounts, ephemeral** — designed for one person running
  it for themselves. No database, no auth, no multi-tenant concerns.

## Quick Start

**1.** Install dependencies and build assets:

```bash
mix setup
```

**2.** Set the environment variables you need for local development — at
minimum an OpenAI-compatible LLM and a Mealie instance:

```bash
export OPENAI_API_KEY=sk-...
export MEALIE_BASE_URL=http://localhost:9000
export MEALIE_API_TOKEN=...
export MEALIE_GROUP_SLUG=home        # optional, defaults to "home"
```

If you want to use audio transcription as a fallback, also set the Whisper
variables (see [Configuration](#configuration)).

**3.** Start the Phoenix server:

```bash
mix phx.server
```

Now visit [`localhost:4000`](http://localhost:4000) in your browser and paste
an Instagram reel URL to start a job.

To run the test suite:

```bash
mix test
```

## Configuration

All configuration is read from environment variables at runtime (see
`config/runtime.exs`); secrets are never hard-coded.

### LLM (recipe formatting)

| Variable             | Required | Default                     | Purpose                                                                 |
| -------------------- | -------- | --------------------------- | ----------------------------------------------------------------------- |
| `OPENAI_BASE_URL`    | No       | `https://api.openai.com/v1` | OpenAI-compatible base URL used for both formatting and merging.        |
| `OPENAI_API_KEY`     | Yes      | `""`                        | API key for the LLM endpoint.                                           |
| `OPENAI_MODEL`       | No       | `gpt-4o-mini`               | Model used for the initial `llm_format` stage.                          |
| `OPENAI_MERGE_MODEL` | No       | falls back to `OPENAI_MODEL`| Model used for `llm_merge` (refining the draft against transcription). |

### Mealie (recipe import)

| Variable             | Required | Default                  | Purpose                                       |
| -------------------- | -------- | ------------------------ | --------------------------------------------- |
| `MEALIE_BASE_URL`    | Yes      | `http://localhost:9000`  | Base URL of your Mealie instance.             |
| `MEALIE_API_TOKEN`   | Yes      | `""`                     | Long-lived API token from Mealie.             |
| `MEALIE_GROUP_SLUG`  | No       | `home`                   | Mealie group slug recipes are imported into.  |

### Transcription (optional)

| Variable            | Required | Default     | Purpose                                                       |
| ------------------- | -------- | ----------- | ------------------------------------------------------------- |
| `WHISPER_BASE_URL`  | No       | `""`        | OpenAI-compatible Whisper endpoint. Empty disables fallback.  |
| `WHISPER_API_KEY`   | No       | `""`        | API key for the Whisper endpoint.                             |
| `WHISPER_MODEL`     | No       | `whisper-1` | Whisper model name.                                           |

### Instagram access

| Variable          | Required | Default | Purpose                                                                              |
| ----------------- | -------- | ------- | ------------------------------------------------------------------------------------ |
| `IG_COOKIES_PATH` | No       | unset   | Path to a Netscape-format cookies file (containing a `sessionid`) for authenticated fetching. Optional. |

### Recipe output

| Variable          | Required | Default | Purpose                                  |
| ----------------- | -------- | ------- | ---------------------------------------- |
| `OUTPUT_LANGUAGE` | No       | `en`    | Language code used for recipe output.    |

### Phoenix / production

| Variable            | Required     | Default        | Purpose                                                       |
| ------------------- | ------------ | -------------- | ------------------------------------------------------------- |
| `SECRET_KEY_BASE`   | Yes (prod)   | unset          | Used to sign/encrypt cookies. Generate with `mix phx.gen.secret`. |
| `PHX_HOST`          | No (prod)    | `example.com`  | Public host name for generated URLs in production.            |
| `PORT`              | No           | `4000`         | Port the endpoint binds to.                                    |
| `DNS_CLUSTER_QUERY` | No           | unset          | DNS query for clustered node discovery.                        |

## Docker / Production Deployment

A hardened container image is published to
`ghcr.io/tomgrozev/insta-mealie`. It is built from a Wolfi-based hardened
runtime image following the
[`TomGrozev/bedrock-containers`](https://github.com/TomGrozev/bedrock-containers)
hardening standard: runs as the non-root user `65532:65532`, listens on
unprivileged port `4000`, has no Linux capabilities, uses `tini` as PID 1, and
is designed for a read-only root filesystem with a single writable `/tmp`
mount. There is no database — jobs live in ETS only (see
[ADR 0001](docs/adr/0001-in-memory-job-tracking.md)) — so no other persistent
mounts are required.

A minimal `docker run`:

```bash
docker run -p 4000:4000 \
  -e SECRET_KEY_BASE=... \
  -e MEALIE_BASE_URL=... \
  -e MEALIE_API_TOKEN=... \
  -e OPENAI_API_KEY=... \
  ghcr.io/tomgrozev/insta-mealie:latest
```

Pass any of the variables from [Configuration](#configuration) as `-e` flags,
or supply them via your orchestrator's secret mechanism. Generate
`SECRET_KEY_BASE` with `mix phx.gen.secret`.

## Documentation

- [CONTEXT.md](CONTEXT.md) — domain glossary: the canonical names for reels,
  jobs, stages, ingredients, errors, and Instagram-access terms used
  throughout the codebase.
- [docs/adr/](docs/adr/) — architecture decision records. Start with
  [ADR 0001 — In-memory ETS job tracking](docs/adr/0001-in-memory-job-tracking.md)
  and [ADR 0004 — Single-user, ephemeral](docs/adr/0004-single-user-ephemeral.md)
  for the core design constraints.
- [CHANGELOG.md](CHANGELOG.md) — release notes.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines on contributing to
InstaMealie.

## License

See [LICENSE](LICENSE) for details. InstaMealie is released under the
[Apache License 2.0](https://www.apache.org/licenses/LICENSE-2.0).
