#!/usr/bin/env bash
# Tests for bootstrap/immich.sh and its wiring into run.sh (Phase 11) and
# down.sh (Reverse Phase 11), against a fake kubectl and a temp data dir.
#   unit:        each rule (dirs / role / API wait / namespace / secret) in isolation
#   integration: fresh server -> re-run -> run.sh phase -> down.sh keep/purge
# Run: bash scripts/tests/bootstrap-immich.test.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/bootstrap/immich.sh"
PASS=0
FAIL=0

setup() {
  WORK=$(mktemp -d)
  mkdir -p "$WORK/bin" "$WORK/mnt/data"
  export FAKE_STATE="$WORK/state"
  mkdir -p "$FAKE_STATE"
  touch "$FAKE_STATE/calls"
  # Fake kubectl: an API that is ready unless $FAKE_STATE/notready exists,
  # namespaces as files, one secret stored as its literal.
  cat > "$WORK/bin/kubectl" <<'K'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_STATE/calls"
args=("$@")
[ "${args[0]}" = "-n" ] && args=("${args[@]:2}")
case "${args[*]}" in
  "get --raw /readyz") [ ! -f "$FAKE_STATE/notready" ] ;;
  "get namespace "*) [ -f "$FAKE_STATE/ns-${args[2]}" ] ;;
  "create namespace "*) touch "$FAKE_STATE/ns-${args[2]}" ;;
  "get secret immich-db") [ -f "$FAKE_STATE/secret" ] ;;
  "create secret generic immich-db --from-literal=DB_PASSWORD="*)
    printf %s "${args[4]#--from-literal=DB_PASSWORD=}" > "$FAKE_STATE/secret" ;;
  *) echo "fake kubectl: unexpected $*" >&2; exit 2 ;;
esac
K
  chmod +x "$WORK/bin/kubectl"
  export PATH="$WORK/bin:$PATH"
  export IMMICH_DATA="$WORK/mnt/data/immich" IMMICH_KUBE_WAIT=0 K3S_ROLE=server
  unset IMMICH_DB_PASSWORD
}

teardown() { rm -rf "$WORK"; }

run() { OUT=$(bash "$SCRIPT" 2>&1); CODE=$?; }
secret() { cat "$FAKE_STATE/secret" 2>/dev/null; }
creates() { grep -c "create secret" "$FAKE_STATE/calls"; }
mode() { stat -c %a "$1"; }

check() { # name, then a command that must succeed
  local name=$1; shift
  if "$@"; then PASS=$((PASS + 1)); echo "ok   $name"
  else FAIL=$((FAIL + 1)); echo "FAIL $name"; echo "$OUT" | sed 's/^/     | /'; fi
}

# Run the text of one `# === <marker>` block from a script (up to the next
# `# ===` header) so the real run.sh/down.sh wiring is exercised without
# root, apt or systemd.
block() { # file, marker
  awk -v m="$2" 'index($0, "# === " m) == 1 {on=1; print; next}
                 on && /^# === / {exit} on {print}' "$1"
}

echo "# unit: data dirs"
setup; rmdir "$WORK/mnt/data"; run
check "refuses when the data volume (parent dir) is missing" test "$CODE" -ne 0
check "  and says to mount it" grep -q "mount the data volume" <<<"$OUT"
check "  and creates nothing" test ! -e "$IMMICH_DATA"
teardown

setup; K3S_ROLE=agent run
check "creates library, postgres, model-cache" test -d "$IMMICH_DATA/library" -a -d "$IMMICH_DATA/postgres" -a -d "$IMMICH_DATA/model-cache"
check "postgres dir is private (0700)" test "$(mode "$IMMICH_DATA/postgres")" = 700
check "library is 0755" test "$(mode "$IMMICH_DATA/library")" = 755
teardown

setup; mkdir -p "$IMMICH_DATA/postgres"; chmod 750 "$IMMICH_DATA/postgres"; echo keep > "$IMMICH_DATA/library.txt"
K3S_ROLE=agent run
check "leaves an existing postgres dir's mode alone (container owns it)" test "$(mode "$IMMICH_DATA/postgres")" = 750
check "never touches existing files" grep -qx keep "$IMMICH_DATA/library.txt"
teardown

echo "# unit: role"
setup; K3S_ROLE=agent run
check "agent: succeeds" test "$CODE" -eq 0
check "agent: never calls kubectl" test ! -s "$FAKE_STATE/calls"
check "agent: prints the manual secret command" grep -q "create secret generic immich-db" <<<"$OUT"
teardown

# PATH holds only what immich.sh needs: CI runners ship a real /usr/bin/kubectl,
# so falling back to /usr/bin would not hide it.
setup; mkdir "$WORK/sysbin"
for t in bash dirname install head od tr sleep; do ln -s "$(command -v "$t")" "$WORK/sysbin/$t"; done
OUT=$(PATH="$WORK/sysbin" "$WORK/sysbin/bash" "$SCRIPT" 2>&1); CODE=$?
check "server without kubectl: fails clearly" test "$CODE" -ne 0 -a -n "$(grep 'kubectl not found' <<<"$OUT")"
teardown

setup; touch "$FAKE_STATE/notready"; run
check "server, API never ready: fails after the wait" test "$CODE" -ne 0 -a -n "$(grep 'not ready' <<<"$OUT")"
check "  and creates no secret" test -z "$(secret)"
teardown

echo "# unit: namespace"
setup; run
check "creates the namespace when missing" test -f "$FAKE_STATE/ns-immich"
teardown
setup; touch "$FAKE_STATE/ns-immich"; run
check "doesn't recreate an existing namespace" test "$(grep -c 'create namespace' "$FAKE_STATE/calls")" -eq 0
teardown

