# Building a Home Server: Architecture Guide

This is a write-up of a real, running home server — the topology, every technology
in it, why each piece was chosen, and the order to build it in if you're starting
from nothing.

Names and domains below are placeholders (`example.com`, `home.lan`, `node-a`,
`node-b`). Substitute your own.

---

## 1. The one-paragraph summary

Two second-hand machines at home run a **k3s** Kubernetes cluster joined over a
**Tailscale** VPN. One of them is also the *data host*: PostgreSQL, MongoDB, Redis
and MinIO run there as plain systemd services on bare metal, not in the cluster.
Public traffic arrives through **Cloudflare** → home router → **ingress-nginx** in
the cluster, with TLS certificates issued automatically by **cert-manager** from
Let's Encrypt. Apps are built into container images by **GitHub Actions**, pushed
to **GHCR**, and deployed by a single **generic Helm chart** that every app
configures with one small `deployment.yaml` in its own repo. Nightly **CronJobs**
back everything up to off-site object storage. **Uptime Kuma** watches the whole
thing from a separate box that is deliberately not part of the cluster.

Everything on the host side is reproduced by one idempotent bootstrap script, so
a wiped machine is ~20 minutes from rejoining.

---

## 2. Hardware and topology

| Role | Machine | What it runs |
| --- | --- | --- |
| `node-a` | Small x86 mini PC (Lenovo M720q class, ~€120 used) | k3s **server** (control plane), all four data services, split-DNS resolver |
| `node-b` | Raspberry Pi 5 | k3s **agent** (worker), plus the standalone monitoring stack outside the cluster |

Two nodes is the sweet spot. One node works fine and is where you should start.
The second buys you: a place to run monitoring that survives the first node dying,
a second architecture (arm64 alongside amd64) which forces your builds to stay
portable, and somewhere to drain workloads to.

**Storage:** a separate data volume mounted at `/mnt/data`, with a directory per
service (`/mnt/data/postgres`, `/mnt/data/mongo`, `/mnt/data/redis`,
`/mnt/data/minio`). The bootstrap deliberately does *not* manage the storage layer
— you mount the volume yourself via `/etc/fstab` before enabling any data service.
Mixing "provisions software" and "manages your disks" in one script is how people
lose data.

**OS:** Ubuntu Server LTS on both. Nothing in the design depends on it beyond
`apt` and `systemd`.

---

## 3. Networking — the part most guides get wrong

There are three separate networks in play, and keeping them separate is what makes
the whole thing manageable.

### 3.1 The private plane: Tailscale

Every node joins a **Tailscale** tailnet (WireGuard mesh with automatic NAT
traversal and key management). This gives you:

- **Stable private IPs** (`100.x.y.z`) that don't change when your ISP or router
  does, and **MagicDNS** names (`node-a.your-tailnet.ts.net`).
- **The k3s cluster join over the tailnet.** The agent points at the server's
  Tailscale IP, so the two nodes don't need to be on the same LAN — you could put
  one at a friend's house.
- **Tailscale SSH.** No `authorized_keys`, no password auth, no port 22 exposed
  anywhere. Access is granted in the Tailscale admin ACLs by identity, and revoked
  the same way.
- **CI access without exposing the API server.** GitHub Actions runners join the
  tailnet ephemerally with an OAuth client and a `tag:ci` tag, then talk to
  Kubernetes over it. The k3s API server is never reachable from the internet.

This one decision removes an entire category of problems: no VPN server to run,
no port forwards for admin access, no dynamic-DNS for SSH.

### 3.2 Public ingress: Cloudflare + one A record

Home internet has a dynamic public IP. The naive fix is a DDNS client updating
every hostname. The better pattern is an **anchor record**:

```
example.com          A      <public IP>   ← the ONE record DDNS updates
app.example.com      CNAME  example.com
api.example.com      CNAME  example.com
anything.example.com CNAME  example.com
```

A small systemd service + timer on each node fetches the current public IP,
compares it to the anchor's A record via the Cloudflare API, and updates it only
if changed. Every other hostname follows automatically via CNAME — you add new
subdomains in Cloudflare once and DDNS never touches them again.

Details worth copying:

- It runs on `network-online.target` (so boot and reconnect fire it immediately)
  **and** on a timer every 5 minutes as a backstop.
- **Both nodes run it.** It's idempotent — whichever loses the race just logs
  "unchanged". That's redundancy for free.
