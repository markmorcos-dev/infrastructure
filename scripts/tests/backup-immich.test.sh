#!/usr/bin/env bash
# Tests for the Immich part of the nightly R2 backup (k8s/05-backups.yaml).
#   unit:        each rule on the CronJob/script in isolation
#   integration: backup.sh (taken from the ConfigMap) runs end to end against
#                fake mc / pg_dump / mongodump / redis-cli and a fake Immich
#                library, and reads the same dir Immich writes to
# Run: bash scripts/tests/backup-immich.test.sh   (needs python3 + PyYAML, jq)
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BACKUP="$ROOT/k8s/05-backups.yaml"
IMMICH="$ROOT/k8s/09-immich.yaml"
PASS=0
FAIL=0

to_json() {
  python3 -c 'import json, sys, yaml
print(json.dumps([d for d in yaml.safe_load_all(open(sys.argv[1])) if d]))' "$1"
}
B=$(to_json "$BACKUP") || { echo "cannot parse $BACKUP"; exit 1; }
I=$(to_json "$IMMICH") || { echo "cannot parse $IMMICH"; exit 1; }
pod='.[] | select(.kind=="CronJob" and .metadata.name=="offsite-backup") | .spec.jobTemplate.spec.template.spec'
SCRIPT_TEXT=$(jq -r '.[] | select(.kind=="ConfigMap" and .metadata.name=="backup-script") | .data["backup.sh"]' <<<"$B")

check() { # name, then a command that must succeed
  local name=$1; shift
  if "$@"; then PASS=$((PASS + 1)); echo "ok   $name"
  else FAIL=$((FAIL + 1)); echo "FAIL $name"; [ -n "${OUT:-}" ] && echo "$OUT" | sed 's/^/     | /'; fi
}

echo "# unit: CronJob"
check "pinned to m720q (the disk + the amd64 mc build)" \
  test "$(jq -r "$pod | .nodeSelector[\"kubernetes.io/hostname\"]" <<<"$B")" = m720q
check "immich library mounted read-only at /immich" \
  test "$(jq -r "$pod | .containers[0].volumeMounts[] | select(.name==\"immich\") | \"\(.mountPath) \(.readOnly)\"" <<<"$B")" = "/immich true"
check "hostPath must already exist (type Directory, never created empty)" \
  test "$(jq -r "$pod | .volumes[] | select(.name==\"immich\") | .hostPath.type" <<<"$B")" = Directory

echo "# unit: backup.sh"
check "never mirrors with --remove (deletions stay in R2)" \
  bash -c 'grep -v "^[[:space:]]*#" <<<"$1" | grep -q " mirror " && ! grep -v "^[[:space:]]*#" <<<"$1" | grep " mirror " | grep -q -- "--remove"' _ "$SCRIPT_TEXT"
bad=$(sed 's/mirror --overwrite "\$IMMICH_SRC/mirror --overwrite --remove "$IMMICH_SRC/' <<<"$SCRIPT_TEXT")
check "  (and a --remove would be caught)" \
  bash -c 'grep -v "^[[:space:]]*#" <<<"$1" | grep " mirror " | grep -q -- "--remove"' _ "$bad"
check "immich step runs after every database step" bash -c '
  s=$1; i=$(grep -n "immich mirror" <<<"$s" | head -1 | cut -d: -f1)
  for k in pg_dump "mirror --overwrite \"src\"" mongodump redis-cli; do
    n=$(grep -nF -- "$k" <<<"$s" | tail -1 | cut -d: -f1); [ "$n" -lt "$i" ] || exit 1
  done' _ "$SCRIPT_TEXT"
check "no hard-coded /tmp/mc left (all calls go through \$MC)" \
  bash -c '[ "$(grep -c "/tmp/mc" <<<"$1")" -eq 1 ]' _ "$SCRIPT_TEXT"

