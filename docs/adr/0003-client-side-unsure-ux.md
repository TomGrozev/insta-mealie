# Client-side "unsure" UX for unknown ingredients

Mealie's ingredient parser (`POST /api/parser/ingredient(s)`) returns a single best-guess `ParsedIngredient` with per-field confidence and exposes no candidates array, yet the app must resolve ingredients the parser could not classify (food confidence < 0.85, or null `food.id`/`unit.id`). We build the "unsure" resolution entirely client-side: on low confidence, show a Picker populated from `/api/foods?search=` and `/api/units?search=` (5 candidates) with an inline-edit escape hatch, then commit raw food/unit names and let Mealie auto-create them server-side. All review happens in a single-screen batch review BEFORE any Mealie POST. (Resolved in #3 and #6.)

**Considered Options**
- Client-side picker from Mealie foods/units search — chosen (Mealie, not the LLM, is the source of truth for the user's pantry).
- Ask the LLM to propose candidates — rejected: LLM isn't authoritative for the user's ingredients.
- Post first, fix later in Mealie UI — rejected: leaves dirty data and breaks the review-before-POST invariant.

**Consequences**
- A pre-import review step is mandatory in the job flow; the job holds an un-posted payload draft plus per-field confidence.
- "Accept all & import" batches the commit; Mealie auto-creates unknown foods/units.
