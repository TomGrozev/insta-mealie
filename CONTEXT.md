# InstaMealie

An Instagram-reel → Mealie recipe pipeline. Paste a reel URL (or the caption as fallback); the app extracts the recipe from the caption/comments or from audio transcription, an LLM formats it into Mealie's schema, unknown ingredients get low-burden human confirmation, and the recipe imports to Mealie with a deep link out. Single-user, no accounts, ephemeral.

## Language

### Source & Input

**Reel**
An Instagram reel identified by a URL; the primary recipe source a job is built from.
_Avoid_: video, post, clip

**Caption**
The text accompanying a reel. It is the primary text source for recipe extraction and the fallback input when fetch fails.
_Avoid_: description, post text

**Paste-caption fallback**
The recovery path where the user pastes the caption text directly after a reel fetch fails; it reuses the same job rather than starting a new one.
_Avoid_: manual input, paste mode

### Pipeline & Jobs

**Job**
A single pipeline run that turns one reel (or pasted caption) into one Mealie recipe. Its identity is the `job_id`, which is preserved across retries and state transitions.
_Avoid_: run, task, request

**Stage**
A discrete step in a job's pipeline. The canonical stages are `fetch`, `transcribe`, `llm_format`, `llm_merge`, and `mealie_import`. `llm_merge` refines the local recipe draft with transcription — it is not a Mealie-side merge.
_Avoid_: step, phase

**Terminal state**
A job's final outcome: succeeded, failed, or aborted.
_Avoid_: status, result

**Recent jobs**
The in-app, time-boxed history of previously run jobs, reused to re-open or retry them.
_Avoid_: job log, history

### Extraction & Routing

**Transcribe**
Convert a reel's audio to text, via Whisper.
_Avoid_: speech-to-text, STT

**Recipe verdict**
The LLM's classification of how complete the extracted recipe is: `recipe_complete`, `recipe_partial`, or `no_recipe`. It is carried in the response envelope's `completeness` field alongside the list of `missing_fields`.
_Avoid_: completeness flag, verdict

**Transcribe-anyway override**
A user action that forces transcription even when the caption already yielded a complete recipe; it re-runs the partial path and updates the Mealie recipe in place (same slug).
_Avoid_: force-transcribe, override

### Recipe Representation

**Recipe draft**
The local, in-progress recipe a job builds and refines (through `llm_format` → `llm_merge` → ingredient review) before it is posted to Mealie. It holds the name, description, yield, times, tags, raw ingredient strings, and instruction steps.
_Avoid_: recipe object, recipe struct

**Mealie recipe**
The recipe entity persisted in Mealie, identified by a slug.
_Avoid_: imported recipe

**Slug**
Mealie's stable identifier for a recipe; it is used to build deep links and to update a recipe in place.
_Avoid_: id, recipe id

**Deep link**
A URL into Mealie's UI (view/edit) for an imported recipe, built from its slug.
_Avoid_: link-out, outbound link

### Ingredient Resolution

**Ingredient parser**
Mealie's classifier (modes: `nlp`, `brute`, `openai`) that turns a raw ingredient string into a structured quantity/unit/food with per-field confidence.
_Avoid_: parser, ingredient classifier

**Parsed ingredient**
The parser's output: the original input string plus a structured ingredient (quantity, unit, food, note) and its per-field confidence.
_Avoid_: classification

**Confidence**
The per-field score (quantity, unit, food, comment, average) the parser assigns to an ingredient classification; it decides whether human review is required.
_Avoid_: score, certainty

**Unknown ingredient**
An ingredient the parser could not confidently classify — food confidence below 0.85, or `food.id`/`unit.id` is null.
_Avoid_: unrecognized ingredient, low-confidence ingredient

**Batch review**
The single-screen, pre-import review where a user confirms or edits unknown ingredients before any Mealie POST.
_Avoid_: review screen, ingredient review

**Picker**
The candidate selector (foods/units from Mealie search) offered during batch review as the primary resolution affordance, with an inline-edit escape hatch.
_Avoid_: selector, candidate list

### Errors & Retries

**Error stage**
The pipeline stage where a failure occurred: `fetch`, `transcribe`, `llm_format`, `llm_merge`, or `mealie_import`.
_Avoid_: failed step

**Error class**
The per-stage failure vocabulary: `extraction`, `rate_limited`, `ip_banned`, `cookie_expired`, `network`, `timeout`, `api_error`, `auth`, `validation`.
_Avoid_: error type, failure reason

**Retry**
Resetting the same job (same `job_id`) to re-run from the failed stage, capped at 2 attempts per stage and reset on stage success.
_Avoid_: rerun, resubmit

### Instagram Access

**yt-dlp**
The sidecar binary that downloads reels; a hard build dependency that must support browser impersonation.
_Avoid_: downloader

**Impersonation**
yt-dlp's browser-impersonation capability, required for Instagram access in mid-2026.

**Cookie**
An optional Instagram `sessionid` used for authenticated fetching, enabled opt-in via a path.
_Avoid_: auth cookie, session cookie

**Preflight**
The boot-time check that yt-dlp is present, versioned (≥ 2026.07.04), and impersonation-capable; its absence halts boot.
_Avoid_: startup check, boot check

**Degraded mode**
The boot state when yt-dlp is present but old/incompatible: the app falls back to caption-only input behind a global banner and removes the reel-URL input.
_Avoid_: safe mode, fallback mode
