# ADR-0006: Recipe links are a supplementary source, scraped via Mealie

Date: 2026-08-13
Status: Accepted

## Context

Creators routinely put a link to their own recipe page in a reel's caption. Issue #50 proposed following that link and preferring it over the normal pipeline.

The example reel in that issue (`instagram.com/reel/Da6Pg1Bhtep`) disproves the "prefer" framing. Its caption is *Chocolate* Yogurt Chia Pudding and links to `foolproofliving.com/yogurt-chia-pudding/`, which is the **base** recipe the creator built it from — the caption says so explicitly. The page carries valid `schema.org/Recipe` JSON-LD with 7 ingredients and 4 instruction steps, but no cocoa. The caption lists cocoa but omits chia seeds entirely and has no method at all.

Preferring the link imports a recipe with no chocolate. Using the caption alone imports a chia pudding with no chia. Neither source is correct on its own; only a reconciliation of the two is.

## Decision

A recipe link is a **supplementary source**, not a replacement.

- Link extraction is a pure function over the caption and OP comments, called when building the `llm_format` prompt. The router receives an explicit candidate list (post-skip-list) and returns a `consult_link` boolean, independent of the recipe verdict.
- A new `scrape_link` stage runs **after** `llm_format`, sequentially, only when the router asked for it.
- Scraping uses Mealie's `POST /api/recipes/test-scrape-url`, which returns parsed recipe data without creating anything. Candidates are tried in order, capped at 3, within a single 60 s stage budget.
- The skip-list covers Instagram wrappers, link aggregators, and affiliate domains. URL shorteners are **not** skipped — Mealie follows redirects.
- The linked recipe enters `llm_merge` as an explicitly *suspect* source: it may fill gaps, and may never overwrite what the caption states explicitly, rename the recipe, or remove an ingredient.
- If the linked recipe supplies content for every entry in `missing_fields`, transcription is skipped — a structural check, not another LLM call.
- Scrape failure never fails the job. The stage is marked `:unresolved` and the pipeline continues.
- Only `recipeIngredient`, `recipeInstructions`, `recipeYield` and times are taken. The reel's own thumbnail always wins as the image, since the linked page depicts a different dish. `orgURL` is the reel; the linked page URL goes in notes.

## Considered Options

- **Prefer the link outright (#50 as written)** — rejected: imports the wrong recipe whenever the link is a base or related recipe, which the issue's own example is.
- **Mealie `POST /api/recipes/create/url`** — rejected: Mealie scrapes *and* creates, bypassing the recipe draft, the caption entirely, and the batch review that ADR-0003 exists to provide.
- **Our own `Req` fetch + JSON-LD parser** — rejected: reimplements `recipe-scrapers` (which Mealie already runs, with site-specific parsers and a wild-mode fallback), promotes `lazy_html` to a runtime dependency, and makes arbitrary-URL egress a new surface in this app rather than one Mealie already owns.
- **Scraping in parallel with `llm_format`** — rejected: the saving is bounded by one scrape's duration on a job that runs tens of seconds, and it breaks ADR-0005's single-in-flight-stage model (`%Job{stage: atom}` is singular, and `{:stage_timeout, stage}` matches against it) as well as the linear stage strip.
- **Eager scrape *before* `llm_format`** — rejected for now, but noted: it would let the router judge the linked recipe by its content rather than by its URL, and removes the need for `consult_link`. This is the fallback if `consult_link` proves unreliable in practice.

## Consequences

- `recipe_complete` no longer implies "skip merge". Completeness and link-consultation are independent axes, so a complete caption with a link runs `llm_merge` without ever touching Whisper.
- `LLM.format/2` and `LLM.merge/3` change shape. Domain evidence moves out of `opts` into a fixed-arity `sources` tuple, leaving `opts` for call configuration.
- `scrape_link` is the first stage whose failure is survivable, introducing an `:unresolved` stage status alongside `:done`/`:failed`/`:skipped`. Named to avoid colliding with **Degraded mode**, which already means the yt-dlp boot fallback.
- The pipeline now couples to a Mealie endpoint named `test-scrape-url`. Mealie is self-hosted and upgraded at will, so this is a real upgrade risk; a rename or removal degrades every job to the pre-#50 behaviour rather than breaking it.
- The router judges links from URLs and caption text alone, never page content. It catches missing *sections* (no instructions, "full recipe on my blog") but cannot catch a caption that is silently wrong — the omitted chia seeds would still slip through.