echo "# integration: same directory as Immich"
srv_lib=$(jq -r '.[] | select(.kind=="Deployment" and .metadata.name=="immich-server")
  | .spec.template.spec as $p | ($p.containers[0].volumeMounts[] | select(.mountPath=="/data") | .name) as $v
  | $p.volumes[] | select(.name==$v) | .hostPath.path' <<<"$I")
bk_lib=$(jq -r "$pod | .volumes[] | select(.name==\"immich\") | .hostPath.path" <<<"$B")
check "backup reads the dir immich-server writes (/data -> $srv_lib)" test -n "$srv_lib" -a "$srv_lib" = "$bk_lib"
check "both pinned to the same node" test "$(jq -r '.[] | select(.metadata.name=="immich-server" and .kind=="Deployment") | .spec.template.spec.nodeSelector["kubernetes.io/hostname"]' <<<"$I")" = m720q

echo "# integration: backup.sh end to end"
setup() {
  WORK=$(mktemp -d); mkdir -p "$WORK/bin" "$WORK/state"
  printf '%s\n' "$SCRIPT_TEXT" > "$WORK/backup.sh"
  for t in wget apk; do printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/$t"; done
  printf '#!/bin/sh\necho "-- dump"\n' > "$WORK/bin/pg_dump"
  printf '#!/bin/sh\necho mongo-archive\n' > "$WORK/bin/mongodump"
  printf '#!/bin/sh\nexit 1\n' > "$WORK/bin/redis-cli"           # cache: skipped
  cat > "$WORK/bin/mc" <<M
#!/bin/sh
echo "\$*" >> "$WORK/state/mc"
M
  chmod +x "$WORK"/bin/*
  # Immich's UPLOAD_LOCATION layout
  L="$WORK/library"; mkdir -p "$L/upload/u1/ab" "$L/backups" "$L/thumbs/u1" "$L/encoded-video/u1" "$L/profile/u1"
  echo jpg > "$L/upload/u1/ab/IMG_1.jpg"; echo sql > "$L/backups/immich-db-backup.sql.gz"
}
teardown() { rm -rf "$WORK"; }
run() { # extra env...
  OUT=$(env PATH="$WORK/bin:$PATH" MC="$WORK/bin/mc" IMMICH_SRC="$WORK/library" \
        DATABASE_URL=postgres://x MINIO_ENDPOINT=http://m MINIO_ACCESS_KEY=a MINIO_SECRET_KEY=s \
        R2_ENDPOINT=https://r2 R2_BUCKET=bk R2_ACCESS_KEY=a R2_SECRET_KEY=s MONGO_URI_GAMES=mongodb://g \
        "$@" sh "$WORK/backup.sh" 2>&1); CODE=$?
}
mirrored() { grep -qx "mirror --overwrite $WORK/library/$1 r2/bk/immich/$1" "$WORK/state/mc"; }

setup; run
check "full run succeeds" test "$CODE" -eq 0
check "mirrors originals (upload/)" mirrored upload
check "mirrors Immich's DB dumps (backups/)" mirrored backups
check "mirrors profile pictures (profile/)" mirrored profile
check "skips missing library/ (storage template off)" bash -c '! grep -q "immich/library" "$1"' _ "$WORK/state/mc"
check "skips thumbs/ and encoded-video/ (regenerable)" bash -c '! grep -Eq "thumbs|encoded-video" "$1"' _ "$WORK/state/mc"
check "databases were still backed up" grep -q "postgres/infrastructure-" "$WORK/state/mc"
teardown

setup; mkdir -p "$WORK/library/library/2024"; run
check "mirrors library/ when the storage template is on" mirrored library
teardown

setup; rm -rf "$WORK/library"; run
check "fails loudly when the library isn't mounted" test "$CODE" -ne 0 -a -n "$(grep 'not mounted' <<<"$OUT")"
check "  but only after the database backups were uploaded" grep -q "postgres/infrastructure-" "$WORK/state/mc"
teardown

setup; printf '#!/bin/sh\necho "$*" >> %s/state/mc\ncase "$*" in *immich/upload*) exit 1;; esac\n' "$WORK" > "$WORK/bin/mc"; run
check "a failed upload mirror fails the job (no silent gaps)" test "$CODE" -ne 0
teardown

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
