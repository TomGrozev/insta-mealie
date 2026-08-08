# In-memory ETS job tracking (no Oban)

A job is a single pipeline run (fetch → transcribe → llm_format → llm_merge → mealie_import) that needs progress tracking, abort, and a recent-jobs log. Because the app is single-user and ephemeral, we track jobs in an in-memory ETS table backed by one supervised GenServer per job (DynamicSupervisor + Registry), rather than adding Oban or a database. Durability across restarts is not a requirement, so ETS avoids a Postgres dependency and the operational weight of Oban for a one-concurrent-job workload. (Resolved in #5; retry behavior amended by #14.)

**Considered Options**
- Oban (Postgres-backed job queue) — rejected: heavy operational footprint and durability we do not need; overkill for single-user.
- ETS + GenServer per job — chosen.
- Pure GenServer state with no ETS — rejected: progress must be queryable for the recent-jobs log and survive light process restarts.

**Consequences**
- Job state is lost on app restart (acceptable: ephemeral). Recent-jobs log uses a 24h TTL, ~5min sweep, 500-row cap.
- No auto-retry at launch; retries reset the same `job_id` (amended by #14).
