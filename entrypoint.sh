#!/usr/bin/env sh
set -eu

# RELEASE_TMP (see Dockerfile ENV) and the yt-dlp fetch base both land under
# /tmp/insta_mealie so a single Kubernetes emptyDir on /tmp is sufficient for
# `readOnlyRootFilesystem: true` (see ADR 0007). HOME also points into /tmp
# so the BEAM VM can write ~/.erlang.cookie — ephemeral across restarts, which
# is fine because InstaMealie is single-node and does not cluster (ADR 0004).
mkdir -p /tmp/insta_mealie/release_tmp /tmp/bedrock/home

exec "$@"