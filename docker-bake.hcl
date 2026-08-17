target "docker-metadata-action" {}

variable "APP" {
  default = "insta-mealie"
}

# InstaMealie builds from local source — there is no upstream re-layer and
# therefore no upstream version to pin. VERSION is intentionally absent.

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