echo "# unit: secret"
setup; run
check "generates a 48-char hex password" grep -Eqx '[0-9a-f]{48}' <<<"$(secret)"
teardown
setup; IMMICH_DB_PASSWORD=AbcdEfgh12345678xyz run
check "uses IMMICH_DB_PASSWORD when valid" test "$(secret)" = AbcdEfgh12345678xyz
teardown
for bad in 'short1' 'has-dash-1234567890' 'with space 1234567890' 'p@ssw0rd1234567890'; do
  setup; IMMICH_DB_PASSWORD="$bad" run
  check "rejects IMMICH_DB_PASSWORD '$bad' without creating a secret" test "$CODE" -ne 0 -a -z "$(secret)"
  teardown
done
setup; printf original > "$FAKE_STATE/secret"; touch "$FAKE_STATE/ns-immich"; IMMICH_DB_PASSWORD=AbcdEfgh12345678xyz run
check "never overwrites an existing secret" test "$(secret)" = original -a "$(creates)" -eq 0
check "  and warns that IMMICH_DB_PASSWORD was ignored" grep -q "ignored" <<<"$OUT"
teardown

echo "# integration: lifecycle"
setup
run;  first=$(secret); c1=$CODE
run;  c2=$CODE
check "fresh server run succeeds" test "$c1" -eq 0
check "re-run succeeds and is a no-op for the secret" test "$c2" -eq 0 -a "$(secret)" = "$first" -a "$(creates)" -eq 1

# run.sh Phase 11, as written in run.sh, run with run.sh's defaults. From a
# checkout it uses the immich.sh next to it; under `curl | bash` (no copy next
# to it) it fetches immich.sh from REPO_RAW_URL.
PHASE=$(block "$ROOT/bootstrap/run.sh" "Phase 11: Immich")
check "run.sh has a Phase 11 block calling immich.sh" grep -q 'immich.sh' <<<"$PHASE"
phase_file() { # dir -> writes the block as a script there, with run.sh's defaults
  mkdir -p "$1"
  { echo 'set -euo pipefail; log(){ echo "$*"; }'
    echo 'INSTALL_IMMICH="${INSTALL_IMMICH:-0}" IMMICH_DB_PASSWORD="${IMMICH_DB_PASSWORD:-}"'
    echo 'IMMICH_DATA="${IMMICH_DATA:-/mnt/data/immich}" K3S_ROLE="${K3S_ROLE:-agent}"'
    echo "$PHASE"; } > "$1/run.sh"
}
phase_file "$WORK/checkout"; cp "$SCRIPT" "$WORK/checkout/immich.sh"
OUT=$(INSTALL_IMMICH=1 REPO_RAW_URL=http://unused.invalid bash "$WORK/checkout/run.sh" 2>&1); CODE=$?
check "run.sh Phase 11 runs the local immich.sh (re-run keeps the secret)" \
  test "$CODE" -eq 0 -a "$(secret)" = "$first" -a "$(creates)" -eq 1

phase_file "$WORK/piped"
cat > "$WORK/bin/curl" <<C
#!/usr/bin/env bash
echo "\$*" >> "$FAKE_STATE/curl"
out=""; while [ \$# -gt 0 ]; do [ "\$1" = -o ] && out=\$2; shift; done
cp "$SCRIPT" "\$out"
C
chmod +x "$WORK/bin/curl"
OUT=$(INSTALL_IMMICH=1 REPO_RAW_URL=https://raw.example/bootstrap bash "$WORK/piped/run.sh" 2>&1); CODE=$?
check "run.sh Phase 11 fetches immich.sh from REPO_RAW_URL when piped" \
  test "$CODE" -eq 0 -a -n "$(grep -F 'https://raw.example/bootstrap/immich.sh' "$FAKE_STATE/curl" 2>/dev/null)"
check "  and still keeps the secret" test "$(secret)" = "$first" -a "$(creates)" -eq 1
OUT=$(INSTALL_IMMICH=0 bash "$WORK/checkout/run.sh" 2>&1); CODE=$?
check "run.sh Phase 11 is skipped when INSTALL_IMMICH=0" test "$CODE" -eq 0 -a -z "$OUT"

# down.sh: photos survive PURGE_DATA alone; need PURGE_IMMICH=1 as well.
REV=$(block "$ROOT/bootstrap/down.sh" "Reverse Phase 11: Immich")
helpers='log(){ echo "$*"; }; warn(){ echo "$*" >&2; }; rm_rf(){ rm -rf "$@" 2>/dev/null || true; };'
echo photo > "$IMMICH_DATA/library/IMG_1.jpg"
OUT=$(INSTALL_IMMICH=1 PURGE_DATA=1 PURGE_IMMICH=0 bash -c "$helpers $REV" 2>&1)
check "down.sh PURGE_DATA=1 alone keeps the photos" test -f "$IMMICH_DATA/library/IMG_1.jpg"
OUT=$(INSTALL_IMMICH=1 PURGE_DATA=0 PURGE_IMMICH=1 bash -c "$helpers $REV" 2>&1)
check "down.sh PURGE_IMMICH=1 without PURGE_DATA keeps the photos" test -f "$IMMICH_DATA/library/IMG_1.jpg"
OUT=$(INSTALL_IMMICH=1 PURGE_DATA=1 PURGE_IMMICH=1 bash -c "$helpers $REV" 2>&1)
check "down.sh PURGE_DATA=1 PURGE_IMMICH=1 deletes them" test ! -e "$IMMICH_DATA"
check "  but not the rest of the data volume" test -d "$WORK/mnt/data"
teardown

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
