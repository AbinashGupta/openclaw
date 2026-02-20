# Local Docker Setup with Whisper

This directory contains a local Docker configuration that extends OpenClaw with Whisper support.

## Files

- `OC-EXT-Dockerfile.local` - Extends the base OpenClaw image with Whisper
- `oc-ext-docker-build-local.sh` - Build script for creating the local image
- This file is gitignored and won't conflict with upstream updates

## Quick Start

### Option A: Build and use the local image

```bash
# Build both base and local images
./oc-ext-docker-build-local.sh

# Use the local image with docker-compose
export OPENCLAW_IMAGE=openclaw:local-whisper
docker compose -f docker-compose.yml up -d openclaw-gateway
```

### Option B: Build manually

```bash
# Build base image first
docker build -t openclaw:local -f Dockerfile .

# Build local image with Whisper
docker build -t openclaw:local-whisper -f OC-EXT-Dockerfile.local .

# Use it
docker compose -f docker-compose.yml up -d openclaw-gateway
```

## What's Installed

The local image adds:
- **ffmpeg** - Audio processing library required by Whisper
- **python3-pip** - Python package manager
- **openai-whisper** - OpenAI's Whisper speech recognition model

## Updating OpenClaw

When you pull new changes from upstream:

```bash
# Pull latest changes
git pull origin main

# Rebuild both images
./oc-ext-docker-build-local.sh

# Restart containers
docker compose -f docker-compose.yml up -d openclaw-gateway
```

Your `OC-EXT-Dockerfile.local` won't be affected by upstream changes since it's gitignored.

## Environment Variables

- `OPENCLAW_IMAGE` - Base image name (default: `openclaw:local`)
- `OPENCLAW_LOCAL_IMAGE` - Local image name (default: `openclaw:local-whisper`)

## Troubleshooting

If you get "image not found" errors, make sure you've built the base image first:

```bash
docker build -t openclaw:local -f Dockerfile .
```

Then build the local image:

```bash
docker build -t openclaw:local-whisper -f OC-EXT-Dockerfile.local .
```
