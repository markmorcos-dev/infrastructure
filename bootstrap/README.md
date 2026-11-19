# infrastructure / bootstrap

Idempotent one-shot bootstrap for my Raspberry Pi 5 and Lenovo M720q nodes.

Sets up: IP forwarding sysctls, Tailscale, k3s (server or agent), multi-zone Cloudflare DDNS, k3s cleanup timer, and optionally the data-host services (MinIO, PostgreSQL, MongoDB, Redis) plus split-DNS via dnsmasq.

## Quick start

```bash
# 1. Pull secrets into place (host-local, never committed)
sudo install -d -m 0755 /etc/infrastructure
sudo nano /etc/infrastructure/bootstrap/.env       # paste & edit from .env.example
sudo chmod 0600 /etc/infrastructure/bootstrap/.env

# 2. Run bootstrap
curl -fsSL https://raw.githubusercontent.com/markmorcos/infrastructure/main/bootstrap/run.sh | sudo bash
```

Re-run any time — every step is idempotent.

## Teardown

`down.sh` reverses `run.sh`. It reads the same `.env` and the same `INSTALL_*`
toggles, then undoes each enabled phase in reverse order (services disabled,
unit files / scripts / apt repos / keyrings removed). Idempotent and safe to
re-run.

```bash
sudo FORCE=1 ./down.sh                       # tear down, KEEP all data
sudo FORCE=1 PURGE_DATA=1 ./down.sh          # also delete DB / MinIO data dirs
sudo FORCE=1 REMOVE_TAILSCALE=1 ./down.sh    # also leave the tailnet
```

Safety defaults:

- **Data is kept** unless `PURGE_DATA=1` (then `POSTGRES_DATA` / `MONGO_DATA` /
  `REDIS_DATA` / `MINIO_VOLUMES` are deleted).
- **Immich photos need an extra switch**: `PURGE_DATA=1` alone keeps
  `IMMICH_DATA`; it is only deleted with `PURGE_DATA=1 PURGE_IMMICH=1`.
- **Tailscale is left in place** unless `REMOVE_TAILSCALE=1` — removing it would
  drop a Tailscale-SSH session, so do that from a local console.
- **k3s** is removed via its official uninstall script, which also clears
  `/var/lib/rancher` (inherent to uninstalling, independent of `PURGE_DATA`).
- Base packages (curl, jq, gnupg, …) are intentionally left installed.
- Without `FORCE=1` the script prompts interactively, and refuses to run at all
  when piped (no TTY).

## Setting up the Pi (server)

```ini
# /etc/infrastructure/bootstrap/.env (Pi)
INSTALL_MINIO=1

TAILSCALE_AUTHKEY=tskey-auth-...
K3S_ROLE=server
CF_API_TOKEN=...

MINIO_ROOT_USER=minio-user
MINIO_ROOT_PASSWORD=...
MINIO_BROWSER_REDIRECT_URL=https://minio.morcos.tech
MINIO_SERVER_URL=https://cdn.morcos.tech
```

After Pi bootstrap, grab the token to use on the agent:

```bash
sudo cat /var/lib/rancher/k3s/server/node-token
```

## Setting up the M720q (agent)

```ini
# /etc/infrastructure/bootstrap/.env (M720q)
INSTALL_MINIO=0

TAILSCALE_AUTHKEY=tskey-auth-...
K3S_ROLE=agent
K3S_URL=https://100.69.211.117:6443       # Pi's Tailscale IP (matches tls-san)
K3S_TOKEN=K10b...                          # from Pi
CF_API_TOKEN=...                           # same token; both nodes update DNS for redundancy
```

## What gets installed

