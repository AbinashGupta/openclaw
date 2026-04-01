# Phases for Cloud Readiness + Migration (Starting from **Local Docker Only**)

> **Context assumption:** OpenClaw currently runs **only in local Docker**.  
> **Target outcome:** A safe, repeatable **local ↔ cloud runtime handoff** model with **single active runtime**, **scripted switching**, and **state continuity**, while preserving the current **extension-first / no-fork / file-based** architectural position.

---

## Phase 0 — Baseline Freeze & Operating Model Finalization

**Status: ✅ COMPLETE**

### Purpose
Lock the migration rules and scope **before** building cloud infra or automation.

### What was defined

- **Single active runtime invariant**: only **local OR cloud** runs at a time (never both). Both-down transition window enforced during all state transfers.
- Reframed migration language from "continuous bi-directional sync" → **"controlled handoff-based state transfer"**
- **Switch-script-only policy**: no manual start/stop during transition workflow; fail closed (abort on uncertainty); no conflict merge in v1
- Confirmed architectural constraints:
  - OpenClaw stays upstream / untouched (`oc-ext-*` extension layer only)
  - Extension layer remains external; no fork now
  - File-based state is acceptable for the single-writer stage
  - DB migration deferred until real concurrency/workflow pain appears

### The 3-concern v1 scope

1. **Stop safely** — quiesce source runtime cleanly
2. **Move state safely** — snapshot → copy via S3 → verify checksums/file counts
3. **Start safely** — version compatibility check + health/smoke test at destination

### Deferred explicitly (not v1)

| Deferred Item | Reason |
|---|---|
| Generic sync framework / pluggable engines | Single-script is sufficient |
| Conflict merge / reconciliation logic | Single writer means conflicts should never occur |
| Multi-operator workflow / permissions | Not applicable yet |
| Secrets sync automation (`.env` ↔ Secrets Manager) | Manual local `.env` + AWS Secrets Manager is fine |
| Runtime `git pull` mutation for built apps | Image version = code version is the correct model |
| Dashboard / UI for switch management | Script + process is enough |

### Concrete outputs (already in migration plan)

- `OC-EXT-CLOUD-MIGRATION-PLAN.md` §§ `v1 Focus`, `Operating Model`, `Architectural Position Alignment`, `Switch Workflow (v1 Sequence)`, `Version Compatibility & Deployment Discipline`, `State Handoff & Transfer Strategy`, `Conflict Handling`

### Phase 0 gate ✅
Operating model finalized: single active runtime, handoff-based transfer, deferred complexity list, v1 scope unambiguous.

---

## Phase 1 — Cloud Runtime Architecture Blueprint (Design Only)

**Status: ✅ COMPLETE (design captured in migration plan)**

### Purpose
Design the **minimum viable cloud runtime** needed to run our Docker image for OpenClaw reliably, before any migration logic is built.

### Agreed v1 architecture (from migration plan)

#### Compute / Runtime
- **EC2 t3.medium** (2 vCPU, 4 GB RAM) — Ubuntu 22.04 LTS
- Docker + Docker Compose for multi-service startup
- Restart policy: `restart: unless-stopped` (already in compose)

#### Persistent State Storage
- **EBS 50 GB GP3** volume — attached to EC2, mounted as `/home/ubuntu/openclaw-config` and `/home/ubuntu/task-manager-data`
- EBS data persists across EC2 stop/start (unlike instance store — critical distinction)
- State paths inside container: `~/.openclaw` → volume-mounted from EBS-backed host path

#### Backup / Transfer Transit
- **S3 bucket** (`openclaw-data-sync-{account-id}`) — used as handoff transit during switches + disaster-recovery snapshots
- Not a live shared filesystem; only written to during a switch or backup cron

```
s3://openclaw-data-sync-{account-id}/
├── openclaw-config/          ← current transfer state
├── task-manager-data/        ← current app data
└── backups/                  ← timestamped snapshots (retain last N)
    ├── 2026-02-21-100000/
    └── ...
```

