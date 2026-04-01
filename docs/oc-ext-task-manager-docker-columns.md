# Task-manager in Docker: columns endpoint returning empty

When running the [task-manager](https://github.com/AbinashGupta/task-manager) app inside the OpenClaw Docker image (e.g. `openclaw:local-whisper`), the **columns** endpoint (`GET /api/kanban/columns`) can return empty data while the **tasks** endpoint (`GET /api/tasks`) returns correct data. This doc explains why and how to debug/fix it.

## Relation to OpenClaw

- Task-manager is cloned at **build time** in `OC-EXT-Dockerfile.local` to `/app/task-manager` and started in the background by the entrypoint (`/app/start.sh`) on port **3847**.
- Data is persisted via the `task-manager-data` volume mount (see `oc-ext-docker-compose.override.yml`):  
  `${OPENCLAW_CONFIG_DIR}/task-manager-data` → `/app/task-manager/data`.
- Both endpoints use the same storage: `lib/storage/csvStorage.ts` with  
  `csvPath = process.env.CSV_PATH || path.join(process.cwd(), 'data', 'tasks.csv')`.

So if **tasks** returns correct data, `storage.getAllTasks()` is reading the correct CSV at runtime. The columns handler uses the same `getKanbanColumns()` which calls `storage.getAllTasks()` and then filters by status. So empty columns with non-empty tasks almost always means the **columns response is being cached** (e.g. from build-time or an earlier request when the CSV was empty).

## Trace logs in task-manager

The task-manager repo already has `console.log` trace logs you can use to see what is happening.

### Columns route

- **File:** `app/api/kanban/columns/route.ts`
- **Logs:**
  - `[COLUMNS-API] GET /api/kanban/columns — flow start` with `csvPath`
  - `[COLUMNS-API] GET /api/kanban/columns — getKanbanColumns returned` with counts and `taskIds`

### Task service (used by columns)

- **File:** `lib/services/taskService.ts` inside `getKanbanColumns()`
- **Logs:**
  - `[COLUMNS-API] getKanbanColumns — storage.getAllTasks() returned` with `count` and task list
  - `[COLUMNS-API] getKanbanColumns — filtered into columns` with per-column lengths

### Tasks route

- **File:** `app/api/tasks/route.ts`
- **Logs:**
  - `[TASKS-API] GET /api/tasks — flow start` with `csvPath`
  - `[TASKS-API] GET /api/tasks — listTasks returned` with `count` and task list

### How to see these logs in Docker

Next runs inside the same container as the gateway. Logs go to stdout/stderr of the gateway container:

```bash
# Follow gateway (and task-manager) logs
docker logs -f openclaw-openclaw-gateway-1

# Or if you use a different compose project name:
docker compose logs -f openclaw-gateway
```

Then call from another terminal:

- `curl http://localhost:3847/api/tasks`
- `curl http://localhost:3847/api/kanban/columns`

Compare the log lines: if you see `[TASKS-API]` with a non-zero count but no `[COLUMNS-API]` lines when you hit the columns endpoint, the columns route is likely **not running** (cached response). If you do see `[COLUMNS-API]` with `count: 0`, then the handler runs but reads empty data (path or file issue).

## Likely cause: static/prerender cache

In the task-manager repo, the columns route already has:

```ts
export const dynamic = 'force-dynamic';
```

and a comment: *"Prevent static prerender at build time (e.g. in Docker the CSV may be empty then)."*

If the Docker image was built with an **older** version of the route (without `force-dynamic`), or if Next still caches the response elsewhere:

1. At **build time** (no volume, empty or missing `data/tasks.csv`), Next may have prerendered `GET /api/kanban/columns` and cached the empty response.
2. At **runtime**, that cached response is returned for columns, while `/api/tasks` is always executed dynamically and reads the mounted CSV.

So columns appears empty while tasks is correct.

## Recommended fixes (in task-manager repo)

1. **Ensure the route is dynamic**  
   Keep `export const dynamic = 'force-dynamic'` in `app/api/kanban/columns/route.ts` and rebuild the Docker image so the running app includes it.

2. **Disable response caching**  
   In the same route, add no-store so browsers/proxies don’t cache the JSON:
   ```ts
   return NextResponse.json(response, {
     status: 200,
     headers: { 'Cache-Control': 'no-store, max-age=0' },
   });
   ```

3. **Pin CSV path in Docker (optional but robust)**  
   In `Dockerfile.local` or in your compose override, set the env for the gateway service so the app doesn’t depend on `process.cwd()`:
   ```yaml
   environment:
     CSV_PATH: /app/task-manager/data/tasks.csv
   ```
   (and ensure the task-manager app reads `process.env.CSV_PATH` in `lib/storage/csvStorage.ts`, which it already does.)

4. **Rebuild the image**  
   After any change to task-manager or the Dockerfile, rebuild so the container runs the updated code:
   ```bash
   docker build -t openclaw:local-whisper -f OC-EXT-Dockerfile.local .
   docker compose up -d
   ```

## Quick checklist

- [ ] Rebuild image after pulling latest task-manager (or after adding `force-dynamic` / Cache-Control).
- [ ] Confirm `OPENCLAW_CONFIG_DIR` is set and the volume mount exists (e.g. `task-manager-data` with `tasks.csv`).
- [ ] Hit both endpoints and watch `docker logs`; if columns returns empty and you see no `[COLUMNS-API]` logs, treat it as caching and apply/verify the fixes above.

If you add the task-manager repo to your workspace, you can edit `app/api/kanban/columns/route.ts` and `lib/services/taskService.ts` there; the trace log prefixes above will match those files.

---

## Verified: container vs workspace code (Feb 2026)

Curl and Docker logs were compared to the task-manager source under `/Users/abinmac/code/task-manager` (or your workspace root).

### API responses (after `curl` to both endpoints)

| Endpoint | Response |
|----------|----------|
| `GET http://localhost:3847/api/tasks` | `success: true`, `data: [ { id: "e136cd8e-...", title: "Miracle of Mind meditation", status: "todo", ... } ]` — real task from CSV. |
| `GET http://localhost:3847/api/kanban/columns` | `success: true`, `data: { todo: [], "in-progress": [], blocked: [], done: [] }` — empty columns. |

### Docker logs

- **No** `[TASKS-API]`, `[COLUMNS-API]`, or `csvPath` lines appear in `docker logs openclaw-openclaw-gateway-1` after hitting either endpoint.
- So either the route handlers that contain those `console.log` calls are not running (cached response), or the code running in the container does not contain those logs.

### Code inside the container vs workspace

The files **inside the running container** (`docker exec ... cat /app/task-manager/app/api/...`) were compared to the **workspace** task-manager:

| File | In container (image) | In workspace (`/Users/abinmac/code/task-manager`) |
|------|----------------------|---------------------------------------------------|
| `app/api/kanban/columns/route.ts` | No `export const dynamic = 'force-dynamic'`. No `storage` import. No `console.log`. GET just calls `getKanbanColumns()` and returns. | Has `dynamic = 'force-dynamic'`, `storage.getFilePath()`, and `console.log('[COLUMNS-API] ...')` (lines 8, 12, 16–28). |
| `app/api/tasks/route.ts` | No `storage` import. No `console.log`. GET uses `request.nextUrl.searchParams` and `listTasks(filters)`. | Has `console.log('[TASKS-API] ...')` (lines 9, 26–29). |

So the **image was built from an older revision** of task-manager (before `force-dynamic`, trace logs, and the `storage` import were added to the columns route).

### Why columns is empty and tasks is correct

1. **Tasks:** The in-container tasks route uses `request.nextUrl.searchParams`. Next.js treats it as **dynamic**, so the handler runs on every request and reads the mounted CSV → you see real data.
2. **Columns:** The in-container columns route has no `dynamic = 'force-dynamic'` and does not use `request`. Next.js can **prerender** that GET at build time. At build time there is no volume, so `data/tasks.csv` is empty → the prerendered response is `{ todo: [], ... }`. That cached response is what you get at runtime.

### Why you don’t see any task-manager logs

The running app in the container is the **old** code: it has no `[TASKS-API]` or `[COLUMNS-API]` `console.log` calls. So even when the tasks handler runs, nothing with those prefixes is printed. After you **rebuild the image** from the current task-manager (with trace logs and `force-dynamic`), redeploy and hit the endpoints again; you should then see the log lines in `docker logs` and columns should return real data.
