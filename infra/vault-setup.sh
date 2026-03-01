#!/bin/bash
set -euo pipefail
umask 077

NAMESPACE="vault"
TRANSIT_RELEASE="vault-transit"
HA_RELEASE="vault-ha"
VAULT_CHART="hashicorp/vault"
VAULT_CHART_VERSION="0.32.0"
VAULT_IMAGE_TAG="1.21.2"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TRANSIT_VALUES="${REPO_DIR}/apps/helm/vault-transit/values.yaml"
HA_VALUES="${REPO_DIR}/apps/helm/vault-ha/values.yaml"
INGRESS_FILE="${REPO_DIR}/apps/manifests/vault/vault-ingress.yaml"
SECRETS_DIR="${REPO_DIR}/infra/secrets"

mkdir -p "$SECRETS_DIR"
chmod 700 "$SECRETS_DIR"

helm repo update

if ! kubectl -n "$NAMESPACE" get secret vault-transit-unseal >/dev/null 2>&1; then
  kubectl -n "$NAMESPACE" create secret generic vault-transit-unseal \
    --from-literal=unseal_key=placeholder \
    --from-literal=root_token=placeholder \
    --dry-run=client -o yaml | kubectl apply -f -
fi

helm upgrade --install "$TRANSIT_RELEASE" "$VAULT_CHART" \
  -n "$NAMESPACE" -f "$TRANSIT_VALUES" \
  --set server.image.tag="$VAULT_IMAGE_TAG" \
  --create-namespace --version "$VAULT_CHART_VERSION"

kubectl -n "$NAMESPACE" rollout status sts/${TRANSIT_RELEASE} --timeout=300s || true

TRANSIT_POD="${TRANSIT_RELEASE}-0"

if ! kubectl -n "$NAMESPACE" exec "$TRANSIT_POD" -- vault status -format=json 2>/dev/null | grep -q '"initialized":true'; then
  INIT_JSON=$(kubectl -n "$NAMESPACE" exec "$TRANSIT_POD" -- vault operator init -key-shares=1 -key-threshold=1 -format=json)
  echo "$INIT_JSON" > "${SECRETS_DIR}/${TRANSIT_RELEASE}-init.json"
fi

if [ -f "${SECRETS_DIR}/${TRANSIT_RELEASE}-init.json" ]; then
  UNSEAL_KEY=$(python3 - "${SECRETS_DIR}/${TRANSIT_RELEASE}-init.json" <<'PY'
import json,sys
with open(sys.argv[1]) as f:
    data=json.load(f)
print(data["unseal_keys_b64"][0])
PY
  )
  ROOT_TOKEN=$(python3 - "${SECRETS_DIR}/${TRANSIT_RELEASE}-init.json" <<'PY'
import json,sys
with open(sys.argv[1]) as f:
    data=json.load(f)
print(data["root_token"])
PY
  )
  kubectl -n "$NAMESPACE" create secret generic vault-transit-unseal \
    --from-literal=unseal_key="$UNSEAL_KEY" \
    --from-literal=root_token="$ROOT_TOKEN" \
    --dry-run=client -o yaml | kubectl apply -f -
fi

UNSEAL_KEY=$(kubectl -n "$NAMESPACE" get secret vault-transit-unseal -o jsonpath='{.data.unseal_key}' | base64 -d)
for i in 0 1 2; do
  kubectl -n "$NAMESPACE" exec "${TRANSIT_RELEASE}-${i}" -- vault operator unseal "$UNSEAL_KEY" || true
done

ROOT_TOKEN=$(kubectl -n "$NAMESPACE" get secret vault-transit-unseal -o jsonpath='{.data.root_token}' | base64 -d)

kubectl -n "$NAMESPACE" exec "$TRANSIT_POD" -- sh -c "VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$ROOT_TOKEN vault secrets enable -path=transit transit" || true
kubectl -n "$NAMESPACE" exec "$TRANSIT_POD" -- sh -c "VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$ROOT_TOKEN vault list -format=json transit/keys | grep -q '\"vault-ha-key\"' || VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$ROOT_TOKEN vault write -f transit/keys/vault-ha-key"

POLICY=$(cat <<'POL'
path "transit/encrypt/vault-ha-key" {
  capabilities = ["update"]
}
path "transit/decrypt/vault-ha-key" {
  capabilities = ["update"]
}
POL
)
kubectl -n "$NAMESPACE" exec -i "$TRANSIT_POD" -- sh -c "VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$ROOT_TOKEN vault policy write auto-unseal -" <<<"$POLICY"

AUTOSEAL_JSON=$(kubectl -n "$NAMESPACE" exec "$TRANSIT_POD" -- sh -c "VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=$ROOT_TOKEN vault token create -policy=auto-unseal -ttl=17520h -format=json")
echo "$AUTOSEAL_JSON" > "${SECRETS_DIR}/vault-ha-autoseal.json"
AUTOSEAL_TOKEN=$(python3 - "${SECRETS_DIR}/vault-ha-autoseal.json" <<'PY'
import json,sys
with open(sys.argv[1]) as f:
    data=json.load(f)
print(data["auth"]["client_token"])
PY
)

kubectl -n "$NAMESPACE" create secret generic vault-ha-autoseal \
  --from-literal=token="$AUTOSEAL_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install "$HA_RELEASE" "$VAULT_CHART" \
  -n "$NAMESPACE" -f "$HA_VALUES" --set autoSealToken="$AUTOSEAL_TOKEN" \
  --set server.image.tag="$VAULT_IMAGE_TAG" \
  --version "$VAULT_CHART_VERSION"

kubectl -n "$NAMESPACE" rollout status sts/${HA_RELEASE} --timeout=300s || true

HA_POD="${HA_RELEASE}-0"
if ! kubectl -n "$NAMESPACE" exec "$HA_POD" -- vault status -format=json 2>/dev/null | grep -q '"initialized":true'; then
  HA_INIT_JSON=$(kubectl -n "$NAMESPACE" exec "$HA_POD" -- vault operator init -recovery-shares=1 -recovery-threshold=1 -format=json)
  echo "$HA_INIT_JSON" > "${SECRETS_DIR}/${HA_RELEASE}-init.json"
  RECOVERY_KEY=$(python3 - "${SECRETS_DIR}/${HA_RELEASE}-init.json" <<'PY'
import json,sys
with open(sys.argv[1]) as f:
    data=json.load(f)
print(data["recovery_keys_b64"][0])
PY
  )
  HA_ROOT_TOKEN=$(python3 - "${SECRETS_DIR}/${HA_RELEASE}-init.json" <<'PY'
import json,sys
with open(sys.argv[1]) as f:
    data=json.load(f)
print(data["root_token"])
PY
  )
  kubectl -n "$NAMESPACE" create secret generic vault-ha-init \
    --from-literal=recovery_key="$RECOVERY_KEY" \
    --from-literal=root_token="$HA_ROOT_TOKEN" \
    --dry-run=client -o yaml | kubectl apply -f -
fi

kubectl -n "$NAMESPACE" apply -f "$INGRESS_FILE"