#### Secrets
- **AWS Secrets Manager** for cloud runtime secrets
  - `openclaw/gateway-token` → `OPENCLAW_GATEWAY_TOKEN`
  - `openclaw/claude-ai` → `CLAUDE_AI_SESSION_KEY`
  - `openclaw/claude-web` → `CLAUDE_WEB_SESSION_KEY`, `CLAUDE_WEB_COOKIE`
  - `openclaw/twilio` → Twilio credentials (if applicable)
- Local `.env` managed manually — no sync automation with Secrets Manager

#### Networking
- **Security group ingress**: SSH (22), Gateway (18789), Task Manager (3847) — from your IP only
- **Elastic IP**: static IP for EC2 (free when attached to running instance)
- Outbound: unrestricted (for image pulls, GitHub, API calls)

#### Runtime Behavior
- Container image pulled from registry (Docker Hub / GitHub Container Registry / AWS ECR)
- **No build tools on EC2** — runtime only, not dev/build environment
- Auto-`git pull` at startup: **built apps** (`task-manager`, Next.js) use `SKIP_BUILD=true` — git pull is informational only, artifacts come from image
- Auto-`git pull`: acceptable for script/config-only repos with no build step

#### Image Tag Strategy
- `your-registry/openclaw:{YYYYMMDD}-{git-short-sha}` — image tag = code version for built apps
- Image tag recorded in every switch manifest
- No runtime code mutation for built artifacts

#### Logging / Health
- `docker logs openclaw-gateway` — baseline
- Health endpoint: `GET http://localhost:18789/health`
- CloudWatch Logs optional for persistent log retention (7-day retention, minimal cost)

### Persistent vs ephemeral boundary

| Layer | Persistent | Ephemeral |
|---|---|---|
| EBS volume | ✅ Survives stop/start/restart | — |
| Docker container filesystem | — | ✅ Lost on `docker rm` |
| EC2 instance store | — | ✅ Lost on stop/terminate |
| S3 bucket | ✅ Independent of EC2 lifecycle | — |

### Phase 1 gate ✅
Cloud architecture v1 designed and unambiguous. No open architectural questions for v1.

---

## Phase 2 — Infrastructure as Code (IaC) Authoring & Provisioning

**Status: 🔲 TODO — design captured; IaC implementation pending**

### Purpose
Codify the cloud runtime foundation so it is reproducible and safe to rebuild.

### What to implement (AWS CDK — TypeScript)

#### CDK project structure
```
openclaw-infra/
├── bin/
│   └── openclaw-infra.ts          ← CDK app entry point
├── lib/
│   ├── openclaw-stack.ts          ← Main stack
│   └── constructs/
│       ├── ec2-instance.ts        ← EC2 + security group
│       ├── s3-sync-bucket.ts      ← S3 for state handoff + backups
│       └── secrets.ts             ← Secrets Manager secrets
├── scripts/                       ← Switch scripts go here (Phase 6)
├── cdk.json
└── package.json
```

#### CDK stack components (all already designed in migration plan)

| Component | Spec | CDK Construct |
|---|---|---|
| EC2 instance | t3.medium, Ubuntu 22.04, 50 GB GP3 | `ec2.Instance` |
| EBS volume | 50 GB GP3, `/dev/sda1` | `ec2.BlockDeviceVolume.ebs(50, {volumeType: GP3})` |
| Security group | SSH/18789/3847 from `myIp` | `ec2.SecurityGroup` |
| IAM role | SecretsManager read + S3 read/write + SSM | `iam.Role` |
| S3 bucket | Versioned, backups → Glacier at 90d | `s3.Bucket` |
| Elastic IP | Static public IP | `ec2.CfnEIP` |
| Secrets Manager | 5 secrets, manual rotation | `secretsmanager.Secret` |
| CloudWatch Logs (optional) | `/openclaw/gateway`, 7-day retention | `logs.LogGroup` |

#### User data (first-boot provisioning)
Bootstraps the EC2 instance on first launch:
- Install Docker, Docker Compose, AWS CLI, git
- Create `/opt/openclaw` directory (for compose files and switch scripts)
- Create `/home/ubuntu/openclaw-config` and `/home/ubuntu/task-manager-data` dirs (EBS mount points)
- Pull Docker image from registry
- **Does NOT clone the full repo** — only copies `docker-compose.yml` and `oc-ext-*` files

