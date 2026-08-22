target "docker-metadata-action" {}

variable "APP" {
  default = "insta-mealie"
}

# Image tags are injected via docker/metadata-action's bake-file output
# (see .github/workflows/docker.yml), driven by the triggering git ref:
# a `main` push produces `edge`/`sha-*` tags, a `vX.Y.Z` tag produces
# semver tags. No static VERSION variable is defined here.

group "default" {
  targets = ["image-local"]
}

target "image" {
  inherits = ["docker-metadata-action"]
  labels = {
    "org.opencontainers.image.source" = "https://github.com/TomGrozev/insta-mealie"
  }
}

target "image-local" {
  inherits = ["image"]
  output   = ["type=docker"]
  tags     = ["${APP}:local"]
}

target "image-all" {
  inherits = ["image"]
  platforms = [
    "linux/amd64",
    "linux/arm64"
  ]
}