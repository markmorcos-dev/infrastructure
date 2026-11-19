#!/usr/bin/env bash
#
# infrastructure node teardown — reverses bootstrap/run.sh
#
# Mirrors run.sh: reads the same /etc/infrastructure/bootstrap/.env and the same
# INSTALL_* toggles, then tears down each phase in REVERSE order. Each phase
# only undoes what its toggle enabled. Idempotent and safe to re-run.
#
# Usage:
#   sudo FORCE=1 ./down.sh                       # tear down, KEEP all data
#   sudo FORCE=1 PURGE_DATA=1 ./down.sh          # also delete DB/MinIO data dirs
#   sudo FORCE=1 REMOVE_TAILSCALE=1 ./down.sh    # also leave the tailnet (see warning)
#
# SAFETY:
#   * Database/MinIO DATA IS KEPT by default. Set PURGE_DATA=1 to delete it.
#   * Tailscale is LEFT IN PLACE by default — removing it would drop a
#     Tailscale-SSH session. Set REMOVE_TAILSCALE=1 to remove it (ideally from
#     a local console, not over SSH).
#   * k3s is removed via its official uninstall script, which also deletes
#     /var/lib/rancher regardless of PURGE_DATA (that's inherent to uninstalling).

set -uo pipefail   # NOT -e: a teardown must push past already-absent items

# === Constants ================================================================
CONFIG_FILE="${CONFIG_FILE:-/etc/infrastructure/bootstrap/.env}"

