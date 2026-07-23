#!/usr/bin/env bash
# In-cluster bootstrap: waits for Keycloak + Postgres, seeds realm/clients/
# users/databases, randomizes seeded passwords, stores them in a Secret.
# Required env (injected by the chart):
#   KEYCLOAK_URL, KEYCLOAK_ADMIN, KEYCLOAK_ADMIN_PASSWORD,
#   POSTGRES_HOST, POSTGRES_PORT, POSTGRES_USER, POSTGRES_PASSWORD,
#   SERVER_IP (external domain), NAMESPACE
set -euo pipefail

echo "Waiting for Keycloak at $KEYCLOAK_URL ..."
until curl -sf "$KEYCLOAK_URL/realms/master" >/dev/null; do sleep 5; done
echo "Waiting for Postgres at $POSTGRES_HOST:$POSTGRES_PORT ..."
until pg_isready -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" >/dev/null 2>&1; do sleep 5; done

node /seed/setup-server.js

BDP_ADMIN_PASS=$(openssl rand -hex 12)
ENGINEER_PASS=$(openssl rand -hex 12)

KC_TOKEN=$(curl -s -X POST "$KEYCLOAK_URL/realms/master/protocol/openid-connect/token" \
  -d client_id=admin-cli -d "username=$KEYCLOAK_ADMIN" \
  -d "password=$KEYCLOAK_ADMIN_PASSWORD" -d grant_type=password | jq -r .access_token)

set_pass() {
  uid=$(curl -s -H "Authorization: Bearer $KC_TOKEN" \
    "$KEYCLOAK_URL/admin/realms/bdp/users?username=$1&exact=true" | jq -r '.[0].id')
  curl -s -X PUT -H "Authorization: Bearer $KC_TOKEN" -H "Content-Type: application/json" \
    "$KEYCLOAK_URL/admin/realms/bdp/users/$uid/reset-password" \
    -d "{\"type\":\"password\",\"value\":\"$2\",\"temporary\":false}"
}
set_pass admin    "$BDP_ADMIN_PASS"
set_pass engineer "$ENGINEER_PASS"

# Publish generated credentials as a Secret via the API (SA token mounted).
SA=/var/run/secrets/kubernetes.io/serviceaccount
KAPI="https://kubernetes.default.svc"
TOKEN=$(cat $SA/token)
b64() { printf '%s' "$1" | base64 | tr -d '\n'; }
BODY="{
    \"apiVersion\":\"v1\",\"kind\":\"Secret\",
    \"metadata\":{\"name\":\"bdp-credentials\"},
    \"data\":{
      \"admin-password\":\"$(b64 "$BDP_ADMIN_PASS")\",
      \"engineer-password\":\"$(b64 "$ENGINEER_PASS")\"
    }}"
# Every run resets the Keycloak passwords, so the secret must ALWAYS be
# brought in sync — create it, or patch it when it already exists.
curl -sf --cacert $SA/ca.crt -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" -X POST \
  "$KAPI/api/v1/namespaces/$NAMESPACE/secrets" -d "$BODY" >/dev/null \
  || curl -sf --cacert $SA/ca.crt -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/strategic-merge-patch+json" -X PATCH \
      "$KAPI/api/v1/namespaces/$NAMESPACE/secrets/bdp-credentials" -d "$BODY" >/dev/null \
  || { echo "ERROR: could not create or patch bdp-credentials"; exit 1; }

echo "Seed complete. Retrieve credentials: kubectl get secret bdp-credentials -n $NAMESPACE"
