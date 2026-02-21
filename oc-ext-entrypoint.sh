#!/usr/bin/env bash
# On container start: git pull all repos in /myapps, optionally install/build them.
# Then exec the main process. Default SKIP_BUILD=true (pull only, no install/build).
# If the base image had an entrypoint (e.g. openclaw:local-whisper uses /app/start.sh),
# we delegate to it so task-manager + gateway behavior is preserved.
set -euo pipefail

# Pull all custom app repos in /myapps
if [[ -d /myapps ]]; then
  for repo_dir in /myapps/*; do
    if [[ -d "$repo_dir" ]] && [[ -d "$repo_dir/.git" ]]; then
      echo "Pulling $repo_dir..."
      cd "$repo_dir"
      git pull --ff-only || true
      
      # Optional: install/build if SKIP_BUILD=false
      if [[ "${SKIP_BUILD:-true}" == "false" ]] || [[ "${SKIP_BUILD:-true}" == "0" ]]; then
        if [[ -f package.json ]]; then
          echo "Installing dependencies in $repo_dir..."
          npm install
          if grep -q '"build"' package.json; then
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

# Backward compat: if base image had a startup script (e.g. local-whisper), run it with args.
# When /app is volume-mounted, /app/start.sh is hidden; use the copy we put in /entrypoint-helper.
if [[ -x /app/start.sh ]]; then
  exec /app/start.sh "$@"
fi
if [[ -x /entrypoint-helper/start.sh ]]; then
  exec /entrypoint-helper/start.sh "$@"
fi
exec "$@"
