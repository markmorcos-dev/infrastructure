#!/usr/bin/env bash
# Create or update <namespace>/app-secrets for the trash app (markmorcos/trash).
# Fills in missing keys, keeps existing ones, and never regenerates VAPID keys
# (that would break every phone's push subscription). HOUSE_PASSCODE from the
# environment replaces the stored one; without it the stored one is kept.
# Restarts the app afterwards if it is deployed.
#
# Env: HOUSE_PASSCODE (optional after the first run), NAMESPACE (default: trash)
set -euo pipefail

NS="${NAMESPACE:-trash}"
DEPLOYMENT="trash-trash-deployment"

kubectl get namespace "$NS" >/dev/null 2>&1 || { echo "::error::namespace $NS doesn't exist; provision the project in admin first"; exit 1; }

existing=$(kubectl -n "$NS" get secret app-secrets -o json 2>/dev/null || echo '{}')
get() { echo "$existing" | jq -r --arg k "$1" '.data[$k] // empty' | base64 -d; }
mask() { [ -n "${GITHUB_ACTIONS:-}" ] && echo "::add-mask::$1" || true; }

if [ -z "${HOUSE_PASSCODE:-}" ]; then
  HOUSE_PASSCODE=$(get HOUSE_PASSCODE)
  [ -n "$HOUSE_PASSCODE" ] || { echo "::error::add the repo secret TRASH_HOUSE_PASSCODE (the code everyone types to join) and re-run"; exit 1; }
  echo "keeping the existing passcode"
else
  echo "setting the passcode"
fi

SESSION_SECRET=$(get SESSION_SECRET); [ -n "$SESSION_SECRET" ] || { SESSION_SECRET=$(openssl rand -hex 32); echo "generated SESSION_SECRET"; }
CRON_TOKEN=$(get CRON_TOKEN);         [ -n "$CRON_TOKEN" ]     || { CRON_TOKEN=$(openssl rand -hex 32); echo "generated CRON_TOKEN"; }

VAPID_PUBLIC_KEY=$(get VAPID_PUBLIC_KEY)
VAPID_PRIVATE_KEY=$(get VAPID_PRIVATE_KEY)
if [ -z "$VAPID_PUBLIC_KEY" ] || [ -z "$VAPID_PRIVATE_KEY" ]; then
  keys=$(npx --yes web-push@3.6.7 generate-vapid-keys --json)
  VAPID_PUBLIC_KEY=$(echo "$keys" | jq -r .publicKey)
  VAPID_PRIVATE_KEY=$(echo "$keys" | jq -r .privateKey)
  echo "generated VAPID keys"
else
  echo "keeping the existing VAPID keys"
fi
VAPID_SUBJECT=$(get VAPID_SUBJECT); [ -n "$VAPID_SUBJECT" ] || VAPID_SUBJECT="https://trash.morcos.tech"

for v in "$HOUSE_PASSCODE" "$SESSION_SECRET" "$CRON_TOKEN" "$VAPID_PRIVATE_KEY"; do mask "$v"; done

kubectl -n "$NS" create secret generic app-secrets \
  --from-literal=HOUSE_PASSCODE="$HOUSE_PASSCODE" \
  --from-literal=SESSION_SECRET="$SESSION_SECRET" \
  --from-literal=CRON_TOKEN="$CRON_TOKEN" \
  --from-literal=VAPID_PUBLIC_KEY="$VAPID_PUBLIC_KEY" \
  --from-literal=VAPID_PRIVATE_KEY="$VAPID_PRIVATE_KEY" \
  --from-literal=VAPID_SUBJECT="$VAPID_SUBJECT" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
echo "✅ $NS/app-secrets is up to date"

if kubectl -n "$NS" get deployment "$DEPLOYMENT" >/dev/null 2>&1; then
  kubectl -n "$NS" rollout restart "deployment/$DEPLOYMENT" >/dev/null
  echo "restarted the app so it reads the new values"
else
  echo "the app isn't deployed yet; it will read app-secrets on its first deploy"
fi
