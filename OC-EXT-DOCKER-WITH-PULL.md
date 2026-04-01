# OpenClaw Docker Extension: git pull on start

Use this extension to get git-pull-on-start for custom apps in `/myapps` without modifying any upstream openclaw files. All files are prefixed with `oc-ext-` or `OC-EXT-` to avoid conflicts when pulling from upstream.

## How it works

- The image built from `OC-EXT-Dockerfile.local` includes whisper support, custom apps in `/myapps/*`, and git-pull-on-start functionality.
- Custom apps (like task-manager) are cloned into `/myapps/*` during the image build.
- On container start/restart, the entrypoint loops through `/myapps/*` and runs `git pull` in each repo, then optionally installs/builds if `SKIP_BUILD=false`.
- After pulling, it delegates to the startup script (`/app/start.sh`) which starts all apps.
- Default `SKIP_BUILD=true`: only `git pull`, then start (use existing `node_modules`/`dist` in the image or set `SKIP_BUILD=false` for a full refresh).

## Prerequisites

- Docker and Docker Compose.

## Build

Build the image from `OC-EXT-Dockerfile.local`:

```bash
cd /path/to/openclaw
docker build -t openclaw:local-whisper -f OC-EXT-Dockerfile.local .
```

This single image includes:
- OpenClaw base (from upstream)
- Whisper support (ffmpeg, openai-whisper)
- Custom apps in `/myapps/*` (task-manager)
- Git-pull-on-start entrypoint

## Run

Set `OPENCLAW_IMAGE` to the image you built (e.g. `openclaw:local-whisper`). Use the repo's compose file plus this override:

```bash
export OPENCLAW_IMAGE=openclaw:local-whisper
docker compose -f docker-compose.yml -f oc-ext-docker-compose.with-pull.yml up -d openclaw-gateway
```

On first run (or after pulling dependency changes), set `SKIP_BUILD=false` to install/build after pull:

```bash
export OPENCLAW_IMAGE=openclaw:local-whisper
SKIP_BUILD=false docker compose -f docker-compose.yml -f oc-ext-docker-compose.with-pull.yml up -d openclaw-gateway
```

CLI (e.g. onboard):

```bash
export OPENCLAW_IMAGE=openclaw:local-whisper
docker compose -f docker-compose.yml -f oc-ext-docker-compose.with-pull.yml run --rm openclaw-cli onboard
```

## Env vars

- **OPENCLAW_IMAGE** – Image to use (e.g. `openclaw:local-whisper`). Must be the image built from `OC-EXT-Dockerfile.local`.
- **SKIP_BUILD** – Default `true`. Set to `false` or `0` to run `npm install` and `npm run build` in each repo in `/myapps/*` after pull.

All other openclaw compose env vars (e.g. `OPENCLAW_CONFIG_DIR`, `OPENCLAW_GATEWAY_TOKEN`) are unchanged; set them as for the normal Docker setup.

## Adding more apps

To add more custom apps, edit `OC-EXT-Dockerfile.local` and add more `git clone` commands into `/myapps/`:

```dockerfile
RUN git clone https://github.com/user/other-app.git /myapps/other-app
WORKDIR /myapps/other-app
RUN npm install && npm run build
WORKDIR /app
```

Then rebuild the image. The entrypoint will automatically pull all repos in `/myapps/*` on container start.