- The Cloudflare API token is scoped to *Zone → DNS → Edit* on that zone only.
- Worst-case staleness is the timer interval. If that bothers you, configure DDNS
  on the router itself (it fires on actual WAN-IP-change events) and let this be
  the backstop.

Then: forward ports 80 and 443 on the router to the k3s node running
ingress-nginx. That is the *only* inbound hole in the network.

### 3.3 Internal name resolution: split DNS

Cluster apps need to reach the databases, which live outside the cluster. You do
*not* want connection strings full of `100.x.y.z` literals — the day you move
Postgres to another box, you're rotating every app secret.

So: **dnsmasq** on the data host is authoritative for a private zone (`home.lan`),
serving a hand-edited hosts file:

```
100.x.y.z  postgres.home.lan  postgres
100.x.y.z  mongo.home.lan     mongo
100.x.y.z  redis.home.lan     redis
100.x.y.z  minio.home.lan     minio
```

Tailscale's admin console is told: *for the domain `home.lan`, use this
nameserver* (Split DNS → Custom nameserver, restricted to that domain). Now every
device on the tailnet resolves `postgres.home.lan` and nothing else changes.
Moving a service to a new host is one line edit plus `systemctl reload dnsmasq`.

Configuration notes that cost real time to discover:

- dnsmasq binds `interface=tailscale0` + `lo` with `bind-dynamic`, so it survives
  Tailscale restarting.
- `no-hosts`, `no-resolv`, `local=/home.lan/` — it is authoritative for that zone
  and nothing else; everything else falls through to Tailscale's resolver.
- `systemd-resolved` squats on port 53. You must set `DNSStubListener=no` and
  restart it, or dnsmasq won't bind.
- Skip resolvconf integration (`RESOLVCONF=no`); you don't want dnsmasq becoming
  the system resolver.

### 3.4 The two-layer indirection for data services

There's a second layer on top of split DNS. Inside Kubernetes, a `data` namespace
holds **ExternalName Services**:

```yaml
apiVersion: v1
kind: Service
metadata: { name: postgres, namespace: data }
spec:
  type: ExternalName
  externalName: postgres.home.lan
  ports: [{ port: 5432, targetPort: 5432 }]
```

Apps connect to `postgres.data.svc.cluster.local`. That resolves (via CoreDNS
forwarding to the host resolver) to `postgres.home.lan`, which resolves (via
dnsmasq) to a Tailscale IP. Two levels of indirection sounds excessive until you
swap a backend and change exactly one manifest instead of thirty secrets.

Caveat: `ExternalName` is a pure DNS CNAME. No port remapping, no load balancing,
no health checks. The app must still use the real port.

---

## 4. The host layer: one idempotent bootstrap script

Every host-level concern lives in a **single bash script** driven by a
`.env` file at `/etc/infrastructure/bootstrap/.env` (mode 0600, never committed).
You run it as:

```bash
curl -fsSL https://raw.githubusercontent.com/<you>/infrastructure/main/bootstrap/run.sh | sudo bash
```

Re-running it is always safe. It's organised in numbered phases, each gated by an
`INSTALL_*=1` toggle so the same script configures both a control-plane/data host
and a bare worker:

| Phase | What | Toggle |
| --- | --- | --- |
| 0 | base packages (`curl jq gnupg dnsutils`) | always |
| 1 | IP-forwarding sysctls (needed for exit nodes + k3s) | `INSTALL_SYSCTL_FORWARD` |
| 2 | Tailscale install + `tailscale up`/`set` reconcile | `INSTALL_TAILSCALE` |
| 3 | k3s (server or agent) | `INSTALL_K3S` |
| 4 | Cloudflare DDNS script + service + timer | `INSTALL_CF_DDNS` |
| 5 | daily k3s image/ReplicaSet GC timer | `INSTALL_K3S_CLEANUP` |
| 6 | MinIO (binary + systemd unit) | `INSTALL_MINIO` |
| 7 | PostgreSQL (PGDG apt repo, cluster relocated to `/mnt/data`) | `INSTALL_POSTGRES` |
| 8 | MongoDB (official apt repo) | `INSTALL_MONGO` |
| 9 | Redis (official apt repo, AOF persistence) | `INSTALL_REDIS` |
| 10 | dnsmasq split-DNS zone | `INSTALL_DNSMASQ` |