#### IAM policy (minimal, no wildcards)
```
secretsmanager:GetSecretValue → arn:aws:secretsmanager:{region}:{account}:secret:openclaw/*
s3:GetObject, s3:PutObject, s3:ListBucket → arn:aws:s3:::openclaw-data-sync-{account}/*
AmazonSSMManagedInstanceCore (managed policy, for SSM access)
```

#### CDK outputs required (used by switch script in Phase 6)
- EC2 instance ID
- EC2 public IP (Elastic IP)
- S3 bucket name
- SSH command

#### Deployment commands
```bash
# Prerequisites
npm install -g aws-cdk
aws configure  # set Access Key, Secret, Region
cdk bootstrap aws://ACCOUNT-ID/us-east-1

# Create and deploy
mkdir openclaw-infra && cd openclaw-infra
cdk init app --language typescript
# ... implement openclaw-stack.ts (see migration plan for full CDK code)
cdk synth   # preview CloudFormation template
cdk deploy OpenClawStack --context myIp="YOUR_IP/32" --context keyPairName="openclaw-ec2-key"
```

#### Idempotency note
`cdk deploy` is re-runnable. Resources not in the stack are unaffected. EBS volume uses `RemovalPolicy.RETAIN` — never destroyed on `cdk destroy`.

### Phase 2 gate
You can **provision (and reprovision)** the cloud environment from code. Re-apply is predictable/idempotent. All infra outputs documented.

---

## Phase 3 — Cloud Runtime Bring-Up

**Status: 🔲 TODO — after Phase 2**

### Purpose
Prove that the cloud environment is not just provisioned, but **actually runs your containerized OpenClaw** correctly.

### Steps (from migration plan Phase 3–5 checklist)

#### 1. SSH to EC2 and install Docker
```bash
# EC2 user data may have already done this — verify:
docker --version
docker compose version

# If not, install manually:
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker ubuntu
```

#### 2. Pull Docker image from registry (NOT building on EC2)
```bash
# Build locally first:
docker build -t your-registry/openclaw:20260221-abc1234 -f OC-EXT-Dockerfile.local .
docker push your-registry/openclaw:20260221-abc1234

# On EC2:
docker pull your-registry/openclaw:20260221-abc1234
docker tag your-registry/openclaw:20260221-abc1234 openclaw:local-whisper
```

#### 3. Create minimal compose setup on EC2 (no full repo clone)
```bash
mkdir -p /opt/openclaw
# Copy only what's needed: docker-compose.yml, oc-ext-*.yml, oc-ext-*.sh
git clone --depth 1 https://github.com/your-org/openclaw.git /tmp/oc-temp
cp /tmp/oc-temp/docker-compose.yml /opt/openclaw/
cp /tmp/oc-temp/oc-ext-*.yml /opt/openclaw/
cp /tmp/oc-temp/oc-ext-*.sh /opt/openclaw/
rm -rf /tmp/oc-temp
```

#### 4. Create `.env` on EC2 (fetch from Secrets Manager)
```bash
cd /opt/openclaw
cat > .env <<EOF
OPENCLAW_CONFIG_DIR=/home/ubuntu/openclaw-config
OPENCLAW_WORKSPACE_DIR=/home/ubuntu/openclaw-config/workspace
OPENCLAW_IMAGE=openclaw:local-whisper
OPENCLAW_GATEWAY_TOKEN=$(aws secretsmanager get-secret-value --secret-id openclaw/gateway-token --query SecretString --output text)
CLAUDE_AI_SESSION_KEY=$(aws secretsmanager get-secret-value --secret-id openclaw/claude-ai --query SecretString --output text | jq -r .session_key)
EOF
chmod 600 .env
```

#### 5. Start services with test state (no real state yet)
```bash
cd /opt/openclaw
# Create empty state dirs for initial test
mkdir -p /home/ubuntu/openclaw-config /home/ubuntu/task-manager-data
sudo chown -R 1000:1000 /home/ubuntu/openclaw-config /home/ubuntu/task-manager-data

docker compose -f docker-compose.yml -f oc-ext-docker-compose.override.yml up -d
```

