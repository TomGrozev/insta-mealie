# Code Review Feedback

**Diff:** All changes since `main` (committed + uncommitted + untracked)

## lib/insta_mealie/llm.ex

### Lines 425-433 (new)
This conversion to a mealie payload realyl should happen in mealie not here.

## lib/insta_mealie/mealie.ex

### Line 14 (new)
This is never called publicly. The seam is really the import_recipe function. This could be private.

### Line 38 (new)
Under what conditions would we actually ever need to update a recipe? If a recipe exists, does this mean we would be overwriting it?

After looking at the pipeline it seems that we create the recipe before the ingredient review. This seems inefficient, shouldn't we just parse the ingredients then import into mealie once at the end once we are happy?

### Line 54 (new)
Why is the image only updated here and not on create?

### Lines 104-120 (new)
Why just food confidence and not also the unit confidence? Surely both should play into it. If we have low confidence for either we really should make the user review it.

### Lines 156-178 (new)
As per my comment above, I think this should be the seam and we only do create once, updating seems silly unless there is a good reason.

## lib/insta_mealie/pipeline.ex

### Line 325 (new)
Why are we doing cleaning and not doing it at the source? This seems like poor design.

### Lines 390-396 (new)
As mentioned, this double import process is silly.




Treat the findings above as unverified review input. Inspect every finding against the actual code; do not assume automated feedback is correct. For each finding, give a clear verdict (Confirmed / Partly / Not a bug / Intended) with concise code evidence. Say whether it was introduced by the current changes, was pre-existing, or reflects deliberate scope.

Review only the incoming findings. Do not independently review the rest of the diff or search for issues that were not submitted.

Do not change any code until we have discussed the verdicts and validated findings

