# Mealie API Contract — InstaMealie Research Findings

**Research ticket:** Wayfinder #2
**Date:** 2025-07-21
**Mealie version:** v3.20.1 (latest release on `mealie-next` branch)
**Sources:** Mealie source on GitHub (`mealie-recipes/mealie`, branch `mealie-next`), official docs at docs.mealie.io, OpenAPI spec at demo.mealie.io/docs

## 1. Auth Flow

### Token Acquisition

Mealie uses **JWT Bearer tokens** with HS256 signing.

**Endpoint:** `POST /api/auth/token`

- Content-Type: `application/x-www-form-urlencoded` (not JSON!)
- Body fields: `username`, `password`, `remember_me` (boolean, defaults to false)
- Returns:
  ```json
  {
    "access_token": "<jwt-token>",
    "token_type": "bearer"
  }
  ```

**Source:** `mealie/routes/auth/auth.py` — `get_token()` function; `CredentialsRequestForm` class uses FastAPI `Form()` dependency.

### Token Usage

- Header: **`Authorization: Bearer <token>`**
- The FastAPI `OAuth2PasswordBearer` scheme is configured with `tokenUrl="/api/auth/token"`.
- As a fallback, Mealie also checks the **`mealie.access_token` cookie** (used by the web UI) — visible in `mealie/core/dependencies/dependencies.py`. API clients should use the `Authorization: Bearer` header exclusively.

### Token Lifetime & Rotation

- **Default lifetime:** 48 hours (`TOKEN_TIME = 48` in settings, unit is hours)
- Configurable via `TOKEN_TIME` env var. Minimum 1 hour, maximum 400 days (9600 hours).
- `remember_me=true` extends the token to a longer duration.
- **Refresh endpoint:** `GET /api/auth/refresh` — requires a valid token, returns a new token. Simple swap, not a refresh-token rotation scheme.
- **No refresh token / refresh token rotation** — Mealie uses single JWTs. If the token expires, the client must re-authenticate with username/password.
- **Long-lived API tokens** are a separate concept: created via the web UI at `/user/profile/api-tokens`. These are stored in the DB and validated separately (the JWT payload includes a `long_token` flag and `id`). They don't expire in the same way as session tokens. For our InstaMealie integration, these are the recommended tokens — they survive container restarts and don't require re-authentication.

### OIDC Support

Mealie supports OpenID Connect (`/api/auth/oauth` and `/api/auth/oauth/callback`). Not relevant for our headless API client use case.

**Sources:** `mealie/routes/auth/auth.py`, `mealie/core/security/security.py`, `mealie/core/dependencies/dependencies.py`, `mealie/core/settings/settings.py`, `docs.mealie.io/documentation/getting-started/api-usage/`

## 2. Recipe Create Endpoint

### For a pre-formed JSON payload (our use case):

**Endpoint:** `POST /api/recipes`

- **Status:** 201 Created
- **Request body:** A `Recipe` JSON object (the full recipe schema)
- **Response body:** `string` — the **slug** of the newly created recipe

**Important nuance:** The route accepts `CreateRecipe` for the type hint, but the actual `self.service.create_one(data)` call accepts a `Recipe` object. The `CreateRecipe` schema only has `name: str`. However, the **full `Recipe` schema is accepted** because Mealie's service layer handles both — it creates a minimal recipe from `CreateRecipe` or accepts a full `Recipe` payload via `PUT /api/recipes/{slug}` for updates.

**For creating with full data in one call, use:**

- `POST /api/recipes` with `{"name": "My Recipe"}` → returns slug, then `PUT /api/recipes/{slug}` with the full payload.

**OR** (better approach for our use case): Create a minimal recipe first, then update it with full data:

```
POST /api/recipes          → {"name": "Chicken Tikka Masala"}  → returns "chicken-tikka-masala"
PUT  /api/recipes/chicken-tikka-masala  → full Recipe JSON     → returns updated Recipe
```

### Alternative: Create + Full Payload in One Step

The `PUT /api/recipes/{slug}` endpoint:

```python
@router.put("/{slug}")
def update_one(self, slug: str, data: Recipe):
    """Updates a recipe by existing slug and data."""
```