#### 6. Validate everything
```bash
# Check logs
docker logs openclaw-gateway
# Look for: "Starting task-manager...", "Gateway listening on 0.0.0.0:18789"

# Health check
curl http://localhost:18789/health  # on EC2
curl http://EC2_PUBLIC_IP:18789/health  # from local machine

# Task Manager UI
open http://EC2_PUBLIC_IP:3847

# Restart policy test
docker compose restart openclaw-gateway
docker logs openclaw-gateway  # should come back cleanly

# EBS persistence test
echo "test-marker-$(date)" > /home/ubuntu/openclaw-config/test-marker.txt
sudo reboot  # or: docker compose stop && docker compose up -d
cat /home/ubuntu/openclaw-config/test-marker.txt  # must still be there → EBS persisted
```

#### 7. Channels status
```bash
docker compose exec openclaw-gateway node dist/index.js channels status
```

### Key validations required

| Validation | Command | Expected |
|---|---|---|
| Gateway responds | `curl http://EC2_IP:18789/health` | 200 OK |
| Task Manager responds | `curl http://EC2_IP:3847` | 200 OK |
| EBS state persists | Write file → reboot → read file | File present |
| Restart policy works | `docker compose stop && up` | Comes back cleanly |
| Logs available | `docker logs openclaw-gateway` | No crash / fatal errors |

### Phase 3 gate
Cloud runtime is usable: custom image runs reliably, persistent storage survives restart/stop/start, bootstrap runbook documented.

---

## Phase 4 — State Inventory & Criticality Mapping

**Status: 🔲 TODO — after Phase 3 (can be done in parallel with Phase 3)**

### Purpose
Identify **exactly what state must move** to preserve continuity when switching runtimes.

### State inventory (from migration plan technical feasibility analysis)

#### Must transfer (continuity-critical)

| Path | Contents | Why Critical |
|---|---|---|
| `~/.openclaw/agents/{id}/sessions/` | Agent conversation history | Without this, agent forgets all conversations |
| `~/.openclaw/agents/{id}/user.md` | User profile + preferences | Agent personality context |
| `~/.openclaw/agents/{id}/soul.md` | Agent personality + instructions | Agent behavior |
| `~/.openclaw/agents/{id}/memory/*.sqlite` | SQLite semantic memory | Long-term memory / semantic search |
| `~/.openclaw/sessions/` | Active gateway session state | Conversation thread continuity |
| `~/.openclaw/channels/` | Message state, last IDs | Prevents duplicate message processing |
| `~/.openclaw/credentials/` | Provider credentials (Claude, WhatsApp) | Channel connectivity |
| `~/.openclaw/identity/device.json` | Ed25519 device keypair | Device pairing identity |
| `~/.openclaw/config.json` | Agent config, channel settings | Core configuration |
| `task-manager-data/tasks.csv` | Task list | App data continuity |

#### Exclude from transfer

| Path | Reason |
|---|---|
| `~/.openclaw/workspace/` | Transient working files; regenerated |
| `*.log`, `*.tmp` | Cache/temp; not needed |
| `*.lock` files | Stale locks from source must be **deleted** before transfer |
| Build artifacts in `/myapps/*/` | Come from image, not state |

#### Special-case files and their handling

| File / Path | Risk | Handling |
|---|---|---|
| `identity/device.json` | New file = new device identity, may need re-approval | Sync it — single active runtime means no conflict |
| `credentials/whatsapp/{id}/` | Session-bound but file-based | Sync entire dir; only one agent connects at a time |
| Signal CLI data | Outside `~/.openclaw/` if separate | Add to sync paths explicitly if using Signal |
| Config absolute paths | `/Users/abinmac/...` don't resolve on EC2 | Use `~`-relative paths; OpenClaw auto-normalizes via `src/config/normalize-paths.ts` |
| `*.lock` files | Source locks block destination startup | Delete with `find $CONFIG_DIR -name "*.lock" -delete` during transfer |

### State manifest spec (v1)

Every switch creates a manifest file alongside the snapshot:

