# OpenClaw Upgrade Guide

Repeatable process for upgrading the macOS app, CLI, and Docker gateway.
All three components share `~/.openclaw/` -- keeping them on the same version avoids
config schema mismatches.

---

## 1. Check Current Versions

```bash
# macOS app -- open OpenClaw.app > Settings > About
# or:
defaults read /Applications/OpenClaw.app/Contents/Info.plist CFBundleShortVersionString

# CLI (npm-installed)
openclaw --version

# Docker gateway
docker exec openclaw-openclaw-gateway-1 node dist/index.js --version
```

## 2. Find the Latest Published Version

### Docker image (GHCR)

Browse https://github.com/openclaw/openclaw/pkgs/container/openclaw or:

```bash
# List recent tags (requires ghcr.io auth or public access)
docker manifest inspect ghcr.io/openclaw/openclaw:latest 2>/dev/null && echo "latest tag exists"
```

Stable releases are tagged `YYYY.M.D` (e.g. `2026.2.15`). The `latest` tag always
points to the most recent stable release.

### macOS app and CLI

Check the GitHub releases page: https://github.com/openclaw/openclaw/releases

---

## 3. Upgrade the Docker Gateway

### Step 1 -- Backup

```bash
cp -r ~/.openclaw/agents ~/.openclaw/agents.bak
cp ~/.openclaw/openclaw.json ~/.openclaw/openclaw.json.pre-upgrade
```

### Step 2 -- Pull the new image

Replace `YYYY.M.D` with the target version:

```bash
docker pull ghcr.io/openclaw/openclaw:YYYY.M.D
```

### Step 3 -- Update OC-EXT-Dockerfile.local

Edit `OC-EXT-Dockerfile.local` and change the `FROM` line to point to the new version:

```dockerfile
FROM ghcr.io/openclaw/openclaw:YYYY.M.D
```

This is the **only file that needs editing**. The rest of the Dockerfile (ffmpeg,
whisper, USER switches) stays the same.

### Step 4 -- Rebuild the local image

```bash
docker build -t openclaw:local-whisper -f OC-EXT-Dockerfile.local .
```

This rebuilds just the thin whisper/ffmpeg layer on top of the pre-built base
(typically takes 1-2 minutes).

### Step 5 -- Restart the gateway

```bash
docker compose down openclaw-gateway
docker compose up -d openclaw-gateway
```

### Step 6 -- Verify

```bash
# Confirm version
docker exec openclaw-openclaw-gateway-1 node dist/index.js --version

# Check logs for errors
docker logs openclaw-openclaw-gateway-1 --tail 30

# Check container is running
docker ps --filter "name=openclaw"
```

---

## 4. Upgrade the macOS App

1. Go to https://github.com/openclaw/openclaw/releases
2. Download the `.dmg` asset for the target version.
3. Open the DMG and drag OpenClaw.app to `/Applications` (replace existing).
4. Launch the app and verify the version in Settings > About.

Alternatively, the app may auto-update via Sparkle if enabled.

---

## 5. Upgrade the CLI

```bash
npm i -g openclaw@latest
# or pin to a specific version:
npm i -g openclaw@YYYY.M.D

# Verify
openclaw --version
```

---

## Version Compatibility Rules

- **All three components should be on the same version** whenever possible.
- **Docker >= macOS app** is safe. A newer Docker gateway can always read config
  written by an older macOS app.
- **Docker < macOS app is dangerous.** A newer macOS app may write config schema
  changes that the older Docker gateway cannot parse. This is the root cause of
  errors like `ENOENT: no such file or directory, mkdir '/home/node'`.
- The version mismatch warning in logs (`Config was last written by a newer
  OpenClaw`) is a sign that the gateway needs upgrading.

### Recommended upgrade order

1. Docker gateway (first -- so it can read any new config)
2. macOS app (second)
3. CLI (any time)

---

## Rollback

### Restore config and agent data

```bash
cp ~/.openclaw/openclaw.json.pre-upgrade ~/.openclaw/openclaw.json
rm -rf ~/.openclaw/agents && mv ~/.openclaw/agents.bak ~/.openclaw/agents
```

### Revert Docker to previous version

Edit `OC-EXT-Dockerfile.local` and change the `FROM` line back to the previous version:

```dockerfile
FROM ghcr.io/openclaw/openclaw:PREVIOUS.VERSION
```

Then rebuild and restart:

```bash
docker build -t openclaw:local-whisper -f OC-EXT-Dockerfile.local .
docker compose down openclaw-gateway
docker compose up -d openclaw-gateway
```

### Revert macOS app

Download the previous version DMG from GitHub releases and reinstall.

---

## Gotchas

### Shared config directory

The macOS app and Docker gateway both read/write `~/.openclaw/`. The Docker
container mounts it via:

```yaml
volumes:
  - ~/.openclaw:/home/node/.openclaw
  - ~/.openclaw/workspace:/home/node/.openclaw/workspace
```

Any config change made by either side is immediately visible to the other.

### Claude/session env vars

The `CLAUDE_AI_SESSION_KEY`, `CLAUDE_WEB_SESSION_KEY`, and `CLAUDE_WEB_COOKIE`
warnings during `docker compose up` are harmless if you don't use those providers.

### Old local images

After upgrading, the previous `openclaw:local` and old `openclaw:local-whisper`
images remain on disk. Clean up with:

```bash
docker image prune
```

### Telegram polling conflict

If both the macOS app and Docker gateway have Telegram enabled with the same bot
token, you'll see `409 Conflict` errors. Only one instance should poll a given
bot token at a time.