This accepts the **full `Recipe` schema** and replaces the recipe entirely. The `PATCH` variant also exists for partial updates.

### Response Shape

The `create_one` endpoint returns just the slug as a string. The `get_one` and `update_one` endpoints return the full `Recipe` object.

**Sources:** `mealie/routes/recipe/recipe_crud_routes.py` — `create_one()`, `update_one()`, `get_one()`, `mealie/routes/__init__.py` — router prefix `/api`

## 3. Payload Schema

The full recipe schema is defined in `mealie/schema/recipe/recipe.py`. Complete field inventory:

### Top-Level Fields (from `RecipeSummary` and `Recipe`)

| Field | Type | Required | Default | Notes |
|-------|------|----------|---------|-------|
| `name` | `str` | **Yes** | — | Only truly required field. Used to generate slug. |
| `slug` | `str` | No | auto-generated from `name` | Do not set manually unless you need a specific slug. |
| `description` | `str \| None` | No | `""` | |
| `recipeServings` | `float` | No | `0` | |
| `recipeYieldQuantity` | `float` | No | `0` | |
| `recipeYield` | `str \| None` | No | `None` | e.g., "4 servings", "2 loaves" |
| `totalTime` | `str \| None` | No | `None` | ISO 8601 duration string, e.g., `"PT1H30M"` |
| `prepTime` | `str \| None` | No | `None` | ISO 8601 duration, e.g., `"PT15M"` |
| `cookTime` | `str \| None` | No | `None` | ISO 8601 duration, e.g., `"PT45M"` |
| `performTime` | `str \| None` | No | `None` | Total active time |
| `rating` | `float \| None` | No | `None` | |
| `orgURL` | `str \| None` | No | `None` | Original source URL (alias: `orgURL`) |
| `recipeCategory` | `list[RecipeCategory] \| None` | No | `[]` | Array of `{name: str}` objects |
| `tags` | `list[RecipeTag] \| None` | No | `[]` | Array of `{name: str}` objects |
| `tools` | `list[RecipeTool]` | No | `[]` | |
| `recipeIngredient` | `list[RecipeIngredient]` | No | `[]` | **See detailed section below** |
| `recipeInstructions` | `list[RecipeStep] \| None` | No | `[]` | **See detailed section below** |
| `nutrition` | `Nutrition \| None` | No | `None` | **See detailed section below** |
| `settings` | `RecipeSettings \| None` | No | `None` | |
| `assets` | `list[RecipeAsset] \| None` | No | `[]` | |
| `notes` | `list[RecipeNote] \| None` | No | `[]` | |
| `extras` | `dict \| None` | No | `{}` | Custom key-value store |

### `recipeInstructions` — RecipeStep objects

Each step is a `RecipeStep`:

```json
{
  "id": "uuid (auto-generated)",
  "title": "Section Title or null",
  "summary": "optional summary",
  "text": "The instruction text (REQUIRED)",
  "ingredientReferences": [
    {"referenceId": "uuid-of-ingredient"}
  ]
}
```

- `text` is the **only required field** per step.
- `ingredientReferences` links steps to ingredients by their `referenceId` UUIDs.
- For a simple case, just pass `[{"text": "Step 1 instructions here"}]`.

### `recipeIngredient` — Ingredient objects

Each ingredient is a `RecipeIngredient`:

```json
{
  "quantity": 2.0,
  "unit": {"name": "cups"},
  "food": {"name": "flour"},
  "note": "sifted",
  "title": "Section header (optional)",
  "originalText": "2 cups flour, sifted",
  "referenceId": "uuid (auto-generated)"
}
```

**Shortcut: You can pass raw strings!** The `Recipe` model has a `validate_ingredients` validator:

```python
@field_validator("recipe_ingredient", mode="before")
def validate_ingredients(recipe_ingredient):
    if all(isinstance(elem, str) for elem in recipe_ingredient):
        return [RecipeIngredient(note=x) for x in recipe_ingredient]
    return recipe_ingredient
```

So `"recipeIngredient": ["2 cups flour", "1 tsp salt"]` is valid — each string becomes `RecipeIngredient(note="2 cups flour")`. The note is a fallback display string.