```json
{
  "switched_at": "2026-02-21T10:00:00Z",
  "direction": "local-to-cloud",
  "source_runtime": "local",
  "destination_runtime": "cloud",
  "image_tag": "your-registry/openclaw:20260221-abc1234",
  "openclaw_version": "2026.2.15",
  "app_versions": {
    "task-manager": "git-sha-here"
  },
  "extension_versions": {},
  "state_file_count": 142,
  "state_paths_transferred": [
    "~/.openclaw/agents/",
    "~/.openclaw/sessions/",
    "~/.openclaw/channels/",
    "~/.openclaw/credentials/",
    "~/.openclaw/identity/",
    "~/.openclaw/config.json",
    "task-manager-data/"
  ],
  "snapshot_s3_path": "s3://openclaw-data-sync-xxx/backups/2026-02-21-100000/",
  "checksums": {
    "~/.openclaw/agents/": "sha256:...",
    "task-manager-data/tasks.csv": "sha256:..."
  }
}
```

### Phase 4 gate
State manifest spec exists. Include/exclude lists finalized. No ambiguity about continuity-critical state.

---

## Phase 5 — Switch Workflow Design (Runbook First, Then Code)

**Status: 🔲 TODO — after Phase 4**

### Purpose
Design the **exact handoff procedure** before automating it. Write the runbook in human-executable form first.

### v1 switch sequence (authoritative — from migration plan)

```
1. Preflight checks
   ├── Source runtime: confirm fully stopped (docker ps → no openclaw containers)
   ├── Destination: confirm not running
   ├── S3 connectivity: aws s3 ls s3://bucket/ → OK
   ├── Secrets availability: aws secretsmanager get-secret-value ... → OK
   ├── Destination disk space: df -h → sufficient
   ├── Image tag on destination matches manifest (version compatibility)
   └── No prior switch in-progress (no switch.lock file in S3)

2. Graceful stop + quiesce source
   ├── docker compose stop (source runtime)
   ├── Wait for clean shutdown (inspect docker ps — no containers running)
   └── Delete stale lock files:
       find $CONFIG_DIR -name "*.lock" -delete

3. Snapshot + manifest creation
   ├── Record: timestamp, direction, image_tag, app_versions, openclaw_version
   ├── Generate file count + checksums for critical state paths
   ├── Create timestamped backup in S3:
   │   aws s3 sync $CONFIG_DIR s3://bucket/backups/$TIMESTAMP/openclaw-config/
   │   aws s3 sync $TASK_DATA s3://bucket/backups/$TIMESTAMP/task-manager-data/
   └── Write manifest.json alongside snapshot in S3

4. Transfer state to destination (via S3)
   ├── aws s3 sync $CONFIG_DIR s3://bucket/openclaw-config/ --delete \
   │     --exclude "workspace/*" --exclude "*.log" --exclude "*.tmp" --exclude "*.lock"
   └── aws s3 sync $TASK_DATA s3://bucket/task-manager-data/ --delete

5. Verification
   ├── Destination: aws s3 sync s3://bucket/openclaw-config/ $DEST_CONFIG_DIR
   ├── Destination: aws s3 sync s3://bucket/task-manager-data/ $DEST_TASK_DATA
   ├── Check file counts match manifest
   ├── Verify checksums for critical files
   ├── Fix permissions: chown -R 1000:1000 $DEST_CONFIG_DIR $DEST_TASK_DATA
   └── ABORT if mismatch — destination stays stopped

6. Start destination runtime
   ├── Confirm image tag present: docker images | grep $IMAGE_TAG
   └── docker compose up -d

7. Health + smoke test
   ├── Wait for startup (poll health endpoint with retries)
   ├── curl http://localhost:18789/health → 200 OK
   ├── docker logs openclaw-gateway → no fatal errors
   ├── (Optional) Send test message via channel
   └── ABORT + rollback to previous snapshot if health check fails within timeout

8. Write active-runtime marker
   └── echo '{"active":"cloud","switched_at":"...","image_tag":"..."}' \
         > $CONFIG_DIR/active-runtime.json
       aws s3 cp $CONFIG_DIR/active-runtime.json s3://bucket/active-runtime.json

9. Rollback path (if step 7 fails)
   ├── Stop destination: docker compose stop
   ├── Identify previous snapshot: aws s3 ls s3://bucket/backups/
   ├── Restore from snapshot: aws s3 sync s3://bucket/backups/$PREV_TIMESTAMP/... $SOURCE_DIR
   └── Start source runtime back up (manual or scripted)
```

