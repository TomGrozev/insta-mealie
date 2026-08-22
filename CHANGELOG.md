# Changelog

All notable changes to InstaMealie will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## 0.1.0 (2026-08-22)


### Features

* add T1 happy-path pipeline spine ([#20](https://github.com/TomGrozev/insta-mealie/issues/20)) ([8e50781](https://github.com/TomGrozev/insta-mealie/commit/8e5078153d978a3f05320f9a3b6452e924ee2c8f))
* implement T2 routing verdict branches ([#21](https://github.com/TomGrozev/insta-mealie/issues/21)) ([2cc6602](https://github.com/TomGrozev/insta-mealie/commit/2cc6602407c399fd9b74be9337f6387b30f583a9))
* implement T3 first live import — real yt-dlp fetch, Req-backed Mealie client, and boot preflight ([#22](https://github.com/TomGrozev/insta-mealie/issues/22)) ([a420d84](https://github.com/TomGrozev/insta-mealie/commit/a420d84edd4c7b9d7f00fc36a4e06240f83fb78b))
* implement T4 real LLM brain ([#24](https://github.com/TomGrozev/insta-mealie/issues/24)) ([e3a6904](https://github.com/TomGrozev/insta-mealie/commit/e3a69045593dfc4783d0cd70d1accb1a97b8ffd2))
* implement T5 error/retry surface (Variant B) ([e63dac1](https://github.com/TomGrozev/insta-mealie/commit/e63dac1bd8650d2afcc51580bb941f8c213d288a)), closes [#23](https://github.com/TomGrozev/insta-mealie/issues/23)
* implement T6 paste-caption overflow and degraded mode ([#25](https://github.com/TomGrozev/insta-mealie/issues/25)) ([c349428](https://github.com/TomGrozev/insta-mealie/commit/c349428c21b7456486c309b4544e1d50d07f3a3b))
* implement T7 transcribe-anyway override UI ([#26](https://github.com/TomGrozev/insta-mealie/issues/26)) ([4cc8a6d](https://github.com/TomGrozev/insta-mealie/commit/4cc8a6d4fa8cddcdf93211b0011ced1e7b620211))
* implement T8 unknown-ingredient review screen ([#27](https://github.com/TomGrozev/insta-mealie/issues/27)) ([3daecae](https://github.com/TomGrozev/insta-mealie/commit/3daecae0c83a712222342e9450fdf96e4fabd159))
* **pipeline:** follow recipe links as a supplementary merge source ([c40f8cc](https://github.com/TomGrozev/insta-mealie/commit/c40f8cc694aaacaee2f6210b7a5f071059b24316))
* **web:** redesign job list and ingredient review UI ([990e937](https://github.com/TomGrozev/insta-mealie/commit/990e937303582bdb505544536d39397545dbec65))


### Bug Fixes

* address code-review findings ([90bfe84](https://github.com/TomGrozev/insta-mealie/commit/90bfe84cc5b9d16ccd92fb0b4025a1aafc0503af))
* create custom mealie foods and units ([72aa3ff](https://github.com/TomGrozev/insta-mealie/commit/72aa3ffdbc07eeee5a941d9dabfa05936c1ddd34))
* image uploading ([4c88c21](https://github.com/TomGrozev/insta-mealie/commit/4c88c21564bf858e1d924fc92b893b84eabfe7ab))
* **ingredient:** keep structured fields when a parsed ingredient has a note ([59b469a](https://github.com/TomGrozev/insta-mealie/commit/59b469a291139e600f65e2b88898f77adee5a248))
* **llm:** propagate HTTP client errors instead of crashing ([8fc5d54](https://github.com/TomGrozev/insta-mealie/commit/8fc5d548c6a1b7d131c1634f3fab28d66df0b8ce))
* **mealie:** classify 404 distinctly, gate local image uploads to fetch dir ([87d6a0b](https://github.com/TomGrozev/insta-mealie/commit/87d6a0b6563f9a0bb5f7935eab5e7596cc5bfa4f))
* **pipeline:** correct ingredient payload, error stage, and recipe category key ([72ed4fa](https://github.com/TomGrozev/insta-mealie/commit/72ed4fa8f73f05506ae4a959986b878bc2006adc))
* **pipeline:** fix JobAdmission.cancel/1 queue corruption bug ([9d1a284](https://github.com/TomGrozev/insta-mealie/commit/9d1a28496cb2545b524db71070dd03ae5151c69a))
* **pipeline:** stop GenServer on terminal states, fix admission races ([7247b37](https://github.com/TomGrozev/insta-mealie/commit/7247b37b436ec912c4797f0237e1785567aeb8c1))
* **release:** do not pre-seed released version so first release is 0.1.0 ([3aa27e7](https://github.com/TomGrozev/insta-mealie/commit/3aa27e7cdd31576984c7b55daf6b7606199ceca3))
* rename ADR-0003 to ADR-0005 to avoid file-number collision with existing ADR ([07494bd](https://github.com/TomGrozev/insta-mealie/commit/07494bd8eaf92a25ece8b197030ae969d42a54de))
* **web:** fix ReviewLive retry crash and quantity display ([7ec3594](https://github.com/TomGrozev/insta-mealie/commit/7ec35944f4283b126b383deed8dc3fa1ce9fb87f))

## [0.1.0] - 2026-08-22

Initial release of InstaMealie — a single-user Phoenix application that turns Instagram reels into Mealie recipes.

This first release ships an end-to-end pipeline that takes you from an Instagram reel all the way to a published recipe in your own Mealie instance:

### Key features
- **Reel pipeline (T1–T8)**: ingest and process Instagram reels through a complete, observable pipeline, including following recipe links posted in reel captions.
- **Recipe generation**: LLM-driven extraction that converts reel content into clean, structured recipes.
- **Mealie integration**: publish the generated recipes straight into your Mealie instance.
- **Web UI**: an easy-to-use interface for monitoring the pipeline and managing your recipes.

Bug reports, feature requests, and contributions are welcome.