**For structured ingredients**, the `unit` and `food` fields accept:
- Full objects: `{"name": "cup", "fraction": true, "useAbbreviation": false}`
- Strings (auto-wrapped): `"cup"` becomes `{"name": "cup"}`
- `null` if not applicable

### `nutrition` — Nutrition object

```json
{
  "calories": "250",
  "carbohydrateContent": "30g",
  "cholesterolContent": "50mg",
  "fatContent": "10g",
  "fiberContent": "5g",
  "proteinContent": "15g",
  "saturatedFatContent": "3g",
  "sodiumContent": "200mg",
  "sugarContent": "8g",
  "transFatContent": "0g",
  "unsaturatedFatContent": "7g"
}
```

All fields are strings (not numbers) — `coerce_numbers_to_str=True` in the model config. All are optional.

### `settings` — RecipeSettings

```json
{
  "public": false,
  "showNutrition": false,
  "showAssets": false,
  "landscapeView": false,
  "disableComments": true,
  "locked": false
}
```

### `notes` — RecipeNote objects

```json
{"title": "Chef's Note", "text": "This works best with fresh herbs"}
```

Both `title` and `text` are required strings.

### Time Fields

- `prepTime`, `cookTime`, `totalTime`, `performTime` — all accept ISO 8601 duration strings (e.g., `"PT1H30M"` for 1 hour 30 minutes).
- They also accept plain numbers/strings via the `clean_strings` validator.

### Tags & Categories (Shortcuts)

The validators on `Recipe` allow passing **plain strings** for tags and categories:

```json
{"tags": ["Easy", "Italian"], "recipeCategory": ["Dinner"]}
```

These are auto-wrapped into `{name, slug, id}` objects with new UUIDs.

### What Happens if Fields Are Omitted?

- `name` is required — omitting it causes a validation error.
- Everything else defaults gracefully (empty lists, null, empty strings).
- **No rejection for missing optional fields** — Mealie is permissive on create.

**Sources:** `mealie/schema/recipe/recipe.py`, `mealie/schema/recipe/recipe_ingredient.py`, `mealie/schema/recipe/recipe_step.py`, `mealie/schema/recipe/recipe_nutrition.py`, `mealie/schema/recipe/recipe_settings.py`, `mealie/schema/recipe/recipe_notes.py`, `mealie/schema/recipe/recipe_asset.py`, frontend TypeScript types `frontend/app/lib/api/types/recipe.ts`

## 4. Ingredient Parse Flow on Create

### No automatic parsing on create from raw strings

When you pass `"recipeIngredient": ["2 cups flour", "1 tsp salt"]`, Mealie stores each string as the `note` field of a `RecipeIngredient` — it does **not** run them through the NLP/brute-force parser. The validator simply wraps strings into `RecipeIngredient(note=x)`.

### Separate Parse Endpoint

Mealie has a dedicated ingredient parsing endpoint at `/api/parser/ingredients` (the `parser` router is included in the main router). The schema:

```json
POST /api/parser/ingredients
{
  "parser": "nlp",    // or "brute" or "openai"
  "ingredients": ["2 cups flour, sifted", "1 tsp salt"]
}
```