### Hard constraints (enforce in runbook and script)

| Constraint | Enforcement |
|---|---|
| Fail closed | Exit non-zero at any failure; do not continue |
| Both runtimes down during transfer | Verify source stopped before transfer begins |
| No manual bypass | Document that manual switches are not supported |
| No conflict merge | If unexpected destination changes detected → abort |
| No dual-active recovery mode | v1 does not handle "both accidentally ran" gracefully |

### Rollback decision tree

```
Switch failed at step...
├── Step 1-2 (preflight/stop): Source unchanged → restart source, investigate
├── Step 3 (snapshot): Transfer not started → source data safe, restart source
├── Step 4-5 (transfer/verify): Snapshot in S3 → fix transfer issue, retry or restore source
├── Step 6 (start dest): Snapshot in S3 → stop destination, restore source from snapshot
└── Step 7 (health check): Snapshot in S3 → stop destination, restore source from snapshot
```

### Phase 5 gate
Clear human-readable switch runbook. Rollback decision tree finalized. Stop/start/abort criteria explicit.

---

## Phase 6 — v1 Switch Script Implementation (Lean Automation)

**Status: 🔲 TODO — after Phase 5**

### Purpose
Automate the runbook so switching is repeatable, less error-prone, and auditable.

### Script structure (minimum viable)

```
scripts/
├── oc-ext-switch.sh             ← Main switch script (local ↔ cloud)
├── oc-ext-preflight.sh          ← Extracted preflight checks (reusable)
├── oc-ext-snapshot.sh           ← Snapshot + manifest creation
└── oc-ext-healthcheck.sh        ← Health/smoke test (reusable)
```

### What the switch script must do

```bash
#!/usr/bin/env bash
set -euo pipefail

# 1. Enforce single execution (lock)
LOCK_FILE="/tmp/oc-switch.lock"
[ -f "$LOCK_FILE" ] && { echo "Switch already in progress"; exit 1; }
trap 'rm -f "$LOCK_FILE"' EXIT
touch "$LOCK_FILE"

# 2. Preflight checks (all must pass or abort)
./oc-ext-preflight.sh "$DIRECTION" || exit 1

# 3. Stop + quiesce source
docker compose stop openclaw-gateway
find "$CONFIG_DIR" -name "*.lock" -delete

# 4. Snapshot + manifest
TIMESTAMP=$(date +%Y-%m-%d-%H%M%S)
./oc-ext-snapshot.sh "$TIMESTAMP" || exit 1

# 5. Transfer state via S3
aws s3 sync "$CONFIG_DIR" "s3://$BUCKET/openclaw-config/" --delete \
  --exclude "workspace/*" --exclude "*.log" --exclude "*.tmp" --exclude "*.lock"
aws s3 sync "$TASK_DATA" "s3://$BUCKET/task-manager-data/" --delete

# 6. Verify on destination (via SSH or local)
# ... file count + checksum check against manifest ...
[[ "$FILE_COUNT" == "$MANIFEST_COUNT" ]] || { echo "ABORT: file count mismatch"; exit 1; }

# 7. Start destination
# (on destination: pull from S3 → fix permissions → docker compose up -d)

# 8. Health check with retries
./oc-ext-healthcheck.sh "$DEST_HOST" || { echo "ABORT: health check failed"; exit 1; }

# 9. Write active-runtime marker
echo "{\"active\":\"$DEST\",\"switched_at\":\"$(date -u +%FT%TZ)\",\"image_tag\":\"$IMAGE_TAG\"}" \
  > "$CONFIG_DIR/active-runtime.json"

echo "Switch complete: $SOURCE → $DESTINATION"
```

### Key script properties

| Property | Implementation |
|---|---|
| Single execution | Lock file at `/tmp/oc-switch.lock` |
| Fail closed | `set -euo pipefail`; every check exits non-zero on failure |
| Auditable | All output logged to `oc-switch-$TIMESTAMP.log` |
| Rollback preserved | Snapshot in S3 before transfer begins |
| No conflict merge | Detect unexpected destination changes → abort |
| Simple tooling | bash + aws CLI + docker compose — no migration framework |

