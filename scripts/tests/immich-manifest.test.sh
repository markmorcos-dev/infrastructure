#!/usr/bin/env bash
# Tests for k8s/09-immich.yaml (applied verbatim by apply-k8s.yaml).
#   unit:        each rule checked in isolation, plus a broken copy per rule to
#                prove the rule actually catches the mistake
#   integration: the whole stack wires up: every hostname/port the app config
#                points at is a Service in the namespace that selects a pod
#                exposing that port, and every secret/configmap ref resolves
# Run: bash scripts/tests/immich-manifest.test.sh   (needs python3 + PyYAML, jq)
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MANIFEST="${MANIFEST:-$ROOT/k8s/09-immich.yaml}"
PASS=0
FAIL=0

# Multi-doc YAML -> JSON array (PyYAML; the two yq flavours disagree on flags).
to_json() {
  python3 -c 'import json, sys, yaml
print(json.dumps([d for d in yaml.safe_load_all(open(sys.argv[1])) if d]))' "$1"
}

DOCS=$(to_json "$MANIFEST") || { echo "cannot parse $MANIFEST"; exit 1; }
q() { jq -r "$@" <<<"$DOCS"; }

check() { # name, then a command that must succeed
  local name=$1; shift
  if "$@"; then PASS=$((PASS + 1)); echo "ok   $name"
  else FAIL=$((FAIL + 1)); echo "FAIL $name"; fi
}

# ---------------------------------------------------------------- rules ---
# Each rule reads JSON on stdin and prints offending items (empty = pass).
rule_pinned_to_m720q() {
  jq -r '.[] | select(.kind=="Deployment")
    | select(.spec.template.spec.nodeSelector["kubernetes.io/hostname"] != "m720q") | .metadata.name'
}
rule_single_writer() {
  jq -r '.[] | select(.kind=="Deployment")
    | select(.spec.replicas != 1 or .spec.strategy.type != "Recreate") | .metadata.name'
}
rule_images_pinned() {
  jq -r '.[] | select(.kind=="Deployment") | .spec.template.spec.containers[].image
    | select((test("@sha256:") or test(":v[0-9]+\\.[0-9]+\\.[0-9]+$")) | not)'
}
rule_versions_match() {
  jq -r '[.[] | select(.kind=="Deployment") | .spec.template.spec.containers[].image
    | select(test("immich-app/immich-")) | sub(".*:"; "")] | unique
    | if length == 1 then empty else join(" != ") end'
}
rule_hostpaths_in_data_dir() {
  jq -r '.[] | select(.kind=="Deployment") | .spec.template.spec.volumes[]? | .hostPath.path // empty
    | select(. != "/dev/dri" and (startswith("/mnt/data/immich/") | not))'
}
rule_password_from_secret() {
  jq -r '.[] | select(.kind=="Deployment") | .spec.template.spec.containers[] | .env[]?
    | select(.name | test("PASSWORD")) | select(.value != null or .valueFrom.secretKeyRef.name != "immich-db") | .name'
}
rule_everything_namespaced() {
  jq -r '.[] | select(.kind != "Namespace") | select(.metadata.namespace != "immich") | "\(.kind)/\(.metadata.name)"'
}
rule_privileged_only_server() {
  jq -r '.[] | select(.kind=="Deployment") | . as $d | .spec.template.spec.containers[]
    | select(.securityContext.privileged == true) | select($d.metadata.name != "immich-server") | .name'
}
rule_ingress_uncapped() { # nginx defaults to 1m bodies: video uploads would 413
  jq -r '.[] | select(.kind=="Ingress")
    | select(.metadata.annotations["nginx.ingress.kubernetes.io/proxy-body-size"] != "0") | .metadata.name'
}
rule_ingress_tls() { # exactly one public ingress; every host it serves has a cert
  jq -r '[.[] | select(.kind=="Ingress")] as $i
    | if ($i | length) != 1 then "expected 1 Ingress, got \($i | length)" else
        $i[0] | ([.spec.tls[]?.hosts[]]) as $tls
        | .spec.rules[].host | select(. as $h | $tls | index($h) | not) end'
}

RULES=(pinned_to_m720q single_writer images_pinned versions_match hostpaths_in_data_dir
       password_from_secret everything_namespaced privileged_only_server
       ingress_uncapped ingress_tls)

echo "# unit: manifest passes every rule"
for r in "${RULES[@]}"; do
  out=$(rule_$r <<<"$DOCS")
  check "$r${out:+ ($out)}" test -z "$out"
done

