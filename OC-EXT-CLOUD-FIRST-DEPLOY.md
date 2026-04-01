# First Cloud Deployment — Quickest Working Path

> **Situation**: OpenClaw runs locally in Docker. Nothing exists in cloud yet.  
> **Goal**: Get it running on AWS EC2 — completely, correctly, first time.  
> **Approach**: Minimal steps only. No CDK, no Secrets Manager, no switch automation yet. Those come later.

---

## What You'll Need Before Starting

- AWS account with CLI configured (`aws configure`)
- Docker Hub account (free) — for hosting your image
- Your local `.env` file with all secrets
- Local OpenClaw running cleanly (`docker compose up -d` works)

**Estimated time**: 1–2 hours end to end.

---

## Step 1 — Build & Push Your Docker Image

This is the artifact that runs everywhere. Build once locally, pull anywhere.

```bash
# In your openclaw repo directory
cd /Users/abinmac/ai-stack/openclaw

# Tag with your Docker Hub username and a version
IMAGE=your-dockerhub-username/openclaw:cloud-v1

# Build
docker build -t $IMAGE -f OC-EXT-Dockerfile.local .

# Login to Docker Hub (once)
docker login

# Push
docker push $IMAGE
```

> **Why Docker Hub**: no setup needed, free for public images. Switch to AWS ECR later if needed.

---

## Step 2 — Launch EC2 Instance (AWS CLI)

No CDK overhead. One command to get an instance running.

### 2a. Find the Ubuntu 22.04 AMI for your region

```bash
# Get latest Ubuntu 22.04 LTS AMI ID (us-east-1 example — change region as needed)
aws ec2 describe-images \
  --owners 099720109477 \
  --filters "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" \
            "Name=state,Values=available" \
  --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
  --output text --region us-east-1
# → e.g. ami-0c7217cdde317cfec
```

### 2b. Create a key pair (if you don't have one)

```bash
aws ec2 create-key-pair \
  --key-name openclaw-ec2-key \
  --query 'KeyMaterial' \
  --output text > ~/.ssh/openclaw-ec2-key.pem

chmod 400 ~/.ssh/openclaw-ec2-key.pem
```

### 2c. Create a security group

```bash
MY_IP=$(curl -s https://checkip.amazonaws.com)

SG_ID=$(aws ec2 create-security-group \
  --group-name openclaw-sg \
  --description "OpenClaw EC2 security group" \
  --query 'GroupId' --output text)

# SSH (you only)
aws ec2 authorize-security-group-ingress \
  --group-id $SG_ID --protocol tcp --port 22 --cidr $MY_IP/32

# OpenClaw gateway (you only)
aws ec2 authorize-security-group-ingress \
  --group-id $SG_ID --protocol tcp --port 18789 --cidr $MY_IP/32

# Task Manager UI (you only)
aws ec2 authorize-security-group-ingress \
  --group-id $SG_ID --protocol tcp --port 3847 --cidr $MY_IP/32

echo "Security group: $SG_ID"
```

### 2d. Launch the instance

```bash
INSTANCE_ID=$(aws ec2 run-instances \
  --image-id ami-0c7217cdde317cfec \
  --instance-type t3.medium \
  --key-name openclaw-ec2-key \
  --security-group-ids $SG_ID \
  --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":30,"VolumeType":"gp3","DeleteOnTermination":false}}]' \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=openclaw}]' \
  --query 'Instances[0].InstanceId' --output text)

echo "Instance ID: $INSTANCE_ID"

# Wait until running
aws ec2 wait instance-running --instance-ids $INSTANCE_ID

# Get public IP
EC2_IP=$(aws ec2 describe-instances \
  --instance-ids $INSTANCE_ID \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text)

echo "EC2 IP: $EC2_IP"
```

> **Note**: `DeleteOnTermination=false` on the EBS volume means your data survives if you terminate the instance by accident.

---

## Step 3 — Provision the EC2 Instance

SSH in and install what's needed. EC2 only needs Docker — no build tools.

```bash
ssh -i ~/.ssh/openclaw-ec2-key.pem ubuntu@$EC2_IP
```