### Scripts to evolve from migration plan

The existing `sync-to-cloud.sh` / `sync-from-cloud.sh` / `sync-to-s3.sh` scripts (in the migration plan) are the starting point. Evolve them into the switch script by adding:
- Preflight checks (currently absent)
- Manifest creation (currently absent)
- Checksum verification (currently absent)
- Version compatibility check (currently absent)
- Health check gate (currently absent)
- Active-runtime marker write (currently absent)
- Lock file (currently absent)

### Phase 6 gate
Script performs end-to-end switch in a testable scenario. Failures abort safely without corrupting state. Logs make it possible to debug what happened.

---

## Phase 7 — Validation & Dry Runs

**Status: 🔲 TODO — after Phase 6**

### Purpose
Build confidence through repeated controlled tests before relying on the workflow operationally.

### Test matrix (minimum)

| Test Case | Direction | Expected Outcome |
|---|---|---|
| Happy path | local → cloud | Switch completes, health check passes, agent responds |
| Happy path | cloud → local | Switch completes, health check passes, agent responds |
| Repeated cycles | local → cloud → local (×3) | No state drift, no degradation |
| Checksum mismatch | local → cloud | Script aborts at step 5, source state intact |
| Missing secret | cloud → local | Preflight fails at step 1, nothing started |
| Health check failure | Any | Script aborts at step 7, destination stopped, source restorable from snapshot |
| Version incompatibility | Any | Preflight fails, destination not started |
| Interrupted transfer | Mid-transfer | Script detects mismatch at step 5, aborts, snapshot available |
| Both accidentally running | — | Detect via active-runtime marker, abort on next switch attempt |

### What to observe

- **State continuity**: agent remembers conversations from before the switch
- **No split-brain**: active-runtime marker correctly reflects which side is running
- **Correct abort behavior**: failures stop before corrupting state
- **Rollback viability**: previous snapshot restores cleanly
- **Repeatability**: not just one lucky run — test minimum 3 full cycles

### Session continuity validation

After each switch, verify:
```bash
# Check session files present with recent timestamps
ls -la ~/.openclaw/agents/*/sessions/
find ~/.openclaw -name "*.jsonl" -mtime -1

# Ask the agent a question that requires memory of a past conversation
# e.g., "What did we discuss yesterday about the project?"
```

### Phase 7 gate
Multiple successful dry runs in both directions. Failure cases abort safely. Rollback works from prior snapshot. Post-switch health/smoke tests consistently pass.

---

## Phase 8 — Controlled Production Adoption

**Status: 🔲 TODO — after Phase 7**

### Purpose
Use the switching workflow for real transitions under strict operational discipline.

### Operating policy (v1 — single operator)

| Policy | Rule |
|---|---|
| Who switches | Only you |
| How to switch | Only via `oc-ext-switch.sh` — no manual start/stop |
| Manual override | Not supported in v1 — treat as a procedure violation |
| Switch log | Record each switch: timestamp, versions, source→destination, outcome |
| Post-switch review | After each real use, review logs for anomalies |

### Troubleshooting separation (from migration plan)

When a switch fails, identify which layer failed before attempting a fix:

| Failure Type | Symptoms | First Action |
|---|---|---|
| **Infra/runtime issue** | EC2 unreachable, Docker not starting, disk full | Fix infra; don't touch state |
| **State-transfer issue** | Checksum mismatch, S3 access denied | Re-run transfer; source snapshot preserved |
| **App compatibility issue** | Health check fails after start, version mismatch | Roll back to previous snapshot; fix image first |

### Switch log format (suggested)

```
2026-02-21T10:00:00Z | local→cloud | image:20260221-abc1234 | COMPLETED | duration: 4m32s
2026-02-28T14:23:00Z | cloud→local | image:20260228-def5678 | COMPLETED | duration: 3m18s
2026-03-10T09:12:00Z | local→cloud | image:20260310-ghi9012 | ABORTED   | reason: health_check_timeout
```

### Phase 8 gate
Real local↔cloud transitions complete reliably. No unexpected state drift. Single-active-runtime invariant holds in practice. Process feels routine, not fragile.