There's a matching `down.sh` that reverses each enabled phase in reverse order.
It **keeps data by default** — you have to pass `PURGE_DATA=1` to delete the data
directories, and `REMOVE_TAILSCALE=1` to leave the tailnet (removing Tailscale
would kill the SSH session you're running it from). Without `FORCE=1` it prompts,
and it refuses to run at all when piped with no TTY.

**Idempotency techniques worth stealing:**

- Third-party apt repo files are deleted at the top of the script and re-written
  by their own phase. A stale codename from an earlier run can otherwise break
  *every* `apt` operation, including the one at the start.
- Detect "installed" by the presence of the role-specific systemd unit, not by a
  binary on `$PATH` — that way a server↔agent role switch is noticed.
- Installed ≠ running. If the unit exists but is dead, start it.
- For Tailscale, if it's already up, run `tailscale set …` to reconcile prefs
  rather than skipping — so config changes in `.env` actually take effect.
- Downloads are checksum-verified before being moved into place.
- Never clobber a hand-edited file (the dnsmasq hosts file is written only if
  absent).

**A note on the data-services install:** PostgreSQL, MongoDB, Redis and MinIO are
installed **natively from their upstream apt repos / release binaries**, not in
containers and not in Kubernetes. This is a deliberate choice — see §6.

---

## 5. The cluster layer

### 5.1 k3s

**k3s** (Rancher's lightweight Kubernetes) rather than full kubeadm. Single binary,
single systemd unit, sane defaults, runs comfortably on a Pi.

Server config (`/etc/rancher/k3s/config.yaml`):

```yaml
write-kubeconfig-mode: "0644"
tls-san:
  - node-a
  - 100.x.y.z      # the Tailscale IP the agent and CI connect to
```

The `tls-san` entries matter: without the Tailscale IP in the API server
certificate, both the agent join and remote `kubectl` fail TLS verification.

Installed with `--disable=traefik`. k3s ships Traefik by default; it's replaced
with ingress-nginx below. Keep server and agent on the same minor version —
version skew across a k3s upgrade is a real source of weird failures.

### 5.2 Cluster add-ons

Installed once by an `init.sh`, both via their upstream Helm charts:

- **ingress-nginx** — the HTTP entry point. Everything public goes through it.
- **cert-manager** — automatic Let's Encrypt certificates.
- **Headlamp** (optional) — a web dashboard for the cluster, itself exposed
  through an Ingress.

A single `ClusterIssuer` handles certificates with two solvers:

- **HTTP-01** by default, solved through the nginx ingress class. Works for any
  hostname that resolves to your public IP.
- **DNS-01 via Cloudflare**, scoped by `dnsZones` to specific zones. Necessary
  because **wildcard certificates cannot be issued over HTTP-01**. If you ever
  want `*.example.com`, you need DNS-01 and a Cloudflare token in a secret in the
  cert-manager namespace.

### 5.3 Namespace-per-project

Each app gets its own namespace, created on demand by the deploy. Shared
infrastructure namespaces (`data`, `backups`, `infrastructure`) carry
`helm.sh/resource-policy: keep` so a `helm uninstall` can never take them out.
Pod Security Standards labels (`enforce: baseline`, `warn`/`audit: restricted`)
are applied at the namespace level.

RBAC is scoped tightly and per-purpose. Two examples of the pattern:

- A control-plane app that needs to inventory and rotate secrets across
  namespaces gets a `ClusterRole` limited to exactly
  `secrets`/`namespaces`/`pods`/`pods/log`/`deployments`/`jobs` with named verbs
  — not `cluster-admin`.
- An app offering self-serve custom domains gets a namespaced `Role` allowing
  only `ingresses` in its own namespace. cert-manager picks up the annotation and
  issues the cert, so the app needs no `Certificate` or `Secret` permissions at
  all.

Optional per-service **NetworkPolicies** are supported by the chart for anything
that should be locked down further.

---

## 6. Data: why the databases are *not* in Kubernetes

PostgreSQL, MongoDB, Redis and MinIO run as **systemd services on bare metal** on
the data host. This is the most contrarian decision here and the one that has paid
off most.

Reasons:

1. **Storage in a small k3s cluster is the hard part.** Stateful workloads want
   real persistent volumes; the honest options at home are local-path (which pins
   the pod to a node anyway — so you've gained nothing) or a distributed storage
   layer (Longhorn/Ceph — significant operational weight for two nodes).
2. **Upgrades and recovery are boring**, which is what you want from a database.
   `apt`, a systemd unit, a data directory. Debugging is `journalctl`.
3. **The cluster can be rebuilt from scratch without touching the data.** Wipe
   k3s, re-run bootstrap, redeploy every app — the databases never noticed.
4. The indirection in §3.4 means apps don't know or care where they live.

Layout: one directory per service under the data volume, each owned by its own
service user. One subtlety — the volume root needs `a+x` (search, not list) so
each service user can traverse into its own `0700` directory when the mountpoint
is owned by a different service.

**MinIO** deserves a specific mention: it's an S3-compatible object store, and
running one at home is a genuine unlock. Anything that would otherwise need S3 —
user uploads, generated assets, static files, a CDN origin — just works, with the
same SDKs. It's exposed through two Ingresses: one for the browser console, one
for the S3 API (used as a CDN origin, with CORS headers, a large
`proxy-body-size`, buffering off, and long proxy timeouts for big uploads). Both
point at ExternalName services aimed at the data host.

### The honest security caveat

All four data services bind on `0.0.0.0`. There is no LAN-only binding. What
protects them is (a) Tailscale ACLs, (b) the fact that only 80/443 are forwarded
at the router, and (c) a password on every service. **If you copy this, understand
that a host firewall is on you.** The safer variant is to bind each service to the
`tailscale0` address only.

---

## 7. Application delivery — the interesting bit

The design goal: **an app repo should contain its application code and one small
config file, and nothing else about infrastructure.** No Kubernetes manifests, no
Helm chart, no deploy scripts, no workflow logic. Adding an app should be
approximately free.

### 7.1 One generic Helm chart

There is exactly one Helm chart, versioned and published as an **OCI artifact to
GHCR** (`oci://ghcr.io/<you>/infrastructure`). It renders, from a list in values:

- a `Deployment` (rolling update, `maxUnavailable: 0`, `maxSurge: 1` — no
  downtime), with optional node selectors, security contexts, service accounts,
  volumes (secret/configMap/emptyDir/hostPath), resources, and all three probe
  types
- a `Service`
- an `Ingress` with cert-manager annotations, multi-host + www-redirect support
- optional `NetworkPolicy`
- `CronJob`s owned by the app
- pre-install/pre-upgrade `Job` hooks

Values are validated by a `values.schema.json`, so a malformed app config fails at
`helm upgrade` with a real message instead of rendering something broken.

Chart releases are automated: a push to `main` that changes the chart's
`Chart.yaml` version triggers a workflow that packages and pushes it to GHCR. Apps
pin a chart version, so bumping the chart doesn't silently change every app.

A tiny detail with outsized value: the pod template stamps a `build-timestamp`
label at render time, which guarantees a rollout happens even when the image tag
is unchanged.

### 7.2 The app-side contract

An app repo contains a `deployment.yaml` that is *both* the Helm values file and
the build manifest:

```yaml
version: 0.12.0          # chart version to deploy
project: my-app
namespace: my-app
services:
  - name: web
    image: ghcr.io/<you>/my-app
    context: .
    dockerfile: Dockerfile
    port: 3000
    replicas: 2
    env:
      - name: DATABASE_URL
        valueFrom: { secretKeyRef: { name: db-secrets, key: DATABASE_URL } }
    ingress:
      hosts: ["app.example.com"]
      path: /
      pathType: Prefix
      www: true
    readinessProbe:
      httpGet: { path: /healthz, port: 3000 }
```

That's the whole infrastructure surface of an app.

### 7.3 The pipeline

The app repo's own workflow does one thing: fire a **`repository_dispatch`** at the
infrastructure repo with a payload of `{repository, token, version, config_file,
migrations?}`. All the real logic lives in the infrastructure repo, in one workflow
with four jobs:

**1. `build` (matrix: amd64 on `ubuntu-latest`, arm64 on `ubuntu-24.04-arm`)**

Both architectures are built on **native runners, not QEMU**. This is not an
optimisation — native build tools (esbuild, the Astro compiler, Go toolchains)
*crash* under emulation, and cross-arch emulated builds are also 5–20× slower.
Each leg pushes an arch-suffixed tag and uses a GitHub Actions build cache scoped
per image+arch, with `mode=max` so BuildKit cache mounts are preserved (an
unchanged lockfile skips the whole dependency install).

Build args can be pulled from Kubernetes secrets at build time
(`valueFrom.secretKeyRef`), so build-time configuration never lands in the repo.

**2. `merge`** — stitches the two arch tags into one multi-arch manifest with
`docker buildx imagetools create`. Registry-only, no build, no emulation.

**3. `migrate` (conditional)** — if the dispatch payload contains a `migrations`
object, the SQL files are shipped into the cluster as a **ConfigMap** and applied
by a one-shot **Job in the app's namespace**, using the app's own `DATABASE_URL`
secret. Files run in filename order, each `--single-transaction` with
`ON_ERROR_STOP=1`; the first failure aborts the deploy. Migrations must be
idempotent, since they re-run on every deploy.

Running migrations from *inside* the cluster is the key move: the runner never
needs database credentials or network reachability to the database. It only needs
`kubectl`.

**4. `deploy`** — `helm upgrade --install` against the OCI chart, with
`--history-max=3`.

### 7.4 Deploy authorisation

Each project has a **JWT signed with a cluster-held secret**, with the project name
as the `sub` claim. The deploy script verifies the signature itself in bash
(HMAC-SHA256 via `openssl`, base64url handling and all) against a secret read from
the cluster — a runner can't deploy without cluster access *and* a valid token.

There's a second gate: the script calls an internal `/api/verify` endpoint to check
a per-project `enabled` flag in a registry table. It **fails closed only on an
explicit `enabled: false`**, and fails open on every other condition (endpoint
down, no `curl`, malformed response). That's the right default for a kill switch:
a transient outage in the control plane must never block deploys.

Private images pull via a `ghcr-pull` docker-registry secret that the deploy script
ensures (idempotently, via `kubectl apply`) in the target namespace.

### 7.5 Rollback

A manual-dispatch workflow takes a namespace and runs `helm rollback --wait` on
every release in it. With `--history-max=3` there's always a previous revision.
Recovery from a bad deploy is one button, not an archaeology session.

---

## 8. Scheduled work

Two kinds:

**Host-level**, as systemd timers — DDNS (5 min) and a daily k3s garbage collector
that removes containerd images not referenced by a running container and deletes
zero-replica ReplicaSets. On a small disk this is not optional; image sprawl will
fill a Pi's SD card.

**Cluster-level**, as Kubernetes `CronJob`s. The house style, worth adopting:

- Schedules use **odd minutes** (`17 3 * * *`, `23 5 * * *`) so unrelated jobs
  don't all stampede at `:00`.
- `concurrencyPolicy: Forbid`, small history limits, an `activeDeadlineSeconds`.
- The **"poke my own service"** pattern: the CronJob is a `curlimages/curl`
  container that POSTs an in-cluster endpoint with a bearer token from a secret,
  and the endpoint does the real work idempotently. The scheduler carries no
  business logic and needs no database access, and the job is trivially testable
  by calling the endpoint yourself.
- Apps declare their own crons in their `deployment.yaml` (the chart renders
  them), so schedules live with the code they belong to instead of accumulating as
  loose manifests.

---

## 9. Backups

A nightly `CronJob` in a `backups` namespace pushes everything **off-site to
Cloudflare R2** (S3-compatible, zero egress fees). One script, four steps:

1. `pg_dump --clean --if-exists --no-owner --no-privileges | gzip -9`, uploaded
   timestamped. `--clean --if-exists` means the dump can be replayed straight over
   a live database during a restore.
2. `mc mirror` of all MinIO buckets into R2 — **without** `--remove`, so a
   deletion at the source doesn't propagate and erase your only copy.
3. `mongodump --archive --gzip`, one archive per database, discovered by scanning
   for `MONGO_URI_*` environment variables — so adding a database to the backup is
   adding one env var.
4. Redis `--rdb` snapshots, explicitly **best-effort and non-fatal** (it's cache;
   a failure there must not fail the whole backup run).

The secrets it needs are copied into the backups namespace. The monitoring host's
own state (a SQLite volume) is folded into the same off-site backup with a
`tar` from a throwaway container.

**What matters here:** off-box and off-site. RAID is not a backup, a second
directory on the same disk is not a backup, and a backup you've never restored is
a hypothesis. Test a restore.

---

## 10. Monitoring — run it outside the thing it monitors

**Uptime Kuma** in plain Docker Compose on the *other* node, fronted by **Caddy**
for TLS. Not a Helm chart, not in the cluster, and that's the entire point:

> A monitor must not depend on the thing it monitors. If Kuma lived in the cluster,
> a cluster or node outage would take down the monitor with it, and no alert would
> ever be sent.

The independence is enforced in the details, and this is where people get it
subtly wrong:

- **The monitoring host does not use the split-DNS resolver.** That resolver lives
  on the other node. If the Pi resolved names through it, the monitor would depend
  on the server again. Internal checks target **Tailscale MagicDNS names**
  (`node-a.your-tailnet.ts.net:5432`), which resolve from the local netmap. If the
  data host dies you get a clean "connection refused" instead of a confusing DNS
  failure.
- **The dashboard's own hostname is a *public* Cloudflare A record pointing at the
  Pi's Tailscale IP.** A private IP in a public record is harmless; it resolves
  everywhere but is only reachable from inside the tailnet. No port forward, no
  public exposure, and it doesn't depend on internal DNS either.
- **TLS via DNS-01.** Caddy gets a real Let's Encrypt certificate through the
  Cloudflare API — no public reachability required. The official Caddy image ships
  no DNS providers, so it's rebuilt with `xcaddy build --with
  github.com/caddy-dns/cloudflare`. Builds on both arm64 and amd64.
- **Alerts must leave your network.** Telegram, ntfy, or an external SMTP relay —
  never a notification path that depends on your own infrastructure.

Monitors are grouped **Public** (HTTPS, expect 2xx/3xx, plus a keyword check on a
page or two to catch "200 but broken") and **Internal** (raw TCP port checks
against the databases). 60s interval, 2–3 retries before declaring down.

A simpler alternative if you want to skip Caddy and Cloudflare entirely:
`tailscale serve --bg https / http://localhost:3001` gives you a real certificate
on a `.ts.net` name with no config at all.

---

## 11. Security posture, stated honestly

What's genuinely good:

- **One inbound port pair** (80/443) on the router. Nothing else.
- **No SSH keys or passwords** — Tailscale SSH with identity-based ACLs.
- **The Kubernetes API is never public.** CI reaches it over an ephemeral tailnet
  join with a scoped tag.
- **Scoped API tokens everywhere.** Cloudflare tokens are Zone→DNS→Edit on one
  zone; RBAC is per-purpose, never `cluster-admin`.
- **Secrets never in git.** Host secrets in a `0600` env file; app secrets in
  Kubernetes; build-time secrets injected from the cluster at build time.
- **Signed deploy tokens** plus a registry kill switch.
- Pod Security Standards enforced at namespace level; optional NetworkPolicies.

What's a deliberate homelab trade-off you should know about before copying:

- The kubeconfig is written world-readable on the server (`0644`) for convenience.
  Tailscale SSH is what actually gates access to that host — the file mode isn't
  the real boundary, but on a multi-user machine it would need to be.
- Data services bind `0.0.0.0` with password auth (`scram-sha-256` for Postgres
  from any host). Tailscale ACLs and the absence of port forwards are the real
  perimeter. Add a host firewall, or bind to the Tailscale interface.
- Rotating a data-service password means editing the env file and re-running the
  bootstrap.

---

## 12. Gotchas that cost real time

- **Raspberry Pi 5 with a 16K-page kernel breaks Go binaries**, Tailscale included.
  Check `getconf PAGESIZE`; if it's `16384`, add `kernel=kernel8.img` to
  `/boot/firmware/config.txt` and reboot. Fully reversible.
- **`systemd-resolved` holds port 53.** dnsmasq can't bind until you set
  `DNSStubListener=no` and restart it.
- **A stale third-party apt repo file breaks every `apt` command**, including the
  one your bootstrap runs first. Delete repo files you own before the first
  `apt-get update`, and let each phase re-add its own. MongoDB in particular only
  publishes repos for LTS codenames, so you need an override to pin one.
- **`grep -q` in a pipeline under `set -o pipefail`** makes the upstream command
  fail with SIGPIPE (141), which looks like "not installed" and causes an infinite
  reinstall loop. Check for the systemd unit file instead of piping to `grep -q`.
- **QEMU cross-builds crash native toolchains.** Build each architecture on its own
  runner.
- **Wildcard certificates require DNS-01.** HTTP-01 cannot issue them, no matter
  how the ingress is configured.
- **k3s version skew** between server and agent across a minor version is a source
  of subtle failures. Bump both.
- **Image sprawl fills small disks.** Schedule the GC on day one, not after the
  first outage.

---

## 13. If you're starting from scratch

Don't build all of this at once. It accreted over a long time, and each layer
existed because the previous one hurt. Build in this order and stop wherever it's
enough for you:

**Stage 0 — one machine, no cluster.** A used mini PC, Ubuntu Server, Docker
Compose. Run one or two things. Learn what actually breaks. Most people should stay
here for months, and plenty should stay here forever.

**Stage 1 — remote access.** Install Tailscale, enable Tailscale SSH, close every
inbound port. This is the single highest-value hour in the whole list and it's
independent of everything else.

**Stage 2 — a domain and public ingress.** Buy a domain, put it on Cloudflare, set
up the anchor A record + DDNS timer, forward 80/443, and put a reverse proxy in
front of your containers. Caddy is the easy answer here — automatic TLS with no
configuration.

**Stage 3 — backups.** Before you add anything else. A nightly script that dumps
your databases and syncs your files to an off-site bucket (R2, B2 — both cheap).
Then actually restore one.

**Stage 4 — monitoring.** Uptime Kuma. If you have a second machine, put it there;
if not, put it on the same box but understand that it can't alert you about that
box being down and use an external heartbeat service as a backstop.

**Stage 5 — Kubernetes, only if you want it.** Be honest about why. Good reasons:
you're deploying many small services, you want zero-downtime rolling deploys and
declarative config, you want to learn it, or you want CI to deploy without
touching the host. Bad reason: it's what "real" infrastructure looks like. Compose
plus a reverse proxy handles a surprising amount.

If you do go there: k3s, `--disable=traefik`, ingress-nginx, cert-manager. Keep
your databases outside the cluster (§6). Get one app deployed by hand with `helm
upgrade` before you automate anything.

**Stage 6 — automate the deploy.** Only once you've done it by hand enough times to
know the steps. Write the generic chart, then the pipeline. The payoff is that app
number ten costs the same as app number two.

**Stage 7 — make the host reproducible.** The bootstrap script. Write it *after*
you've set the machine up manually, by transcribing what you actually did. Then
wipe the machine and prove it works.

---

## 14. Technology inventory

| Layer | Choice |
| --- | --- |
| OS | Ubuntu Server LTS |
| Private network | Tailscale (WireGuard), MagicDNS, Tailscale SSH, split DNS |
| Public DNS / edge | Cloudflare (DNS, proxy, API for DDNS + ACME DNS-01) |
| Dynamic DNS | Custom bash script, systemd service + timer, anchor-record pattern |
| Internal DNS | dnsmasq, authoritative for a private zone |
| Orchestration | k3s (server + agent) |
| Ingress | ingress-nginx |
| Certificates | cert-manager + Let's Encrypt (HTTP-01 default, Cloudflare DNS-01 for wildcards) |
| Cluster UI | Headlamp |
| Packaging | Helm — one generic chart, published as an OCI artifact to GHCR |
| Container registry | GHCR (private, pulled via a namespace `ghcr-pull` secret) |
| CI/CD | GitHub Actions — `repository_dispatch` fan-in, native multi-arch matrix, buildx + GHA cache |
| Relational DB | PostgreSQL (bare metal, PGDG apt repo) |
| Document DB | MongoDB (bare metal, official apt repo) |
| Cache | Redis (bare metal, AOF persistence) |
| Object storage / CDN origin | MinIO (bare metal, S3-compatible) |
| Off-site backup | Cloudflare R2 via `mc`, `pg_dump`, `mongodump`, nightly CronJob |
| Monitoring | Uptime Kuma + Caddy (Docker Compose, outside the cluster) |
| Host provisioning | One idempotent bash bootstrap + matching teardown |
| Secrets | Kubernetes Secrets; host `.env` at mode 0600; JWT deploy tokens |

---

## 15. The five ideas worth stealing

1. **One anchor A record, everything else a CNAME.** Dynamic DNS becomes a
   five-line script that touches exactly one record.
2. **Keep state out of the cluster.** Databases on bare metal, reached through two
   layers of DNS indirection. You can rebuild the cluster from zero on a Tuesday
   afternoon and lose nothing.
3. **One generic Helm chart; apps carry one config file.** The marginal cost of a
   new app drops to near zero, and infrastructure changes ship to everything at
   once.
4. **Monitor from outside.** Anything that can't observe its own failure isn't
   monitoring.
5. **Make the host reproducible with an idempotent script you can re-run at any
   time.** Not because you'll rebuild often — because it's the only documentation
   that can't drift from reality.
