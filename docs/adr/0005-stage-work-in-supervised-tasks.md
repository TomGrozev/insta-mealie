# ADR-0005: Stage work runs in supervised tasks

Date: 2026-08-09
Status: Accepted

## Context

Pipeline stages (`fetch`, `llm_format`, `transcribe`, `llm_merge`, `mealie_import`) originally ran synchronously inside the Job GenServer's `handle_info` clauses. This made per-stage timeouts and cancellation structurally ineffective — the process could not read its mailbox while a stage was running, so `{:stage_timeout, _}` and `:cancel` messages could only be processed *after* the stage completed.

## Decision

Each stage's blocking work now runs in a `Task.Supervisor.async_nolink` task. The Job GenServer holds the task reference and stays responsive to `:cancel` and `{:stage_timeout, _}` messages. On timeout or cancel, the task is killed via `Process.exit`.

Stage data (`fetch_data`, `transcript`) moves from `Process.put`/`Process.get` to the GenServer's state map. This makes the data visible to `transition/2`, `JobStore`, and any test that inspects a job. It also allows the revive path (#43) to explicitly refuse to resume a stage whose inputs it cannot reconstruct.

The `Task.Supervisor` is added to the Pipeline supervision tree as `InstaMealie.Pipeline.TaskSupervisor`.

## Consequences

- Per-stage timeouts now fire *while the stage is running*, not after.
- Cancelling a job during a running stage terminates it promptly.
- The revive path (#43) can introspect whether stage inputs are available.
- yt-dlp is still invoked via `System.cmd` (see ADR-0002). Moving to `Port.open` would enable OS-level process killing on timeout/cancel but is deferred to a future ADR.
