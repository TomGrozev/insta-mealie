# Mealie Ingredient Parser API — Research Findings

**Ticket**: InstaMealie wayfinder #3
**Mealie version studied**: `mealie-next` branch (latest development, includes v1.7.0+ features)
**Date**: 2026-07-21

## 1. Available Parsers

Mealie registers three ingredient parser backends, selectable per-call via the `parser` field on the request body:

| Parser key | Internal class | Backend | Notes |
|---|---|---|---|
| `"nlp"` (default) | `NLPParser` | Python `ingredient_parser` library (Conditional Random Fields trained on ~100k NYT ingredients) | Default if `parser` field omitted. No external API key needed. |
| `"brute"` | `BruteForceParser` | Regex/heuristic token splitting (no ML) | Fastest, lowest quality. Useful as a fallback. |
| `"openai"` | `OpenAIParser` | Any OpenAI-compatible API (OpenAI, Ollama, Azure, etc.) | Requires AI provider configured in group settings. Available since v1.7.0. |

**How the parser is selected**: The `parser` field is a per-call parameter — each request to the parse endpoint specifies which parser to use. There is no instance-wide or user-level default stored server-side; the frontend remembers the user's last choice in local preferences (`useParsingPreferences`).

**Config knob names**: The parser enum is `RegisteredParser` with values `"nlp"`, `"brute"`, `"openai"`. No additional config knobs on the endpoint itself. The OpenAI parser reads its provider config (base_url, api_key, model) from the group's `aiProviderSettings`.

**Open Food Facts / other parsers**: Not present. The `ABCIngredientParser` interface is extensible (code comment says "you can register a new parser"), but only the three above are registered in `__registrar`. No Open Food Facts integration exists in the codebase.

**Fuzzy matching layer** (all parsers): After a parser produces a raw result, every parser calls `find_ingredient_match()` which fuzzy-matches the food name against the group's existing `ingredient_foods` database (threshold: 85% via `rapidfuzz`) and the unit against `ingredient_units` (threshold: 70%). This is how the parser links a parsed food string to an existing `IngredientFood` record (giving it an `id`). If no match is found above threshold, the food/unit remains a `CreateIngredientFood`/`CreateIngredientUnit` (name-only, no `id`).

**Sources**: `mealie/schema/recipe/recipe_ingredient.py` (`RegisteredParser` enum); `mealie/services/parser_services/ingredient_parser.py` (`__registrar` dict); `mealie/services/parser_services/_base.py` (`ABCIngredientParser`, `DataMatcher`); `docs/contributors/guides/ingredient-parser/`.

## 2. The Parse Endpoint(s)

Two endpoints, both under the `/parser` prefix (which itself lives under the user-scoped `/api` prefix):

### Single ingredient

```
POST /api/parser/ingredient
```

**Request body** (`IngredientRequest`):
```json
{
  "parser": "nlp",
  "ingredient": "1/2 cup flour, sifted"
}
```

**Response** (`ParsedIngredient`): single object (see §3).

### Batch ingredients

```
POST /api/parser/ingredients
```

**Request body** (`IngredientsRequest`):
```json
{
  "parser": "openai",
  "ingredients": [
    "1/2 cup flour, sifted",
    "2 large eggs",
    "pinch of salt"
  ]
}
```

**Response**: `list[ParsedIngredient]` — array of parsed results, same length and order as input.

**Error responses**: The docs/source do not document specific error schemas for these endpoints. The OpenAI parser raises a `ValueError` if the response count doesn't match input count. Standard FastAPI error responses (422 validation error, 500 internal) apply. No custom error model is defined.

**Authentication**: These are under `BaseUserController`, so they require authentication (session cookie or API token).

**Sources**: `mealie/routes/parser/ingredient_parser.py`; frontend API routes at `frontend/app/lib/api/user/recipes/recipe.ts` (confirms paths `/parser/ingredient` and `/parser/ingredients`).

## 3. Known-Ingredient Response Shape

Each parsed ingredient returns a `ParsedIngredient` object:

```json
{
  "input": "1/2 cup flour, sifted",
  "confidence": {
    "average": 0.92,
    "quantity": 1.0,
    "unit": 1.0,
    "food": 0.85,
    "comment": 1.0
  },
  "ingredient": {
    "quantity": 0.5,
    "unit": {
      "id": "uuid-or-null",
      "name": "cup",
      "plural_name": "cups",
      "description": "",
      "fraction": true,
      "abbreviation": "",
      "plural_abbreviation": "",
      "use_abbreviation": false,
      "aliases": [],
      "extras": {}
    },
    "food": {
      "id": "uuid-or-null",
      "name": "flour",
      "plural_name": null,
      "description": "",
      "label_id": null,
      "aliases": [],
      "extras": {},
      "label": null
    },
    "note": "sifted",
    "display": "1/2 cup flour, sifted",
    "title": null,
    "original_text": "1/2 cup flour, sifted",
    "reference_id": "uuid"
  }
}
```