Response returns `ParsedIngredient[]` with structured `quantity`, `unit`, `food`, `confidence` fields (full details in ticket #3 research findings).

### Recommendation for InstaMealie

If the LLM already produces structured ingredients (quantity + unit + food), send them as structured objects. If the LLM produces raw text strings, either:
1. Send as-is (simple, but ingredients won't be structured for shopping lists/conversions)
2. Call the parse endpoint first, then send the parsed results in the create call

**Sources:** `mealie/schema/recipe/recipe.py` — `validate_ingredients` method, `mealie/schema/recipe/recipe_ingredient.py`

## 5. Deep-Link Routes (Web UI)

### Recipe View URL

```
/g/{groupSlug}/r/{recipeSlug}
```

Example: `https://mealie.example.com/g/my-family/r/chicken-tikka-masala`

**Source:** Nuxt.js file-based routing in `frontend/app/pages/g/[groupSlug]/r/[slug]/index.vue` and the SPA mount in `mealie/routes/spa/__init__.py`.

### Recipe Edit URL

Mealie's frontend uses a **query parameter** for edit mode, not a separate route. The same `/g/{groupSlug}/r/{recipeSlug}` page switches between view and edit modes via a `?edit=true` query parameter (controlled by `PageMode` in the frontend composable `usePageState`).

### Recipe Create URL

```
/g/{groupSlug}/r/create
```

With sub-pages: `/url`, `/html`, `/new`, `/image`, `/zip`, `/bulk`.

### API Get Endpoint (for recipe data)

```
GET /api/recipes/{slug_or_id}
```

Accepts either the slug or the UUID.

### URL Construction for InstaMealie

After creating a recipe, the create endpoint returns the `slug`. To build a link to view it:

```
{base_url}/g/{group_slug}/r/{slug}
```

The `group_slug` is needed — it can be obtained from the authenticated user's profile (`GET /api/users/self` returns `groupSlug`).

### Stability

These routes are part of the SPA routing and have been stable since v1. The pattern `/g/{groupSlug}/r/{slug}` is used in the SSR meta-tag injection code as well, so it's a stable public contract.

**Sources:** `mealie/routes/spa/__init__.py`, frontend routing `frontend/app/pages/g/[groupSlug]/r/[slug]/index.vue`

## 6. Image Attachment

### After Creation: Separate Endpoint

**Endpoint:** `PUT /api/recipes/{slug}/image`

- Content-Type: `multipart/form-data`
- Fields:
  - `image` (File) — the image binary
  - `extension` (Form string) — file extension, e.g., `"jpg"`, `"png"`, `"webp"`
- Response: `{"image": "<cache_key>"}` (the new image version hash)

### Alternative: Scrape Image from URL

**Endpoint:** `POST /api/recipes/{slug}/image`

- Request body: `{"url": "https://example.com/photo.jpg"}`
- Mealie downloads the image from the URL and stores it locally.

### Delete Image

**Endpoint:** `DELETE /api/recipes/{slug}/image`

### Recommended Flow for InstaMealie

1. `POST /api/recipes` with `{"name": "..."}` → get slug
2. `PUT /api/recipes/{slug}` with full recipe payload (without image)
3. `PUT /api/recipes/{slug}/image` with `image` file + `extension` form field

Or, if the LLM extracts an image URL from the reel:

1. Create the recipe
2. `POST /api/recipes/{slug}/image` with `{"url": "https://..."}` to have Mealie fetch it

### Media URLs for Existing Images

```
GET /api/media/recipes/{recipe_id}/images/original.webp?version={image_hash}
GET /api/media/recipes/{recipe_id}/images/min-original.webp?version={image_hash}
```

**Sources:** `mealie/routes/recipe/recipe_crud_routes.py`, `mealie/routes/media/media_recipe.py`

## Open Questions / Unconfirmed

1. **Create endpoint with full payload in one call:** The `POST /api/recipes` endpoint accepts `CreateRecipe` (which only has `name`), but in practice the service layer may accept the full `Recipe` schema via `POST`. This needs live testing — the safe approach is create-then-update.

2. **ISO 8601 time format confirmation:** The docs don't explicitly state that time fields require ISO 8601 durations. The frontend TypeScript types show `string` for these fields. The Pydantic `clean_strings` validator converts numbers to strings. Recommend testing with `"PT30M"` format.

3. **`recipeInstructions` as plain strings:** Like ingredients, it's unclear if `recipeInstructions` accepts an array of plain strings (auto-wrapped to steps) or strictly requires step objects. The validator pattern from ingredients suggests it may, but this was not explicitly visible in the schema code.

4. **Slug collision behavior:** If a recipe with the same name already exists, what happens? The code has an `IntegrityError` handler that returns "Recipe already exists" (400). This suggests slugs must be unique.

5. **Long-lived API token expiry:** The `TOKEN_TIME` setting controls session token expiry, but long-lived API tokens (created via UI) appear to have no explicit expiry — they're validated against the DB. Confirmed by `validate_long_live_token()` which just queries the `api_tokens` table.

6. **`group_slug` acquisition for deep links:** The authenticated user object (`GET /api/users/self`) should return `groupSlug`, but this wasn't confirmed from the schema files fetched. Recommend verifying via `GET /api/users/self` on a running instance.
