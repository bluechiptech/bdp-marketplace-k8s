#!/usr/bin/env bash
# Provision the bdp-admin-svc service-account client used by
# bdp-auth-service's KeycloakAdminClient to drive the Keycloak Admin REST API
# (the /dashboard/users user manager).
#
# Without this client, every KeycloakAdminController call fails at
# accessToken() with a 401 on the client_credentials grant, which surfaces
# to the UI as "BDP-0000 Internal server error".
#
# Idempotent — safe to re-run.
#
# Requires: curl, jq
#
# Env overrides:
#   KC_URL           Keycloak base URL                (default: http://localhost:8080)
#   KC_ADMIN_USER    master-realm admin user          (default: admin)
#   KC_ADMIN_PASS    master-realm admin pass          (default: admin)
#   KC_REALM         Realm to provision into          (default: bdp)
#   ADMIN_SVC_ID     Service-account client id        (default: bdp-admin-svc)
#   ADMIN_SVC_SECRET Service-account client secret    (default: bdp-admin-svc-secret)
#                    MUST match bdp.keycloak.admin-client-secret in application.yml
set -euo pipefail

KC_URL="${KC_URL:-http://localhost:8080}"
KC_ADMIN_USER="${KC_ADMIN_USER:-admin}"
KC_ADMIN_PASS="${KC_ADMIN_PASS:-admin}"
KC_REALM="${KC_REALM:-bdp}"
ADMIN_SVC_ID="${ADMIN_SVC_ID:-bdp-admin-svc}"
ADMIN_SVC_SECRET="${ADMIN_SVC_SECRET:-bdp-admin-svc-secret}"

for cmd in curl jq; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: $cmd is required but not installed" >&2
    exit 1
  fi
done

echo "=== BDP Keycloak admin-svc provisioner ==="
echo "Keycloak: $KC_URL  Realm: $KC_REALM  Client: $ADMIN_SVC_ID"
echo ""

