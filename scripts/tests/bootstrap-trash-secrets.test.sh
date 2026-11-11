#!/usr/bin/env bash
# Tests for scripts/bootstrap-trash-secrets.sh against fake kubectl and npx.
#   unit:        each rule (keep / generate / error) checked in isolation
#   integration: the full first-run → re-run → passcode-change lifecycle
# Run: bash scripts/tests/bootstrap-trash-secrets.test.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/scripts/bootstrap-trash-secrets.sh"
PASS=0
FAIL=0

setup() {
  WORK=$(mktemp -d)
  mkdir -p "$WORK/bin"
  export FAKE_STATE="$WORK/state"
  mkdir -p "$FAKE_STATE"
  touch "$FAKE_STATE/calls"
  # Fake kubectl: a namespace flag, one secret stored as JSON, an optional deployment.
  cat > "$WORK/bin/kubectl" <<'K'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_STATE/calls"
args=("$@")
[ "${args[0]}" = "-n" ] && args=("${args[@]:2}")
case "${args[0]} ${args[1]:-}" in
  "get namespace") [ -f "$FAKE_STATE/namespace" ] ;;
  "get secret") [ -f "$FAKE_STATE/secret.json" ] && cat "$FAKE_STATE/secret.json" ;;
  "get deployment") [ -f "$FAKE_STATE/deployment" ] ;;
  "rollout restart") echo restarted >> "$FAKE_STATE/restarts" ;;
  "create secret")
    data="{}"
    for a in "${args[@]}"; do
      case "$a" in --from-literal=*)
        kv="${a#--from-literal=}"; k="${kv%%=*}"; v="${kv#*=}"
        data=$(echo "$data" | jq --arg k "$k" --arg v "$(printf %s "$v" | base64 -w0)" '. + {($k): $v}') ;;
      esac
    done
    jq -n --argjson d "$data" '{data: $d}' ;;
  "apply -f") cat > "$FAKE_STATE/secret.json" ;;
  *) echo "fake kubectl: unexpected $*" >&2; exit 2 ;;
esac
K
  # Fake npx: hands out numbered VAPID key pairs so a regeneration is visible.
  cat > "$WORK/bin/npx" <<'N'
#!/usr/bin/env bash
n=$(( $(cat "$FAKE_STATE/vapid_count" 2>/dev/null || echo 0) + 1 ))
echo $n > "$FAKE_STATE/vapid_count"
echo "{\"publicKey\":\"PUB$n\",\"privateKey\":\"PRIV$n\"}"
N
  chmod +x "$WORK/bin/kubectl" "$WORK/bin/npx"
  export PATH="$WORK/bin:$PATH"
  unset GITHUB_ACTIONS
}

teardown() { rm -rf "$WORK"; }

run() { OUT=$(bash "$SCRIPT" 2>&1); CODE=$?; }
key() { jq -r --arg k "$1" '.data[$k] // empty' "$FAKE_STATE/secret.json" | base64 -d; }

check() { # name, condition...
  local name=$1; shift
  if "$@"; then PASS=$((PASS + 1)); echo "  ✓ $name"; else FAIL=$((FAIL + 1)); echo "  ✗ $name"; echo "$OUT" | sed 's/^/      /'; fi
}

echo "unit"

setup
run
check "fails when the namespace is missing" test "$CODE" -ne 0
check "explains how to fix a missing namespace" grep -q "provision the project in admin" <<<"$OUT"
teardown

setup
run
check "writes nothing when the namespace is missing" test ! -f "$FAKE_STATE/secret.json"
teardown

setup; touch "$FAKE_STATE/namespace"
run
check "first run succeeds with no input at all" test "$CODE" -eq 0
check "stores no passcode (the app has none)" test -z "$(key HOUSE_PASSCODE)"
check "generates a 64-char session secret" test "$(key SESSION_SECRET | wc -c)" -eq 64
check "generates a cron token" test -n "$(key CRON_TOKEN)"
check "generates VAPID keys" test "$(key VAPID_PUBLIC_KEY)/$(key VAPID_PRIVATE_KEY)" = "PUB1/PRIV1"
check "sets the VAPID subject" test "$(key VAPID_SUBJECT)" = "https://trash.morcos.tech"
check "doesn't restart an app that isn't deployed" test ! -f "$FAKE_STATE/restarts"
check "says the app will pick it up on first deploy" grep -q "first deploy" <<<"$OUT"
teardown

setup; touch "$FAKE_STATE/namespace" "$FAKE_STATE/deployment"
GITHUB_ACTIONS=true run
check "masks secrets in GitHub Actions logs" grep -q "::add-mask::$(key CRON_TOKEN)" <<<"$OUT"
check "restarts a deployed app" test -f "$FAKE_STATE/restarts"
check "never prints the session secret unmasked" bash -c "! grep -v add-mask <<<\"\$1\" | grep -q \"\$2\"" _ "$OUT" "$(key SESSION_SECRET)"
teardown

setup; touch "$FAKE_STATE/namespace"
NAMESPACE=staging-trash run
check "respects NAMESPACE" grep -q -- "-n staging-trash create secret" "$FAKE_STATE/calls"
teardown

echo "integration"

setup; touch "$FAKE_STATE/namespace"
run
first_session=$(key SESSION_SECRET); first_cron=$(key CRON_TOKEN)
touch "$FAKE_STATE/deployment"
run
check "re-run keeps the session secret" test "$(key SESSION_SECRET)" = "$first_session"
check "re-run keeps the cron token" test "$(key CRON_TOKEN)" = "$first_cron"
check "re-run never regenerates VAPID keys" test "$(key VAPID_PUBLIC_KEY)" = "PUB1" -a "$(cat "$FAKE_STATE/vapid_count")" = "1"
HOUSE_PASSCODE=leftover run
check "ignores a leftover HOUSE_PASSCODE variable" test -z "$(key HOUSE_PASSCODE)" -a "$(key SESSION_SECRET)" = "$first_session"
check "each run on a deployed app restarts it" test "$(wc -l < "$FAKE_STATE/restarts")" -eq 2
jq '.data |= del(.VAPID_PRIVATE_KEY)' "$FAKE_STATE/secret.json" > "$FAKE_STATE/s" && mv "$FAKE_STATE/s" "$FAKE_STATE/secret.json"
run
check "a half-missing VAPID pair is regenerated as a pair" test "$(key VAPID_PUBLIC_KEY)/$(key VAPID_PRIVATE_KEY)" = "PUB2/PRIV2"
teardown

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
