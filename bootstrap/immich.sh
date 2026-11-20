#!/usr/bin/env bash
#
# Host-side prerequisites for Immich (k8s/09-immich.yaml). Idempotent.
#   1. data dirs the pods mount via hostPath (library, postgres, model-cache)
#   2. on a k3s server: the `immich` namespace + the `immich-db` secret
#
# Called by run.sh (INSTALL_IMMICH=1) on the host that owns /mnt/data; also
# runnable on its own:  sudo IMMICH_DATA=/mnt/data/immich bash immich.sh
#
# The DB password is generated once and NEVER rotated here: Postgres bakes it
# into its data dir on first start, so changing the secret later would lock
# Immich out of its own database.

set -euo pipefail

IMMICH_DATA="${IMMICH_DATA:-/mnt/data/immich}"
IMMICH_NAMESPACE="${IMMICH_NAMESPACE:-immich}"
IMMICH_DB_PASSWORD="${IMMICH_DB_PASSWORD:-}"        # optional; generated if empty
IMMICH_KUBE_WAIT="${IMMICH_KUBE_WAIT:-120}"         # seconds to wait for the API
K3S_ROLE="${K3S_ROLE:-agent}"

log()  { printf '\033[1;34m[immich]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[immich]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[immich]\033[0m %s\n' "$*" >&2; exit 1; }

# --- 1. data dirs ----------------------------------------------------------
# Like MinIO/Postgres: refuse to write onto the root disk if the data volume
# isn't there (its parent dir is the mount point, e.g. /mnt/data).
PARENT="$(dirname "$IMMICH_DATA")"
[[ -d "$PARENT" ]] || die "$PARENT does not exist — mount the data volume first."

install -d -m 0755 "$IMMICH_DATA" "$IMMICH_DATA/library" "$IMMICH_DATA/model-cache"
# The postgres image chowns this to its own uid on first start; keep it private.
[[ -d "$IMMICH_DATA/postgres" ]] || install -d -m 0700 "$IMMICH_DATA/postgres"
log "Data dirs ready under $IMMICH_DATA"

# --- 2. namespace + secret (needs cluster-admin; only on the k3s server) ---
if [[ "$K3S_ROLE" != "server" ]]; then
  log "Not a k3s server (K3S_ROLE=$K3S_ROLE) — create the secret from a machine with kubectl:"
  log "  kubectl create ns $IMMICH_NAMESPACE"
  log "  kubectl -n $IMMICH_NAMESPACE create secret generic immich-db --from-literal=DB_PASSWORD=\"\$(openssl rand -hex 24)\""
  exit 0
fi

command -v kubectl >/dev/null 2>&1 || die "kubectl not found (k3s installs it) — is k3s installed?"

waited=0
until kubectl get --raw /readyz >/dev/null 2>&1; do
  (( waited >= IMMICH_KUBE_WAIT )) && die "Kubernetes API not ready after ${IMMICH_KUBE_WAIT}s."
  sleep 5; waited=$(( waited + 5 ))
done

if kubectl get namespace "$IMMICH_NAMESPACE" >/dev/null 2>&1; then
  log "Namespace $IMMICH_NAMESPACE exists"
else
  kubectl create namespace "$IMMICH_NAMESPACE" >/dev/null
  log "Created namespace $IMMICH_NAMESPACE"
fi

if kubectl -n "$IMMICH_NAMESPACE" get secret immich-db >/dev/null 2>&1; then
  log "Secret immich-db exists — keeping it (never rotated: Postgres is initialised with it)"
  [[ -n "$IMMICH_DB_PASSWORD" ]] && warn "IMMICH_DB_PASSWORD is set but ignored because the secret already exists."
  exit 0
fi

if [[ -n "$IMMICH_DB_PASSWORD" ]]; then
  # Immich's docs: only A-Za-z0-9 (it ends up in a connection URL).
  [[ "$IMMICH_DB_PASSWORD" =~ ^[A-Za-z0-9]{16,}$ ]] \
    || die "IMMICH_DB_PASSWORD must be at least 16 characters of A-Za-z0-9."
  PW="$IMMICH_DB_PASSWORD"
else
  PW="$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"
fi

kubectl -n "$IMMICH_NAMESPACE" create secret generic immich-db \
  --from-literal=DB_PASSWORD="$PW" >/dev/null
log "Created secret immich-db"