**Key structural notes**:
- `unit` and `food` are **layered objects**, not flat strings. They can be either a full `IngredientUnit`/`IngredientFood` (with `id` when matched to the database) or a `CreateIngredientUnit`/`CreateIngredientFood` (name-only, no `id`, when the parser created a new entity).
- The `confidence` object has per-field granularity (quantity, unit, food, comment) plus an `average`.
- `display` is auto-computed from the components.
- `quantity` is a `float | null` (`NoneFloat`), rounded to 3 decimal places.

**Sources**: `mealie/schema/recipe/recipe_ingredient.py` (`ParsedIngredient`, `IngredientConfidence`, `RecipeIngredient`, `RecipeIngredientBase`, `IngredientFood`, `IngredientUnit` classes).

## 4. Unknown / Ambiguous Ingredient Response

**The API does NOT return a list of candidate interpretations.** There is no "unsure" status, no `candidates` array, and no multi-option response.

When the parser cannot confidently classify an ingredient, it does the following:

1. **Returns a single best guess** with low confidence scores in the `confidence` object.
2. **If the food name doesn't match any existing database food** (below the 85% fuzzy threshold), the `food` field comes back as a `CreateIngredientFood` — an object with a `name` string but **no `id`**. Same for units (no `id` means unmatched).
3. **If the parser truly can't parse** (especially OpenAI), the entire raw string is placed in the `note` field with `food` and `unit` as `null`.

The OpenAI parser prompt explicitly instructs: *"If uncertain about quantity, unit, or food, put the entire string in the note field."* This means unparsed ingredients appear as `{ quantity: 0, unit: null, food: null, note: "whole raw ingredient string" }`.

**The "unsure" UX is entirely client-side.** The frontend (`RecipePageParseDialog.vue`) implements this logic:

```typescript
function shouldReview(ing: ParsedIngredient): boolean {
  if ((ing.confidence?.average || 0) < confidenceThreshold) {  // threshold = 0.85
    return true;
  }
  const food = ing.ingredient.food;
  if (food && !food.id) {
    return true;
  }
  const unit = ing.ingredient.unit;
  if (unit && !unit.id) {
    return true;
  }
  return false;
}
```

When an ingredient needs review, the dialog shows it one-by-one with:
- The original input text
- The confidence score (with red/green indicator)
- An editable ingredient editor (quantity, unit, food, note fields)
- **"Create missing food" / "Create missing unit" buttons** — these POST to `/api/foods` or `/api/units` to create the new entity, then link it
- **"Add as alias" buttons** — if the parser matched a similar food but the text doesn't exactly match, the user can add the text as an alias to the matched food

**No candidate list is ever shown.** The user either accepts the parser's guess and creates a new food/unit, or manually edits the fields. There is no "pick one of these 3 options" interaction.

**Sources**: `mealie/services/parser_services/openai/parser.py` (prompt instruction); `mealie/services/parser_services/_base.py` (`find_ingredient_match` — returns `None` when no match above threshold); `frontend/app/components/Domain/Recipe/RecipePage/RecipePageParts/RecipePageParseDialog.vue` (`shouldReview`, `createMissingFood`, `createMissingUnit`, `addMissingFoodAsAlias`).

## 5. Does the Parser API Surface the "Select an Option" UI Interaction?

**No.** The Mealie parser API does not expose a "select an option" or "candidate interpretations" interaction.

The API contract is strictly: **one input → one output** (a single `ParsedIngredient` with a single best-guess `RecipeIngredient` and confidence scores). There is no endpoint that returns multiple candidate parses, no `alternatives` field in the response, and no `status: "unsure"` or `status: "ambiguous"` flag.

The web app achieves its human-confirmation UX through:

1. **Confidence-score gating**: The frontend applies a threshold (0.85) to `confidence.average`. Below threshold → prompt user to review.
2. **Missing-ID detection**: If `food.id` or `unit.id` is null (parser couldn't match to database), prompt user to create or link.
3. **Inline editing**: The user manually adjusts the parsed fields in an editor widget.
4. **Create-or-alias workflow**: The user either creates a new food/unit entity, or adds the unmatched text as an alias to an existing entity.

The "select an option" UX you see in the web UI is: **the parser makes one guess, the user sees it, and either accepts it (potentially after creating a new food/unit) or edits the fields manually.** There is no multi-candidate selection.

## 6. How to Replicate a "Select an Option" Interaction

Since the parser API doesn't provide candidates, here are the closest available approaches for InstaMealie:

### Option A: Use the `/api/foods` search endpoint for fuzzy matching

```
GET /api/foods?page=1&per_page=5&search=<unknown_food_text>
```

**Response**: `IngredientFoodPagination` — paginated list of `IngredientFood` objects matching the search text. Each has `id`, `name`, `aliases`, etc.

This is the **most promising approach**. When the parser returns a food with no `id` (or low confidence), call this endpoint with the food name. The top results become the candidate list for the user to pick from. This is essentially what the frontend does manually when it offers "create missing food" — but you could present a picker instead.

**Caveat**: The search is a simple string search (ILIKE on Postgres, LIKE on SQLite). With PostgreSQL, fuzzy search is also available. No BM25 or semantic matching — just substring matching. You may need to post-process results with your own scoring.

### Option B: Use the `/api/units` search endpoint similarly

```
GET /api/units?page=1&per_page=5&search=<unknown_unit_text>
```

Same pattern for units. Returns paginated `IngredientUnit` objects.

### Option C: Re-query the OpenAI parser with a candidates prompt

You could call the OpenAI parser a second time with a modified prompt asking it to return multiple candidate interpretations. This would require:
- Bypassing the standard `/api/parser/ingredients` endpoint
- Making a direct HTTP call to the OpenAI-compatible API (using the group's configured provider)
- Crafting a prompt like: *"For this ingredient string, return 3 possible interpretations of quantity/unit/food"*

This is more complex and adds latency/cost, but gives semantically better candidates than simple substring search.

### Option D: Use the existing `DataMatcher` fuzzy-match logic

The `DataMatcher` class in `_base.py` loads all foods/units into memory and uses `rapidfuzz` for matching. This is what the parser uses internally. You could replicate this logic client-side:
- Fetch all foods via `GET /api/foods?page=1&per_page=-1` (all items)
- Run `rapidfuzz.fuzz.ratio` against the unknown food name
- Present matches above a configurable threshold as candidates

This is what the parser does internally — you'd just be surfacing the intermediate fuzzy-match candidates instead of consuming only the top result.

### Recommendation

**Option A** (food/unit search endpoints) is the simplest and most maintainable for InstaMealie. The flow would be:

1. Call `/api/parser/ingredients` with the raw ingredient strings
2. For each result where `food.id` is null (unmatched), call `GET /api/foods?search=<food.name>`
3. Present the search results as candidate options for the user to pick from
4. On selection, link the chosen food's `id` to the ingredient (via the recipe update endpoint)

This reuses Mealie's existing infrastructure and doesn't require any OpenAI prompt engineering or custom matching logic.

## Open Questions / Unconfirmed

1. **`per_page=-1` for "all items"**: The code passes `per_page=-1` to `page_all()` to load all foods/units. The docs don't confirm whether `-1` is a documented API convention for "unlimited" or an internal implementation detail. Test against the live API.

2. **Search behavior differences (SQLite vs Postgres)**: Fuzzy search is only available on PostgreSQL. On SQLite, the `search` parameter is a simple `LIKE %term%`. If the InstaMealie deployment uses SQLite, the food search results may be less helpful.

3. **Food search field coverage**: The `GET /api/foods?search=` parameter searches against `_searchable_properties` which are `name_normalized` and `plural_name_normalized`. It does **not** search aliases by default in the search endpoint — aliases are only used by the parser's internal `DataMatcher`. If you want alias-based matching, you'd need to fetch all foods and do your own fuzzy search (Option D).

4. **No OpenAPI spec fetch confirmed**: The Swagger UI at `demo.mealie.io/docs` was fetched but rendered as a JS app (no content). The actual OpenAPI JSON wasn't retrieved. All endpoint shapes were confirmed from source code rather than the published spec. The paths should be verified against a running instance.

5. **Version drift**: The code studied is from the `mealie-next` branch (post-v3.x). Earlier versions (v1.x, v2.x) may have different parser routes or schema shapes. The `RegisteredParser` enum and endpoint paths are stable since v1.0, but the OpenAI parser and `IngredientConfidence.food` field are newer additions.

6. **No `candidates` field in any schema**: Confirmed by exhaustive search of the schema file (`recipe_ingredient.py`) and parser routes. The `ParsedIngredient` response has exactly three fields: `input`, `confidence`, `ingredient`. There is no `alternatives`, `candidates`, `suggestions`, or similar field.