---

## Phase 9 — Hardening (Only Based on Real Pain)

**Status: 🔲 FUTURE — only when real operational need is observed**

### Purpose
Add complexity **only when justified by observed issues in Phase 8**. Never preemptively.

### Candidate upgrades (defer until real pain appears)

| Candidate | Trigger to implement |
|---|---|
| Stronger startup guard (shared active-runtime lock in S3) | If active-runtime marker alone proves insufficient |
| Better observability / alerts (CloudWatch alarms) | If silent failures happen in production |
| Faster transfer optimization (parallel S3 sync, compression) | If transfer time becomes operationally painful |
| More robust rollback UX | If rollback from snapshot proves brittle |
| Version compatibility automation (version matrix checks) | If version mismatches recur |
| DB-backed architecture / fork decisions | Only if: concurrency pain, multi-agent need, file-system limits, or missing lifecycle controls appear |
| Multi-operator support / permissions | Only if: real second operator needs to switch |

### Constraints that must remain true through all hardening

| Constraint | Why it must stay |
|---|---|
| **Extension-only strategy** | Preserves upstream upgradability and future migration flexibility |
| **OpenClaw stays upstream** | No fork until forced by real, measurable friction |
| **Manthan / OpenClaw separation** | Conceptual boundary protects system evolution path |
| **Single-writer model** | Foundation of state correctness; don't erode this without DB-level concurrency control |
| **File-based state acceptable** | Until real concurrency / workflow pain justifies migration |

### Phase 9 gate
Each added safeguard solves a real observed failure mode. Architecture remains simple enough to operate solo. Future optionality is preserved.

---

## Summary of Phase Gates (Quick View)

| Phase | Gate Criterion | Status |
|---|---|---|
| **Phase 0** | Operating model finalized: single active runtime, handoff-based transfer, deferred complexity list | ✅ Complete |
| **Phase 1** | Cloud architecture v1 designed and unambiguous (EC2, EBS, S3, Secrets Manager, image tag strategy) | ✅ Complete |
| **Phase 2** | Infra can be provisioned reproducibly from IaC (CDK); outputs documented | 🔲 TODO |
| **Phase 3** | OpenClaw runs in cloud from your Docker image with persistent state path and restart behavior | 🔲 TODO |
| **Phase 4** | State inventory and manifest spec finalized; include/exclude lists unambiguous | 🔲 TODO |
| **Phase 5** | Switch runbook and rollback rules finalized in human-readable form | 🔲 TODO |
| **Phase 6** | Switch script works in test mode and fails closed | 🔲 TODO |
| **Phase 7** | Dry runs pass in both directions; failure injection handled safely; rollback verified | 🔲 TODO |
| **Phase 8** | Real switches succeed consistently under single-operator discipline | 🔲 TODO |
| **Phase 9** | Hardening only addresses real pain, without architectural overreach | 🔲 FUTURE |

---

## Why This Phase Order Works

**Foundation before migration** — never start state handoff automation before the runtime it targets is stable and understood.

```
Phase 0 (what)  → Phase 1 (design)  → Phase 2 (build infra)
→ Phase 3 (prove runtime)  → Phase 4 (map state)
→ Phase 5 (design switch)  → Phase 6 (automate switch)
→ Phase 7 (validate)  → Phase 8 (operate)  → Phase 9 (harden)
```

Each phase has a **binary gate** — complete means the gate criterion is met, not just that work was done. No phase starts until the previous gate passes.

The ordering follows the AWS "assess → mobilize → migrate" pattern adapted to a single-operator, file-based, extension-first architecture:
- **Assess** (Phases 0–1): establish constraints and architecture
- **Mobilize** (Phases 2–4): build infra, prove runtime, map state
- **Migrate** (Phases 5–7): design, automate, validate the handoff
- **Operate & Harden** (Phases 8–9): real use under discipline, then targeted hardening

---

*Related document: [`OC-EXT-CLOUD-MIGRATION-PLAN.md`](OC-EXT-CLOUD-MIGRATION-PLAN.md) — full migration plan with architecture diagrams, AWS CDK stack, state analysis, script templates, cost estimates, and troubleshooting reference.*
