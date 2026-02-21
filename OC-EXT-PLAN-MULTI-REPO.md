# Multi-Repo Docker Setup Plan

## Goal

Run multiple custom applications (each as a git repo) alongside OpenClaw in a single container, with automatic `git pull` on container start/restart for each repo.

## Current State

- **`/app`** — OpenClaw application root (gateway, CLI, etc.) — inherited from base Dockerfile
- **`/app/task-manager`** — task-manager cloned here in `OC-EXT-Dockerfile.local`
- **`/app/start.sh`** — startup script that starts task-manager, then gateway

## Proposed Structure

Separate OpenClaw from custom apps:

- **`/app`** — OpenClaw application (not a git repo, just the app files)
- **`/myapps/task-manager`** — task-manager git repo
- **`/myapps/other-app`** — future custom apps (each as a git repo)
- **`/myapps/...`** — additional apps as needed

## Changes Required

### 1. Update `OC-EXT-Dockerfile.local`

Move task-manager clone from `/app/task-manager` to `/myapps/task-manager`:

```dockerfile
# Before:
RUN git clone https://github.com/AbinashGupta/task-manager.git /app/task-manager

# After:
RUN mkdir -p /myapps && \
    git clone https://github.com/AbinashGupta/task-manager.git /myapps/task-manager
```

Update task-manager install/build to use new path:

```dockerfile
# Before:
WORKDIR /app/task-manager

# After:
WORKDIR /myapps/task-manager
```

### 2. Update `/app/start.sh`

Change task-manager path from `/app/task-manager` to `/myapps/task-manager`:

```bash
# Before:
cd /app/task-manager && node node_modules/.bin/next start -H 0.0.0.0 -p 3847 &

# After:
cd /myapps/task-manager && node node_modules/.bin/next start -H 0.0.0.0 -p 3847 &
```

### 3. Update Extension Entrypoint (`oc-ext-entrypoint.sh`)

Replace single `/app` git pull with a loop that pulls all repos in `/myapps`:

```bash
#!/usr/bin/env bash
set -euo pipefail

# Pull all custom app repos in /myapps
if [[ -d /myapps ]]; then
  for repo_dir in /myapps/*; do
    if [[ -d "$repo_dir/.git" ]]; then
      echo "Pulling $repo_dir..."
      cd "$repo_dir"
      git pull --ff-only || true
      
      # Optional: install/build if SKIP_BUILD=false
      if [[ "${SKIP_BUILD:-true}" == "false" ]] || [[ "${SKIP_BUILD:-true}" == "0" ]]; then
        if [[ -f package.json ]]; then
          echo "Installing deps in $repo_dir..."
          npm install
          if [[ -f package.json ]] && grep -q '"build"' package.json; then
            echo "Building $repo_dir..."
            npm run build
          fi
        fi
      fi
    fi
  done
fi

# Return to /app (openclaw root) for startup
cd /app

# Delegate to base image's startup script if it exists
if [[ -x /app/start.sh ]]; then
  exec /app/start.sh "$@"
fi
if [[ -x /entrypoint-helper/start.sh ]]; then
  exec /entrypoint-helper/start.sh "$@"
fi
exec "$@"
```

### 4. Remove `/app` Volume Mount from Extension Compose

The extension compose (`oc-ext-docker-compose.with-pull.yml`) should **not** mount `/app`. The container should use the image's `/app` (openclaw) and `/myapps` (custom repos), with no host mounts.

## Benefits

1. **Clear separation**: OpenClaw at `/app`, custom apps at `/myapps`
2. **Scalable**: Add new apps by cloning into `/myapps/` in Dockerfile
3. **Automatic updates**: All repos in `/myapps` are pulled on container restart
4. **No conflicts**: Custom apps don't interfere with openclaw structure
5. **Self-contained**: No need for host mounts; everything is in the image

## Implementation Steps (Completed)

1. ✅ Update `OC-EXT-Dockerfile.local` to clone task-manager into `/myapps/task-manager`
2. ✅ Update `/app/start.sh` to reference `/myapps/task-manager`
3. ✅ Update `oc-ext-entrypoint.sh` to loop through `/myapps/*` and pull each repo
4. ✅ Remove `/app` mount from `oc-ext-docker-compose.with-pull.yml`
5. ⏳ Rebuild images and test

## Environment Variables

- **`SKIP_BUILD`** (default: `true`) — when `false`, runs `npm install` and `npm run build` in each repo after pull
- **`MYAPPS_PATH`** (optional future enhancement) — custom path instead of `/myapps` if needed

## Notes

- OpenClaw at `/app` is **not** a git repo (no `.git` in the image by default)
- Only custom apps in `/myapps/*` are git repos and get pulled
- Each app in `/myapps` is independent; add/remove by editing `OC-EXT-Dockerfile.local`
- The wrapper image (`OC-EXT-Dockerfile.with-pull`) adds the entrypoint; `OC-EXT-Dockerfile.local` defines which apps to clone
- All extension files use `oc-ext-` or `OC-EXT-` prefix to avoid conflicts with upstream