**On EC2:**

```bash
# Install Docker
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker ubuntu
newgrp docker  # apply group without logout

# Verify
docker --version
docker compose version

# Create directories for persistent state
mkdir -p ~/openclaw-config ~/task-manager-data
sudo chown -R 1000:1000 ~/openclaw-config ~/task-manager-data

# Create working directory for compose files
mkdir -p ~/openclaw
```

---

## Step 4 — Copy Your Config & Secrets to EC2

### 4a. Copy your `.env` file

```bash
# On LOCAL machine:
scp -i ~/.ssh/openclaw-ec2-key.pem \
  /Users/abinmac/ai-stack/openclaw/.env \
  ubuntu@$EC2_IP:~/openclaw/.env
```

Then SSH into EC2 and set permissions:

```bash
# On EC2:
chmod 600 ~/openclaw/.env

# Edit: update OPENCLAW_CONFIG_DIR and OPENCLAW_IMAGE to match EC2 paths/image
nano ~/openclaw/.env
```

Make sure `.env` on EC2 has:
```bash
OPENCLAW_CONFIG_DIR=/home/ubuntu/openclaw-config
OPENCLAW_WORKSPACE_DIR=/home/ubuntu/openclaw-config/workspace
OPENCLAW_IMAGE=your-dockerhub-username/openclaw:cloud-v1
```

### 4b. Copy your local OpenClaw config (first time — brings credentials, channels, agent memory)

```bash
# On LOCAL machine — stop local agent first for a clean copy:
docker compose stop openclaw-gateway

# Copy your entire ~/.openclaw config to EC2
rsync -avz --exclude "workspace/" --exclude "*.log" --exclude "*.tmp" --exclude "*.lock" \
  ~/.openclaw/ ubuntu@$EC2_IP:~/openclaw-config/

# Optional: copy task manager data if you have existing tasks
rsync -avz \
  ~/.openclaw/task-manager-data/ ubuntu@$EC2_IP:~/task-manager-data/
  # (adjust the source path to wherever your task-manager-data actually lives)
```

Then fix ownership on EC2:

```bash
# On EC2:
sudo chown -R 1000:1000 ~/openclaw-config ~/task-manager-data
# Clean any stale lock files from the local machine
find ~/openclaw-config -name "*.lock" -delete
```

> **Fresh start alternative**: if you'd rather configure OpenClaw fresh on EC2 (re-add channels manually), skip step 4b entirely. OpenClaw will create a new config on first run.

---

## Step 5 — Create the Compose File on EC2

```bash
# On EC2:
cat > ~/openclaw/docker-compose.cloud.yml << 'EOF'
services:
  openclaw-gateway:
    image: ${OPENCLAW_IMAGE}
    restart: unless-stopped
    ports:
      - "18789:18789"
      - "3847:3847"
    volumes:
      - ${OPENCLAW_CONFIG_DIR}:/home/node/.openclaw
      - ${OPENCLAW_CONFIG_DIR}/task-manager-data:/myapps/task-manager/data
    env_file:
      - .env
    environment:
      - SKIP_BUILD=true
EOF
```

---

## Step 6 — Pull Image & Start

```bash
# On EC2:
cd ~/openclaw

# Pull your image
docker pull your-dockerhub-username/openclaw:cloud-v1

# Start
docker compose -f docker-compose.cloud.yml --env-file .env up -d

# Watch logs
docker logs -f openclaw-gateway
```

**Expected log output:**
```
Pulling /myapps/task-manager...
Starting task-manager...
Gateway listening on 0.0.0.0:18789
```

---

## Step 7 — Verify It's Working

```bash
# On EC2:
curl http://localhost:18789/health

# From your local machine:
curl http://$EC2_IP:18789/health

# Open Task Manager in browser:
open http://$EC2_IP:3847

# Check channel status
docker compose -f docker-compose.cloud.yml exec openclaw-gateway \
  node dist/index.js channels status
```

Send a test message via your configured channel (Telegram / Discord / etc.) and confirm the cloud agent responds.

---

## Step 8 — (Optional but Recommended) Assign a Static IP

