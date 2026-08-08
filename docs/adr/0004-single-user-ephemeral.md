# Single-user, no accounts, ephemeral by design

InstaMealie is a personal pipeline that pushes one person's Instagram reels into their own Mealie instance. We design for a single user with no account system and treat all job and pipeline state as ephemeral — there is no durable store, and losing state on app restart is acceptable. This keeps the app a thin, stateless-ish importer in front of Mealie (the system of record) rather than a multi-user product. (Stated in the wayfinder map, #1; reinforced by the in-memory ETS job-tracking decision in ADR 0001.)

**Considered Options**
- Single-user, no accounts, ephemeral — chosen.
- Add account/login and per-user scoping — rejected: unjustified complexity for a personal tool.
- Build multi-tenant from the start — rejected: over-engineering; no sharing requirement.

**Consequences**
- No authentication, sessions, or user-scoped data model in the UI or backend.
- State loss on restart is acceptable (no DB); pairs with ADR 0001's ETS store.
- Mealie remains the durable system of record for recipes; InstaMealie holds only transient job state.
