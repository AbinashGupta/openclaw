#!/usr/bin/env bash
set -euo pipefail

# Build script for local OpenClaw with Whisper support
# This builds the base image first, then layers Whisper on top

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_IMAGE="${OPENCLAW_IMAGE:-openclaw:local}"
LOCAL_IMAGE="${OPENCLAW_LOCAL_IMAGE:-openclaw:local-whisper}"

echo "==> Building base OpenClaw image: $BASE_IMAGE"
docker build \
  --build-arg "OPENCLAW_DOCKER_APT_PACKAGES=${OPENCLAW_DOCKER_APT_PACKAGES:-}" \
  -t "$BASE_IMAGE" \
  -f "$ROOT_DIR/Dockerfile" \
  "$ROOT_DIR"

echo ""
echo "==> Building local image with Whisper: $LOCAL_IMAGE"
docker build \
  -t "$LOCAL_IMAGE" \
  -f "$ROOT_DIR/OC-EXT-Dockerfile.local" \
  "$ROOT_DIR"

echo ""
echo "✅ Build complete!"
echo "Base image:  $BASE_IMAGE"
echo "Local image: $LOCAL_IMAGE"
echo ""
echo "To use the local image, update your docker-compose.yml or set:"
echo "  export OPENCLAW_IMAGE=$LOCAL_IMAGE"