echo "# unit: each rule rejects a broken manifest"
srv='(.[] | select(.kind=="Deployment" and .metadata.name=="immich-server"))'
ml='(.[] | select(.kind=="Deployment" and .metadata.name=="immich-machine-learning"))'
ing='(.[] | select(.kind=="Ingress"))'
declare -A BREAK=(
  [pinned_to_m720q]="$srv.spec.template.spec.nodeSelector = {}"
  [single_writer]="$srv.spec.replicas = 2"
  [images_pinned]="$srv.spec.template.spec.containers[0].image = \"ghcr.io/immich-app/immich-server:release\""
  [versions_match]="$ml.spec.template.spec.containers[0].image = \"ghcr.io/immich-app/immich-machine-learning:v0.0.1\""
  [hostpaths_in_data_dir]="$srv.spec.template.spec.volumes[0].hostPath.path = \"/home/photos\""
  [password_from_secret]="$srv.spec.template.spec.containers[0].env[0] = {name: \"DB_PASSWORD\", value: \"hunter2\"}"
  [everything_namespaced]="$srv.metadata.namespace = \"default\""
  [privileged_only_server]="$ml.spec.template.spec.containers[0].securityContext = {privileged: true}"
  [ingress_uncapped]="$ing.metadata.annotations[\"nginx.ingress.kubernetes.io/proxy-body-size\"] = \"10m\""
  [ingress_tls]="$ing.spec.tls = []"
)
for r in "${RULES[@]}"; do
  out=$(jq "${BREAK[$r]}" <<<"$DOCS" | rule_$r)
  check "$r catches breakage" test -n "$out"
done

# ---------------------------------------------------------- integration ---
echo "# integration: the stack wires together"
cfg() { q --arg k "$1" '.[] | select(.kind=="ConfigMap" and .metadata.name=="immich-env") | .data[$k] // empty'; }

# A hostname:port the app dials must be a Service whose selector matches a
# Deployment that exposes the target port.
wired() { # host port
  local sel
  sel=$(q --arg h "$1" --argjson p "$2" '.[] | select(.kind=="Service" and .metadata.name==$h)
          | select(any(.spec.ports[]; .port==$p)) | .spec.selector | tojson')
  [ -n "$sel" ] || { echo "  no Service $1:$2" >&2; return 1; }
  q --argjson s "$sel" --argjson p "$2" '[.[] | select(.kind=="Deployment")
      | select(.spec.template.metadata.labels | contains($s))
      | select(any(.spec.template.spec.containers[].ports[]?; .containerPort==$p))] | length' | grep -qx 1
}
check "server -> postgres ($(cfg DB_HOSTNAME):$(cfg DB_PORT))" wired "$(cfg DB_HOSTNAME)" "$(cfg DB_PORT)"
check "server -> valkey ($(cfg REDIS_HOSTNAME):$(cfg REDIS_PORT))" wired "$(cfg REDIS_HOSTNAME)" "$(cfg REDIS_PORT)"
ml_url=$(cfg IMMICH_MACHINE_LEARNING_URL)
ml_host=$(sed -E 's#^https?://([^:/]+):([0-9]+).*#\1#' <<<"$ml_url")
ml_port=$(sed -E 's#^https?://([^:/]+):([0-9]+).*#\2#' <<<"$ml_url")
check "server -> machine-learning ($ml_url)" wired "$ml_host" "$ml_port"
check "port-forward target svc/immich-server:2283" wired immich-server 2283
ing_svc=$(q '.[] | select(.kind=="Ingress") | .spec.rules[0].http.paths[0].backend.service.name')
ing_port=$(q '.[] | select(.kind=="Ingress") | .spec.rules[0].http.paths[0].backend.service.port.number')
check "ingress -> $ing_svc:$ing_port reaches the server pod" wired "$ing_svc" "$ing_port"
check "ingress backend is the server, not another service" test "$ing_svc" = immich-server

# Postgres must create exactly the DB/user the server logs in with.
pg_from_cfg() { q --arg n "$1" '.[] | select(.metadata.name=="immich-postgres" and .kind=="Deployment")
  | .spec.template.spec.containers[0].env[] | select(.name==$n) | .valueFrom.configMapKeyRef.key'; }
check "postgres user/db come from the same config as the server" \
  test "$(pg_from_cfg POSTGRES_USER) $(pg_from_cfg POSTGRES_DB)" = "DB_USERNAME DB_DATABASE_NAME"

# Every configMap/secret a pod references is either in the manifest or is the
# one hand-made secret (immich-db) documented in the header.
missing=$(q '([.[] | select(.kind=="ConfigMap") | .metadata.name] + ["immich-db"]) as $have
  | [.. | objects | (.configMapKeyRef.name? , .secretKeyRef.name? , .configMapRef.name?) // empty]
  | unique | map(select(. as $n | $have | index($n) | not)) | join(" ")')
check "all config/secret refs resolve${missing:+ (missing: $missing)}" test -z "$missing"
check "header documents the hand-made immich-db secret" grep -q 'create secret generic immich-db' "$MANIFEST"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
