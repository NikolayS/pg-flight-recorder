#!/usr/bin/env bash
# provision_bench.sh — provision Hetzner VM for pg-flight-recorder benchmarks
# Security: firewall FIRST, PostgreSQL on localhost only, password auth, log_connections=on
# Idempotent: safe to re-run; tears down at end

set -euo pipefail

HCLOUD=${HCLOUD:-/usr/local/bin/hcloud}
SERVER_NAME="pgfr-bench"
SERVER_TYPE="cx22"
LOCATION="nbg1"
IMAGE="ubuntu-24.04"
FIREWALL_NAME="pgfr-bench-fw"
SSH_KEY_NAME="pgfr-bench-issue4"
SSH_KEY_FILE="/tmp/pgfr_bench_key"
PGFR_BRANCH="storage-overhaul-spec"

log() { echo "[$(date -u +%H:%M:%S)] $*"; }

# ── 0. Validate env ──────────────────────────────────────────────────────────
if [[ -z "${HCLOUD_TOKEN:-}" ]]; then
  echo "ERROR: HCLOUD_TOKEN not set" >&2
  exit 1
fi

# ── 1. Generate SSH key ──────────────────────────────────────────────────────
log "Generating SSH key: $SSH_KEY_FILE"
if [[ -f "$SSH_KEY_FILE" ]]; then
  log "SSH key already exists at $SSH_KEY_FILE"
else
  ssh-keygen -t ed25519 -f "$SSH_KEY_FILE" -N "" -C "$SSH_KEY_NAME"
fi

# ── 2. Upload SSH key to Hetzner (idempotent) ────────────────────────────────
log "Uploading SSH key to Hetzner as $SSH_KEY_NAME"
if $HCLOUD ssh-key describe "$SSH_KEY_NAME" &>/dev/null; then
  log "SSH key $SSH_KEY_NAME already exists"
else
  $HCLOUD ssh-key create --name "$SSH_KEY_NAME" --public-key-from-file "${SSH_KEY_FILE}.pub"
fi

# ── 3. Create firewall (SSH only) BEFORE server creation ────────────────────
log "Creating firewall: $FIREWALL_NAME (SSH port 22 only)"
if $HCLOUD firewall describe "$FIREWALL_NAME" &>/dev/null; then
  log "Firewall $FIREWALL_NAME already exists"
else
  $HCLOUD firewall create --name "$FIREWALL_NAME"
  $HCLOUD firewall add-rule "$FIREWALL_NAME" \
    --direction in \
    --protocol tcp \
    --port 22 \
    --source-ips 0.0.0.0/0 \
    --source-ips ::/0
  log "Firewall created with SSH-only inbound rule"
fi

# ── 4. Create server WITH firewall attached at boot ─────────────────────────
log "Creating server: $SERVER_NAME ($SERVER_TYPE, $LOCATION, $IMAGE)"
if $HCLOUD server describe "$SERVER_NAME" &>/dev/null; then
  log "Server $SERVER_NAME already exists"
else
  $HCLOUD server create \
    --name "$SERVER_NAME" \
    --type "$SERVER_TYPE" \
    --location "$LOCATION" \
    --image "$IMAGE" \
    --ssh-key "$SSH_KEY_NAME" \
    --firewall "$FIREWALL_NAME"
  log "Server created with firewall attached"
fi

# Get server IP
SERVER_IP=$($HCLOUD server describe "$SERVER_NAME" -o format='{{.PublicNet.IPv4.IP}}')
log "Server IP: $SERVER_IP"

# ── 5. Wait for SSH ──────────────────────────────────────────────────────────
log "Waiting for SSH to become available..."
for i in $(seq 1 30); do
  if ssh -i "$SSH_KEY_FILE" \
         -o StrictHostKeyChecking=no \
         -o ConnectTimeout=5 \
         -o BatchMode=yes \
         "root@$SERVER_IP" "echo ok" &>/dev/null; then
    log "SSH available"
    break
  fi
  sleep 10
done

# ── 6. Upload and run setup_pg.sh ────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
log "Copying setup scripts to server..."
scp -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no \
  "$SCRIPT_DIR/setup_pg.sh" \
  "root@$SERVER_IP:/root/setup_pg.sh"
ssh -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no "root@$SERVER_IP" \
  "chmod +x /root/setup_pg.sh && /root/setup_pg.sh 2>&1 | tee /root/setup_pg.log"

# ── 7. Run measurements ──────────────────────────────────────────────────────
log "Running §9.2 baseline measurements..."
scp -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no \
  "$SCRIPT_DIR/baseline_measure.sql" \
  "root@$SERVER_IP:/root/baseline_measure.sql"
ssh -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no "root@$SERVER_IP" \
  "sudo -u postgres psql -p 5433 -d pgfr_bench17 \
   --csv -f /root/baseline_measure.sql 2>&1 | tee /root/baseline_results.csv"

# Copy results back
scp -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no \
  "root@$SERVER_IP:/root/baseline_results.csv" \
  /tmp/baseline_results.csv
log "Results saved to /tmp/baseline_results.csv"

# ── 8. Teardown ──────────────────────────────────────────────────────────────
log "Tearing down Hetzner resources..."
$HCLOUD server delete "$SERVER_NAME" && log "Server deleted"
$HCLOUD ssh-key delete "$SSH_KEY_NAME" && log "SSH key deleted"
# Note: firewall kept for reuse; delete manually if not needed:
# $HCLOUD firewall delete "$FIREWALL_NAME"
log "Teardown complete"