# ── 1. Master admin token ──────────────────────────────────────────
echo "1. Obtaining master admin token..."
TOKEN_RESPONSE=$(curl -sS -X POST "$KC_URL/realms/master/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode "username=$KC_ADMIN_USER" \
  --data-urlencode "password=$KC_ADMIN_PASS" \
  -d "grant_type=password" \
  -d "client_id=admin-cli")

ACCESS_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.access_token // empty')
if [[ -z "$ACCESS_TOKEN" ]]; then
  echo "ERROR: Failed to get admin token. Response:" >&2
  echo "$TOKEN_RESPONSE" | jq . 2>/dev/null || echo "$TOKEN_RESPONSE" >&2
  exit 1
fi
echo "   Token obtained."

api() {
  curl -sS "$@" -H "Authorization: Bearer $ACCESS_TOKEN" -H "Content-Type: application/json"
}

# ── 2. Create or update bdp-admin-svc as a confidential service-account client ──
echo "2. Creating/updating $ADMIN_SVC_ID..."
CLIENT_PAYLOAD=$(jq -n --arg id "$ADMIN_SVC_ID" --arg secret "$ADMIN_SVC_SECRET" '{
  clientId: $id,
  enabled: true,
  publicClient: false,
  standardFlowEnabled: false,
  directAccessGrantsEnabled: false,
  serviceAccountsEnabled: true,
  clientAuthenticatorType: "client-secret",
  secret: $secret,
  protocol: "openid-connect"
}')

EXISTING=$(api "$KC_URL/admin/realms/$KC_REALM/clients?clientId=$ADMIN_SVC_ID")
CLIENT_UUID=$(echo "$EXISTING" | jq -r '.[0].id // empty')

if [[ -z "$CLIENT_UUID" ]]; then
  api -X POST "$KC_URL/admin/realms/$KC_REALM/clients" -d "$CLIENT_PAYLOAD" >/dev/null
  EXISTING=$(api "$KC_URL/admin/realms/$KC_REALM/clients?clientId=$ADMIN_SVC_ID")
  CLIENT_UUID=$(echo "$EXISTING" | jq -r '.[0].id // empty')
  echo "   Created $ADMIN_SVC_ID (id: $CLIENT_UUID)"
else
  api -X PUT "$KC_URL/admin/realms/$KC_REALM/clients/$CLIENT_UUID" -d "$CLIENT_PAYLOAD" >/dev/null
  echo "   Updated existing $ADMIN_SVC_ID (id: $CLIENT_UUID)"
fi

if [[ -z "$CLIENT_UUID" ]]; then
  echo "ERROR: Could not resolve client UUID for $ADMIN_SVC_ID" >&2
  exit 1
fi

# Ensure the stored secret matches (POST/PUT sets it, but re-assert to be safe).
api -X POST "$KC_URL/admin/realms/$KC_REALM/clients/$CLIENT_UUID/client-secret" >/dev/null || true
# The line above rotates the secret; set it back to the expected value explicitly.
api -X PUT "$KC_URL/admin/realms/$KC_REALM/clients/$CLIENT_UUID" -d "$CLIENT_PAYLOAD" >/dev/null
echo "   Secret set to configured value."

# ── 3. Resolve the service-account user + realm-management client ───
echo "3. Resolving service-account user and realm-management roles..."
SA_USER_ID=$(api "$KC_URL/admin/realms/$KC_REALM/clients/$CLIENT_UUID/service-account-user" | jq -r '.id // empty')
if [[ -z "$SA_USER_ID" ]]; then
  echo "ERROR: Service account user not found — is serviceAccountsEnabled set?" >&2
  exit 1
fi

RM_UUID=$(api "$KC_URL/admin/realms/$KC_REALM/clients?clientId=realm-management" | jq -r '.[0].id // empty')
if [[ -z "$RM_UUID" ]]; then
  echo "ERROR: realm-management client not found in realm $KC_REALM" >&2
  exit 1
fi

# Roles the KeycloakAdminClient needs:
#   manage-users  -> create/update/delete/reset-password/role-mappings
#   view-users    -> list/get users
#   query-users   -> search users
#   view-realm    -> read realm roles (GET /roles) for the role picker
#   view-clients        -> list clients, needed to resolve bdp-client's UUID
#   manage-authorization -> required to EDIT permissions from BDP
#                          (PUT /api/v1/admin/role-permissions/...). It is
#                          write access over the authorization model itself,
#                          so it is granted for that feature and nothing else:
#                          the read-only matrix deliberately uses the
#                          view-only endpoints even though the settings export
#                          would be fewer calls.
#
#                          The blast radius is real -- whoever compromises
#                          bdp-auth-service can rewrite every permission on the
#                          platform. Mitigations: the endpoint is behind
#                          bdp:roles#write, which only admin holds; revoking
#                          from admin is refused outright; and every change is
#                          audited at HIGH severity naming the actor.
#   view-authorization  -> read that client's resource-server settings, which
#                          is what backs the role -> permissions matrix on
#                          /dashboard/roles. Without these two the matrix
#                          query returns an empty list rather than a 403, so
#                          the screen renders "no permissions" instead of an
#                          error and nobody can tell it is broken.
WANT_ROLES=("manage-users" "view-users" "query-users" "view-realm"             "view-clients" "view-authorization" "manage-authorization")

AVAILABLE=$(api "$KC_URL/admin/realms/$KC_REALM/users/$SA_USER_ID/role-mappings/clients/$RM_UUID/available")

ASSIGN="[]"
for role in "${WANT_ROLES[@]}"; do
  entry=$(echo "$AVAILABLE" | jq -c ".[] | select(.name==\"$role\")")
  if [[ -n "$entry" ]]; then
    ASSIGN=$(echo "$ASSIGN" | jq -c ". + [$entry]")
  fi
done

COUNT=$(echo "$ASSIGN" | jq 'length')
if [[ "$COUNT" -gt 0 ]]; then
  api -X POST "$KC_URL/admin/realms/$KC_REALM/users/$SA_USER_ID/role-mappings/clients/$RM_UUID" -d "$ASSIGN" >/dev/null
  echo "   Assigned $COUNT realm-management role(s): $(echo "$ASSIGN" | jq -r '[.[].name] | join(", ")')"
else
  echo "   All required roles already assigned (nothing to add)."
fi

# ── 4. Smoke test the client_credentials grant ─────────────────────
echo "4. Verifying client_credentials grant..."
GRANT=$(curl -sS -X POST "$KC_URL/realms/$KC_REALM/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=client_credentials" \
  --data-urlencode "client_id=$ADMIN_SVC_ID" \
  --data-urlencode "client_secret=$ADMIN_SVC_SECRET")

if echo "$GRANT" | jq -e '.access_token' >/dev/null 2>&1; then
  echo "   OK — $ADMIN_SVC_ID can obtain a token."
else
  echo "ERROR: client_credentials grant still failing:" >&2
  echo "$GRANT" | jq . 2>/dev/null || echo "$GRANT" >&2
  exit 1
fi

echo ""
echo "=== Done ==="
echo "Restart bdp-auth-service is NOT required (token is fetched lazily),"
echo "but if it cached a failure, a restart clears it. Reload /dashboard/users."