| Component | Path | Trigger |
| --- | --- | --- |
| sysctl IP forwarding | `/etc/sysctl.d/99-tailscale.conf` | `INSTALL_SYSCTL_FORWARD=1` |
| Tailscale | apt repo, then `tailscale up` | `INSTALL_TAILSCALE=1` |
| k3s | `/usr/local/bin/k3s` + systemd | `INSTALL_K3S=1` |
| DDNS script | `/usr/local/lib/infrastructure/cloudflare-ddns.sh` | `INSTALL_CF_DDNS=1` |
| DDNS service + timer | `/etc/systemd/system/cloudflare-ddns.{service,timer}` | `INSTALL_CF_DDNS=1` |
| k3s cleanup | `/usr/local/lib/infrastructure/k3s-cleanup.sh` + timer | `INSTALL_K3S_CLEANUP=1` |
| MinIO | `/usr/local/bin/minio` + unit + `/etc/default/minio` | `INSTALL_MINIO=1` |
| PostgreSQL | PGDG apt repo, cluster on `POSTGRES_DATA` (`/mnt/data/postgres`) | `INSTALL_POSTGRES=1` |
| MongoDB | mongodb-org apt repo, `/etc/mongod.conf`, data on `MONGO_DATA` | `INSTALL_MONGO=1` |
| Redis | packages.redis.io apt repo, `/etc/redis/infrastructure.conf`, data on `REDIS_DATA` | `INSTALL_REDIS=1` |
| dnsmasq | `/etc/dnsmasq.d/<domain>.conf` + `/etc/infrastructure/dnsmasq/<domain>.hosts` | `INSTALL_DNSMASQ=1` |
| Immich prerequisites | `IMMICH_DATA` (`/mnt/data/immich`) dirs; on a k3s server also the `immich` namespace + `immich-db` secret ([`immich.sh`](./immich.sh)) | `INSTALL_IMMICH=1` |

## Adding / removing domains

Edit [`domains.conf`](./domains.conf), commit, push. Next DDNS run (≤ `CF_DDNS_INTERVAL`, default 5 min) on each node picks it up. No bootstrap re-run needed.

Format:

```
zone.tld = record1 record2 *
```

Use `*` for wildcards, the zone name itself for the apex.

## DDNS behavior

- Runs on every `network-online.target` (boot + reconnect)
- Plus periodic timer every `CF_DDNS_INTERVAL` (default 5 min)
- Both nodes run it — idempotent, second one to update sees "unchanged"

Worst-case staleness: `CF_DDNS_INTERVAL`. To eliminate it entirely, configure DDNS at your router (e.g. Fritzbox → Internet → Permit Access → Dynamic DNS) — that fires on actual WAN IP change events. Combine with a CNAME-anchor pattern (one A record updated by router; everything else as CNAMEs) to keep this script trivial.

## Caveats

**Pi 5 with 16K-page kernel** breaks Tailscale's Go binary (and other Go programs). Check:

```bash
getconf PAGESIZE
```

If it returns `16384`, add `kernel=kernel8.img` to `/boot/firmware/config.txt` and reboot. Fully reversible — just remove the line and reboot again.

**Storage is your problem.** MinIO refuses to start if `/mnt/data` isn't mounted, and PostgreSQL/MongoDB/Redis all put their data under `/mnt/data` too. The bootstrap won't manage your storage layer — mount the data volume (via `/etc/fstab` or a one-off setup script) *before* enabling these toggles.

**Data services bind on all interfaces.** PostgreSQL, MongoDB, Redis and MinIO all listen on `0.0.0.0` and rely on Tailscale ACLs / a host firewall for protection — there is no LAN-only binding by default. Each requires a password in `.env`; rotating a password means editing `.env` and re-running the bootstrap.

**k3s version skew.** Server and agent should be on the same minor (1.32.x). Update `K3S_VERSION` on both nodes when you bump.

## Files in this repo

- `run.sh` — the bootstrap; idempotent, safe to re-run
- `down.sh` — reverses `run.sh`; idempotent. Keeps data unless `PURGE_DATA=1`
- `immich.sh` — Immich host prerequisites (Phase 11 of `run.sh`; also runnable alone)
- `.env.example` — copy + edit to `/etc/infrastructure/bootstrap/.env` on each host
- `domains.conf` — list of CF zones and records to keep pointed at home IP
- `README.md` — this file