Without an Elastic IP, the EC2 IP changes every time you stop/start the instance.

```bash
# Allocate
EIP_ALLOC=$(aws ec2 allocate-address --query 'AllocationId' --output text)

# Attach to your instance
aws ec2 associate-address \
  --instance-id $INSTANCE_ID \
  --allocation-id $EIP_ALLOC

# Get your new static IP
aws ec2 describe-addresses \
  --allocation-ids $EIP_ALLOC \
  --query 'Addresses[0].PublicIp' --output text
```

Update your security group IP whitelist if your local IP changes in the future:
```bash
MY_IP=$(curl -s https://checkip.amazonaws.com)
aws ec2 authorize-security-group-ingress \
  --group-id $SG_ID --protocol tcp --port 18789 --cidr $MY_IP/32
```

---

## What You Have After These Steps

| Component | What's Running |
|---|---|
| EC2 t3.medium | Ubuntu 22.04, Docker installed |
| EBS 30 GB GP3 | Persistent — survives instance stop/start |
| OpenClaw Gateway | Port 18789 |
| Task Manager | Port 3847 |
| Image | `your-dockerhub-username/openclaw:cloud-v1` on Docker Hub |
| Config | Copied from local `~/.openclaw/` |
| Restart policy | `unless-stopped` — survives reboots |

---

## Day-to-Day Operations

### Stop the agent (save costs when not needed)
```bash
# On EC2:
docker compose -f ~/openclaw/docker-compose.cloud.yml stop

# Stop the EC2 instance itself (EBS data preserved):
aws ec2 stop-instances --instance-ids $INSTANCE_ID
```

### Restart
```bash
aws ec2 start-instances --instance-ids $INSTANCE_ID
# Wait ~30s, then:
ssh -i ~/.ssh/openclaw-ec2-key.pem ubuntu@$EC2_IP
cd ~/openclaw && docker compose -f docker-compose.cloud.yml up -d
```

### Update code (no Dockerfile change)
```bash
# Push to GitHub → SSH to EC2 → restart container
# oc-ext-entrypoint.sh will git pull at startup (SKIP_BUILD=true on cloud)
docker compose -f docker-compose.cloud.yml restart openclaw-gateway
```

### Update image (Dockerfile or new app)
```bash
# On LOCAL machine:
docker build -t your-dockerhub-username/openclaw:cloud-v2 -f OC-EXT-Dockerfile.local .
docker push your-dockerhub-username/openclaw:cloud-v2

# On EC2: update .env → OPENCLAW_IMAGE=...cloud-v2 → pull → restart
docker pull your-dockerhub-username/openclaw:cloud-v2
docker compose -f docker-compose.cloud.yml up -d
```

---

## Record These Values (You'll Need Them)

```
Instance ID:      i-xxxxxxxxxxxx
Elastic IP:       x.x.x.x
Security Group:   sg-xxxxxxxxxxxx
EBS Volume ID:    vol-xxxxxxxxxxxx  (find in console or aws ec2 describe-volumes)
Image:            your-dockerhub-username/openclaw:cloud-v1
Key pair:         ~/.ssh/openclaw-ec2-key.pem
Compose file:     ~/openclaw/docker-compose.cloud.yml  (on EC2)
Config dir:       /home/ubuntu/openclaw-config  (on EC2)
```

---

## What This Is NOT (Save for Later)

| Not included | When to add |
|---|---|
| AWS CDK / IaC | Phase 2 — after manual setup is proven working |
| AWS Secrets Manager | When you're tired of managing `.env` manually |
| Switch script / handoff automation | Phase 5–6 — when you start switching local ↔ cloud regularly |
| S3 snapshots / backup cron | Phase 6+ — after the switch workflow is built |
| CloudWatch logs | When you need persistent log history |

---

## Transition to CDK (After Manual Setup Works)

Once OpenClaw is running reliably via manual setup, codify the same infra in CDK, destroy the manual resources, and redeploy. This is Phase 2 in the migration phases.

### The CDK stack must match exactly what you built manually