# === Logging ==================================================================
log()  { printf '\033[1;34m[teardown]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[teardown]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[teardown]\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root (sudo)."
command -v apt-get >/dev/null 2>&1 || die "This script targets Debian/Ubuntu."

# === Load config ==============================================================
if [[ -f "$CONFIG_FILE" ]]; then
  log "Loading $CONFIG_FILE"
  set -a; # shellcheck disable=SC1090
  source "$CONFIG_FILE"; set +a
fi

# Toggles (same defaults as run.sh, so a config-driven teardown matches install)
INSTALL_SYSCTL_FORWARD="${INSTALL_SYSCTL_FORWARD:-1}"
INSTALL_TAILSCALE="${INSTALL_TAILSCALE:-1}"
INSTALL_K3S="${INSTALL_K3S:-1}"
INSTALL_CF_DDNS="${INSTALL_CF_DDNS:-1}"
INSTALL_K3S_CLEANUP="${INSTALL_K3S_CLEANUP:-1}"
INSTALL_MINIO="${INSTALL_MINIO:-0}"
INSTALL_POSTGRES="${INSTALL_POSTGRES:-0}"
INSTALL_MONGO="${INSTALL_MONGO:-0}"
INSTALL_REDIS="${INSTALL_REDIS:-0}"
INSTALL_DNSMASQ="${INSTALL_DNSMASQ:-0}"
INSTALL_IMMICH="${INSTALL_IMMICH:-0}"

# Values we need to locate data dirs / units (mirror run.sh defaults)
POSTGRES_VERSION="${POSTGRES_VERSION:-16}"
POSTGRES_DATA="${POSTGRES_DATA:-/mnt/data/postgres}"
MONGO_DATA="${MONGO_DATA:-/mnt/data/mongo}"
REDIS_DATA="${REDIS_DATA:-/mnt/data/redis}"
IMMICH_DATA="${IMMICH_DATA:-/mnt/data/immich}"
MINIO_VOLUMES="${MINIO_VOLUMES:-/mnt/data/minio}"
DNSMASQ_DOMAIN="${DNSMASQ_DOMAIN:-morcos.lan}"

# Teardown-only switches
PURGE_DATA="${PURGE_DATA:-0}"
PURGE_IMMICH="${PURGE_IMMICH:-0}"                # photos: needs PURGE_DATA=1 too
REMOVE_TAILSCALE="${REMOVE_TAILSCALE:-0}"
FORCE="${FORCE:-0}"

# === Confirmation =============================================================
if [[ "$FORCE" != "1" ]]; then
  if [[ -t 0 ]]; then
    warn "About to tear down infrastructure components on $(hostname)."
    [[ "$PURGE_DATA"       == "1" ]] && warn "PURGE_DATA=1 — database/MinIO data WILL be deleted."
    [[ "$PURGE_DATA" == "1" && "$PURGE_IMMICH" == "1" ]] && warn "PURGE_IMMICH=1 — the Immich PHOTO LIBRARY WILL be deleted."
    [[ "$REMOVE_TAILSCALE" == "1" ]] && warn "REMOVE_TAILSCALE=1 — this may drop your SSH session."
    read -rp "Continue? [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || die "Aborted."
  else
    die "Refusing non-interactive teardown. Re-run with FORCE=1 to confirm."
  fi
fi

# === Helpers ==================================================================
stop_disable() { for u in "$@"; do systemctl disable --now "$u" >/dev/null 2>&1 || true; done; }
rm_f()         { rm -f  "$@" 2>/dev/null || true; }
rm_rf()        { rm -rf "$@" 2>/dev/null || true; }
purge()        { DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq "$@" >/dev/null 2>&1 || true; }

# === Reverse Phase 11: Immich ==================================================
# The namespace/secret go away with k3s (or: kubectl delete ns immich). The
# photo library is irreplaceable, so PURGE_DATA alone never touches it: it
# needs its own PURGE_IMMICH=1 on top.
if [[ "$INSTALL_IMMICH" == "1" ]]; then
  log "Removing Immich prerequisites..."
  if [[ "$PURGE_DATA" == "1" && "$PURGE_IMMICH" == "1" ]]; then
    rm_rf "$IMMICH_DATA"; warn "Deleted Immich data (photos + DB): $IMMICH_DATA"
  else
    log "Kept Immich photos + DB at $IMMICH_DATA (delete with PURGE_DATA=1 PURGE_IMMICH=1)"
  fi
fi

# === Reverse Phase 10: dnsmasq ================================================
if [[ "$INSTALL_DNSMASQ" == "1" ]]; then
  log "Removing dnsmasq..."
  stop_disable dnsmasq
  purge dnsmasq
  rm_f "/etc/dnsmasq.d/${DNSMASQ_DOMAIN}.conf"
  rm_rf /etc/infrastructure/dnsmasq
  warn "If this host was set as a Tailscale custom nameserver, remove it in the admin console."
  warn "run.sh disabled systemd-resolved's stub listener; re-enable manually if you need it:"
  warn "  sudo sed -i 's/^DNSStubListener=no/#DNSStubListener=/' /etc/systemd/resolved.conf && sudo systemctl restart systemd-resolved"
fi

# === Reverse Phase 9: Redis ===================================================
if [[ "$INSTALL_REDIS" == "1" ]]; then
  log "Removing Redis..."
  stop_disable redis-server
  purge redis redis-server redis-tools
  rm_f /etc/redis/infrastructure.conf
  rm_rf /etc/systemd/system/redis-server.service.d
  rm_f /etc/apt/sources.list.d/redis.list /etc/apt/keyrings/redis.gpg
  if [[ "$PURGE_DATA" == "1" ]]; then rm_rf "$REDIS_DATA"; warn "Deleted Redis data: $REDIS_DATA"; fi
fi

# === Reverse Phase 8: MongoDB =================================================
if [[ "$INSTALL_MONGO" == "1" ]]; then
  log "Removing MongoDB..."
  stop_disable mongod
  purge 'mongodb-org*' mongodb-mongosh
  rm_f /etc/mongod.conf
  rm_rf /etc/systemd/system/mongod.service.d
  rm_f /etc/apt/sources.list.d/mongodb-org-*.list
  rm_f /etc/apt/keyrings/mongodb-*.gpg
  if [[ "$PURGE_DATA" == "1" ]]; then rm_rf "$MONGO_DATA"; warn "Deleted MongoDB data: $MONGO_DATA"; fi
fi

# === Reverse Phase 7: PostgreSQL ==============================================
if [[ "$INSTALL_POSTGRES" == "1" ]]; then
  log "Removing PostgreSQL ${POSTGRES_VERSION}..."
  stop_disable "postgresql@${POSTGRES_VERSION}-main" postgresql
  purge "postgresql-${POSTGRES_VERSION}" "postgresql-client-${POSTGRES_VERSION}" postgresql-common postgresql-client-common
  rm_f /etc/apt/sources.list.d/pgdg.list /etc/apt/keyrings/pgdg.asc
  rm_rf "/etc/postgresql/${POSTGRES_VERSION}"
  if [[ "$PURGE_DATA" == "1" ]]; then rm_rf "$POSTGRES_DATA"; warn "Deleted PostgreSQL data: $POSTGRES_DATA"; fi
fi

# === Reverse Phase 6: MinIO ===================================================
if [[ "$INSTALL_MINIO" == "1" ]]; then
  log "Removing MinIO..."
  stop_disable minio
  rm_f /etc/systemd/system/minio.service
  rm_f /usr/local/bin/minio
  rm_f /etc/default/minio
  if [[ "$PURGE_DATA" == "1" ]]; then rm_rf "$MINIO_VOLUMES"; warn "Deleted MinIO data: $MINIO_VOLUMES"; fi
  getent passwd minio-user >/dev/null 2>&1 && userdel  minio-user 2>/dev/null || true
  getent group  minio-user >/dev/null 2>&1 && groupdel minio-user 2>/dev/null || true
fi

# === Reverse Phase 5: k3s cleanup =============================================
if [[ "$INSTALL_K3S_CLEANUP" == "1" ]]; then
  log "Removing k3s cleanup timer..."
  stop_disable k3s-cleanup.timer k3s-cleanup.service
  rm_f /etc/systemd/system/k3s-cleanup.timer /etc/systemd/system/k3s-cleanup.service
  rm_f /usr/local/lib/infrastructure/k3s-cleanup.sh
fi

# === Reverse Phase 4: Cloudflare DDNS =========================================
if [[ "$INSTALL_CF_DDNS" == "1" ]]; then
  log "Removing Cloudflare DDNS..."
  stop_disable cloudflare-ddns.timer cloudflare-ddns.service
  rm_f /etc/systemd/system/cloudflare-ddns.timer /etc/systemd/system/cloudflare-ddns.service
  rm_f /usr/local/lib/infrastructure/cloudflare-ddns.sh
  rm_f /etc/infrastructure/bootstrap/cloudflare-ddns.env
fi

systemctl daemon-reload 2>/dev/null || true

# === Reverse Phase 3: k3s =====================================================
if [[ "$INSTALL_K3S" == "1" ]]; then
  log "Removing k3s (via official uninstall script)..."
  if [[ -x /usr/local/bin/k3s-uninstall.sh ]]; then
    /usr/local/bin/k3s-uninstall.sh || true
  elif [[ -x /usr/local/bin/k3s-agent-uninstall.sh ]]; then
    /usr/local/bin/k3s-agent-uninstall.sh || true
  else
    warn "No k3s uninstall script found — k3s may already be gone."
  fi
  rm_rf /etc/rancher/k3s
fi

# === Reverse Phase 2: Tailscale (guarded) =====================================
if [[ "$INSTALL_TAILSCALE" == "1" && "$REMOVE_TAILSCALE" == "1" ]]; then
  warn "Removing Tailscale — if you are connected via Tailscale SSH this WILL drop your session."
  tailscale down   2>/dev/null || true
  tailscale logout 2>/dev/null || true
  purge tailscale
  rm_rf /var/lib/tailscale
elif [[ "$INSTALL_TAILSCALE" == "1" ]]; then
  log "Leaving Tailscale in place (set REMOVE_TAILSCALE=1 to remove it)."
fi

# === Reverse Phase 1: sysctl IP forwarding ====================================
if [[ "$INSTALL_SYSCTL_FORWARD" == "1" ]]; then
  log "Removing IP-forwarding sysctl..."
  rm_f /etc/sysctl.d/99-tailscale.conf
  sysctl -w net.ipv4.ip_forward=0          >/dev/null 2>&1 || true
  sysctl -w net.ipv6.conf.all.forwarding=0 >/dev/null 2>&1 || true
fi

# Note: Phase 0 base packages (curl, jq, gnupg, dnsutils, ca-certificates) are
# intentionally left installed — they're generally useful and widely depended on.

# === Done =====================================================================
systemctl daemon-reload 2>/dev/null || true
DEBIAN_FRONTEND=noninteractive apt-get autoremove -y -qq >/dev/null 2>&1 || true

log "Teardown complete."
[[ "$PURGE_DATA" == "1" ]] || log "Data dirs were KEPT (PURGE_DATA=0). Re-run with PURGE_DATA=1 to delete them."
