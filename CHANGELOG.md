# Changelog

All notable changes to InstaMealie will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.1](https://github.com/TomGrozev/insta-mealie/compare/v0.1.0...v0.1.1) (2026-08-22)


### Bug Fixes

* patch CVEs from Grype/dependency scan ([a9f6948](https://github.com/TomGrozev/insta-mealie/commit/a9f6948e3e21df65c0c5af5131cd26ef48f74ae6))

## [0.1.0] - 2026-08-22

Initial release of InstaMealie — a single-user Phoenix application that turns Instagram reels into Mealie recipes.

This first release ships an end-to-end pipeline that takes you from an Instagram reel all the way to a published recipe in your own Mealie instance:

### Key features
- **Reel pipeline (T1–T8)**: ingest and process Instagram reels through a complete, observable pipeline, including following recipe links posted in reel captions.
- **Recipe generation**: LLM-driven extraction that converts reel content into clean, structured recipes.
- **Mealie integration**: publish the generated recipes straight into your Mealie instance.
- **Web UI**: an easy-to-use interface for monitoring the pipeline and managing your recipes.

Bug reports, feature requests, and contributions are welcome.