| What you built manually | CDK equivalent |
|---|---|
| EC2 t3.medium, Ubuntu 22.04 | `ec2.Instance` with `InstanceType.of(T3, MEDIUM)` + `MachineImage.lookup(...)` |
| EBS 30 GB GP3, `DeleteOnTermination=false` | `ec2.BlockDeviceVolume.ebs(30, {volumeType: GP3, deleteOnTermination: false})` |
| Security group (SSH/18789/3847 from your IP) | `ec2.SecurityGroup` + `addIngressRule` |
| Key pair `openclaw-ec2-key` | `ec2.Instance.keyName` |
| Elastic IP | `ec2.CfnEIP` |
| IAM instance profile | `iam.Role` (add S3 + Secrets Manager permissions when you add those) |

### Transition sequence (preserves your state)

**Step 1 — Save your state locally before destroying anything**
```bash
# On EC2: stop the container
docker compose -f ~/openclaw/docker-compose.cloud.yml stop

# On LOCAL machine: pull state from EC2 as a local backup
rsync -avz ubuntu@$EC2_IP:~/openclaw-config/ /tmp/openclaw-cloud-backup/
rsync -avz ubuntu@$EC2_IP:~/task-manager-data/ /tmp/openclaw-cloud-backup/task-manager-data/
```

**Step 2 — Write and deploy the CDK stack**
```bash
mkdir openclaw-infra && cd openclaw-infra
cdk init app --language typescript
# ... implement the stack matching the manual setup above ...
cdk synth    # review the CloudFormation template first
cdk deploy OpenClawStack --context myIp="$(curl -s https://checkip.amazonaws.com)/32"
```

CDK will create a new EC2 instance and a new EBS volume. Note the new instance ID and IP from CDK outputs.

**Step 3 — Provision the new CDK instance**

SSH into the new EC2 instance and repeat Steps 3–6 from this doc (Docker install, dirs, `.env`, compose file, pull image, start).

**Step 4 — Restore your state onto the CDK instance**
```bash
# Copy your saved state to the new CDK instance
rsync -avz /tmp/openclaw-cloud-backup/ ubuntu@$NEW_EC2_IP:~/openclaw-config/
rsync -avz /tmp/openclaw-cloud-backup/task-manager-data/ ubuntu@$NEW_EC2_IP:~/task-manager-data/

# Fix ownership
ssh ubuntu@$NEW_EC2_IP "sudo chown -R 1000:1000 ~/openclaw-config ~/task-manager-data"
```

**Step 5 — Verify the CDK instance is healthy**
```bash
curl http://$NEW_EC2_IP:18789/health
# Send a test message — agent should remember prior state
```

**Step 6 — Destroy the manual resources (only after CDK instance is verified)**
```bash
# Terminate the old EC2 instance
aws ec2 terminate-instances --instance-ids $OLD_INSTANCE_ID

# Release the old Elastic IP (if you're not reusing it)
aws ec2 release-address --allocation-id $OLD_EIP_ALLOC

# Delete the old security group (after instance is fully terminated)
aws ec2 delete-security-group --group-id $OLD_SG_ID

# The old EBS volume (DeleteOnTermination=false) will persist — delete it explicitly
# Check first: aws ec2 describe-volumes --filters "Name=attachment.instance-id,Values=$OLD_INSTANCE_ID"
aws ec2 delete-volume --volume-id $OLD_VOLUME_ID
```

> **Order matters**: terminate instance first, then release Elastic IP and security group. A security group with active associations cannot be deleted.

### What stays the same after CDK transition

- Same image: `your-dockerhub-username/openclaw:cloud-v1`
- Same compose file: `~/openclaw/docker-compose.cloud.yml`
- Same state directories: `~/openclaw-config`, `~/task-manager-data`
- Same `.env` file (copy it to the new instance)
- Assign the Elastic IP to the new instance if you want the same IP

---

*Phases reference: [`OC-EXT-CLOUD-MIGRATION-PHASES.md`](OC-EXT-CLOUD-MIGRATION-PHASES.md)*  
*Full architecture reference: [`OC-EXT-CLOUD-MIGRATION-PLAN.md`](OC-EXT-CLOUD-MIGRATION-PLAN.md)*
