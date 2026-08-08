# yt-dlp invoked via System.cmd, containerization deferred

Reels are downloaded by yt-dlp, a fast-moving binary whose Instagram-access behavior (impersonation, cookie rotation) changes constantly. We invoke yt-dlp as a sidecar binary via `System.cmd` per job, with opt-in cookie auth via `INSTA_MEALIE_IG_COOKIES_PATH`, and we defer Docker containerizing the app — yt-dlp is installed on the host (via pipx) with impersonation support. `System.cmd` keeps the integration simple and debuggable, and host-managed yt-dlp tracks Instagram changes far faster than a vendored image would. (Resolved in #7; boot check specified in #10.)

**Considered Options**
- `System.cmd` to host-installed yt-dlp — chosen.
- Vendor yt-dlp inside a Docker image — deferred: image staleness breaks Instagram access; host-managed pipx is fresher.
- Library binding / HTTP API instead of the CLI — not viable.

**Consequences**
- Boot preflight must verify yt-dlp presence, version (≥ 2026.07.04), and impersonation support, halting boot if absent.
- An absent binary is a boot-time failure, not a per-job error.
