#!/usr/bin/env bash
# Apply the BDP authorization catalog to the running Keycloak using
# the Admin REST API (no Docker dependency).
# Idempotent — safe to re-run after edits to config/keycloak/authz-bdp.json.
#
# Requires: curl, jq
#
# Env overrides:
#   KC_URL        Keycloak base URL                 (default: http://localhost:8080)
#   KC_ADMIN_USER Keycloak master-realm admin user  (default: admin)
#   KC_ADMIN_PASS Keycloak master-realm admin pass  (default: admin)
#   KC_REALM      Realm to import into              (default: bdp)
#   AUTHZ_CONFIG_DIR  Folder holding authz-bdp.json (default: <repo>/config/keycloak)
#                     -- the Helm chart's Keycloak job mounts it elsewhere.
set -euo pipefail

KC_URL="${KC_URL:-http://localhost:8080}"
KC_ADMIN_USER="${KC_ADMIN_USER:-admin}"
KC_ADMIN_PASS="${KC_ADMIN_PASS:-admin}"
KC_REALM="${KC_REALM:-bdp}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG_DIR="${AUTHZ_CONFIG_DIR:-$REPO_ROOT/config/keycloak}"

if [[ ! -f "$CONFIG_DIR/authz-bdp.json" ]]; then
  echo "ERROR: $CONFIG_DIR/authz-bdp.json not found" >&2
  exit 1
fi

for cmd in curl jq; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: $cmd is required but not installed" >&2
    exit 1
  fi
done

echo "=== BDP Keycloak Authorization Seeder ==="
echo "Keycloak: $KC_URL  Realm: $KC_REALM"
echo ""

# ── 1. Get admin access token ──────────────────────────────────────
echo "1. Obtaining admin access token..."
# --data-urlencode on the credentials, not -d. The generated Keycloak admin
# password contains +, / and =, which -d sends raw into a form body where they
# already mean something else. Keycloak receives a different password and
# answers "Invalid user credentials", which reads as a wrong secret and sends
# you looking in the wrong place -- it is an encoding bug here, not a bad
# credential. Verified against the live realm: -d gives 401, --data-urlencode
# gives 200 with the same password.
#
# The master admin-cli token lives only 60 seconds by default, and a full run
# makes several hundred calls. On a slower cluster the token expired during
# step 7, every later call got {"error":"HTTP 401 Unauthorized"} (an object,
# not a list), and step 8 died with "jq: Cannot index string with string
# name" -- the domain groups and extra realm roles were never created. So the
# token is fetched by a function and renewed (refresh_token) at every step and
# every loop pass, long before it can expire.
get_admin_token() {
  local resp
  resp=$(curl -sS -X POST "$KC_URL/realms/master/protocol/openid-connect/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "username=$KC_ADMIN_USER" \
    --data-urlencode "password=$KC_ADMIN_PASS" \
    -d "grant_type=password" \
    -d "client_id=admin-cli")
  ACCESS_TOKEN=$(echo "$resp" | jq -r '.access_token // empty')
  if [[ -z "$ACCESS_TOKEN" ]]; then
    echo "ERROR: Failed to get admin token. Response:" >&2
    echo "$resp" | jq . 2>/dev/null || echo "$resp" >&2
    exit 1
  fi
  TOKEN_AT=$SECONDS
}
# Must run in the main shell (not inside $(...)), or the new token is lost.
refresh_token() {
  if (( SECONDS - TOKEN_AT > 30 )); then get_admin_token; fi
}
get_admin_token
echo "   Token obtained."

api() {
  curl -sS "$@" -H "Authorization: Bearer $ACCESS_TOKEN" -H "Content-Type: application/json"
}

# ── 2. Create or find bdp-client ───────────────────────────────────
echo "2. Creating/finding bdp-client..."
EXISTING=$(api "$KC_URL/admin/realms/$KC_REALM/clients?clientId=bdp-client")
CLIENT_UUID=$(echo "$EXISTING" | jq -r '.[0].id // empty')

if [[ -z "$CLIENT_UUID" ]]; then
  echo "   Creating bdp-client..."
  CREATE_RESP=$(api -X POST "$KC_URL/admin/realms/$KC_REALM/clients" -d '{
    "clientId": "bdp-client",
    "enabled": true,
    "publicClient": false,
    "directAccessGrantsEnabled": true,
    "serviceAccountsEnabled": true,
    "authorizationServicesEnabled": true,
    "protocol": "openid-connect"
  }')

  # Get the UUID of the newly created client
  EXISTING=$(api "$KC_URL/admin/realms/$KC_REALM/clients?clientId=bdp-client")
  CLIENT_UUID=$(echo "$EXISTING" | jq -r '.[0].id // empty')
  if [[ -z "$CLIENT_UUID" ]]; then
    echo "ERROR: Failed to create bdp-client" >&2
    exit 1
  fi
  echo "   Created bdp-client (id: $CLIENT_UUID)"
else
  # Ensure authorization services are enabled
  api -X PUT "$KC_URL/admin/realms/$KC_REALM/clients/$CLIENT_UUID" -d "{
    \"clientId\": \"bdp-client\",
    \"enabled\": true,
    \"publicClient\": false,
    \"directAccessGrantsEnabled\": true,
    \"serviceAccountsEnabled\": true,
    \"authorizationServicesEnabled\": true
  }" >/dev/null
  echo "   Found existing bdp-client (id: $CLIENT_UUID), authorization enabled."
fi

AUTHZ_BASE="$KC_URL/admin/realms/$KC_REALM/clients/$CLIENT_UUID/authz/resource-server"

# ── 3. Configure resource server settings ──────────────────────────
echo "3. Configuring resource server..."
api -X PUT "$AUTHZ_BASE" -d '{
  "allowRemoteResourceManagement": false,
  "policyEnforcementMode": "ENFORCING",
  "decisionStrategy": "AFFIRMATIVE"
}' >/dev/null
echo "   Resource server configured (ENFORCING, AFFIRMATIVE)."

# ── 4. Create scopes ──────────────────────────────────────────────
echo "4. Creating authorization scopes..."
# Derived from the catalog, not hardcoded. A hardcoded list meant adding a
# scope to authz-bdp.json created the resource but never the scope, so the
# permission referencing it could not bind -- and the symptom was a 403 for
# everyone including admin, on an endpoint whose resource plainly existed.
# Nothing warned; the seeder reported success.
mapfile -t SCOPES < <(jq -r '.clients[0].authorizationSettings.resources[].scopes[]?.name' \
  "$CONFIG_DIR/authz-bdp.json" | sort -u)
if [[ ${#SCOPES[@]} -eq 0 ]]; then
  echo "ERROR: no scopes found in $CONFIG_DIR/authz-bdp.json" >&2
  exit 1
fi
declare -A SCOPE_IDS

EXISTING_SCOPES=$(api "$AUTHZ_BASE/scope")
for scope_name in "${SCOPES[@]}"; do
  refresh_token
  existing_id=$(echo "$EXISTING_SCOPES" | jq -r ".[] | select(.name==\"$scope_name\") | .id // empty")
  if [[ -n "$existing_id" ]]; then
    SCOPE_IDS["$scope_name"]="$existing_id"
  else
    resp=$(api -X POST "$AUTHZ_BASE/scope" -d "{\"name\": \"$scope_name\"}")
    new_id=$(echo "$resp" | jq -r '.id // empty')
    if [[ -n "$new_id" ]]; then
      SCOPE_IDS["$scope_name"]="$new_id"
    fi
  fi
done
echo "   ${#SCOPE_IDS[@]} scopes ready."

# ── 5. Create resources ────────────────────────────────────────────
echo "5. Creating resources..."
RESOURCE_COUNT=0
EXISTING_RESOURCES=$(api "$AUTHZ_BASE/resource?max=500")

RESOURCES_JSON=$(jq -c '.clients[0].authorizationSettings.resources[]' "$CONFIG_DIR/authz-bdp.json")
while IFS= read -r resource; do
  refresh_token
  res_name=$(echo "$resource" | jq -r '.name')
  res_display=$(echo "$resource" | jq -r '.displayName')

  existing_id=$(echo "$EXISTING_RESOURCES" | jq -r ".[] | select(.name==\"$res_name\") | ._id // empty")

  scope_refs=$(echo "$resource" | jq -c '[.scopes[].name]')
  scope_payload=$(echo "$scope_refs" | jq -c '[.[] as $s | {"name": $s}]')

  if [[ -n "$existing_id" ]]; then
    api -X PUT "$AUTHZ_BASE/resource/$existing_id" -d "{
      \"_id\": \"$existing_id\",
      \"name\": \"$res_name\",
      \"displayName\": \"$res_display\",
      \"scopes\": $scope_payload
    }" >/dev/null
  else
    api -X POST "$AUTHZ_BASE/resource" -d "{
      \"name\": \"$res_name\",
      \"displayName\": \"$res_display\",
      \"scopes\": $scope_payload
    }" >/dev/null
  fi
  RESOURCE_COUNT=$((RESOURCE_COUNT + 1))
done <<< "$RESOURCES_JSON"
echo "   $RESOURCE_COUNT resources created/updated."

# Refresh resources to get IDs
EXISTING_RESOURCES=$(api "$AUTHZ_BASE/resource?max=500")

# ── 6. Create role-based policies ──────────────────────────────────
echo "6. Creating role-based policies..."
POLICY_COUNT=0
EXISTING_POLICIES=$(api "$AUTHZ_BASE/policy?max=500")

# Create any realm role a policy references but the realm does not have yet.
# Step 8 also creates roles, but it runs after this one -- so on a fresh realm,
# or the first run after a new role is added to the catalog, the policy below
# is created with its role binding silently skipped. It only came right on a
# second run, which meant a one-shot install produced a policy that matched
# nobody. Roles are cheap and creation is idempotent, so make them here.
# config.roles is a JSON string, so fromjson has to run inside the same jq
# expression. Piping the raw text into a second jq fails with "only strings
# can be parsed" -- and swallowing that with 2>/dev/null makes the whole loop
# a silent no-op, which is exactly how the first attempt at this appeared to
# work while creating nothing.
POLICY_ROLE_NAMES=$(jq -r '.clients[0].authorizationSettings.policies[]
  | select(.type=="role") | .config.roles | fromjson | .[].id' \
  "$CONFIG_DIR/authz-bdp.json" | sort -u)
for rn in $POLICY_ROLE_NAMES; do
  refresh_token
  # Test the status code, not curl's exit code. `api` is plain `curl -sS`
  # with no -f, so it exits 0 on a 404 and returns a JSON error body -- an
  # `if ! api ...` guard here silently never fires.
  rc=$(curl -sS -o /dev/null -w '%{http_code}' \
    "$KC_URL/admin/realms/$KC_REALM/roles/$rn" \
    -H "Authorization: Bearer $ACCESS_TOKEN")
  if [[ "$rc" == "404" ]]; then
    curl -sS -X POST "$KC_URL/admin/realms/$KC_REALM/roles" \
      -H "Authorization: Bearer $ACCESS_TOKEN" -H "Content-Type: application/json" \
      -d "{\"name\":\"$rn\",\"description\":\"Referenced by an authorization policy\"}" \
      >/dev/null && echo "   created missing realm role '$rn'"
  fi
done

# Get realm roles for ID lookup
REALM_ROLES=$(api "$KC_URL/admin/realms/$KC_REALM/roles")

POLICIES_JSON=$(jq -c '.clients[0].authorizationSettings.policies[] | select(.type=="role")' "$CONFIG_DIR/authz-bdp.json")
while IFS= read -r policy; do
  refresh_token
  pol_name=$(echo "$policy" | jq -r '.name')
  pol_logic=$(echo "$policy" | jq -r '.logic')
  pol_strategy=$(echo "$policy" | jq -r '.decisionStrategy')
  roles_config=$(echo "$policy" | jq -r '.config.roles')

  existing_pol_id=$(echo "$EXISTING_POLICIES" | jq -r ".[] | select(.name==\"$pol_name\") | .id // empty")

  # Build roles array with realm role IDs
  roles_payload="[]"
  role_entries=$(echo "$roles_config" | jq -c '.[]')
  while IFS= read -r role_entry; do
    role_name=$(echo "$role_entry" | jq -r '.id')
    role_required=$(echo "$role_entry" | jq -r '.required')
    realm_role_id=$(echo "$REALM_ROLES" | jq -r ".[] | select(.name==\"$role_name\") | .id // empty")
    if [[ -n "$realm_role_id" ]]; then
      roles_payload=$(echo "$roles_payload" | jq -c ". + [{\"id\": \"$realm_role_id\", \"required\": $role_required}]")
    else
      echo "   WARNING: realm role '$role_name' not found, skipping in policy '$pol_name'"
    fi
  done <<< "$role_entries"

  payload="{
    \"name\": \"$pol_name\",
    \"type\": \"role\",
    \"logic\": \"$pol_logic\",
    \"decisionStrategy\": \"$pol_strategy\",
    \"roles\": $roles_payload
  }"

  if [[ -n "$existing_pol_id" ]]; then
    api -X PUT "$AUTHZ_BASE/policy/role/$existing_pol_id" -d "$payload" >/dev/null
  else
    api -X POST "$AUTHZ_BASE/policy/role" -d "$payload" >/dev/null
  fi
  POLICY_COUNT=$((POLICY_COUNT + 1))
done <<< "$POLICIES_JSON"
echo "   $POLICY_COUNT role policies created/updated."

# Refresh policies to get IDs
EXISTING_POLICIES=$(api "$AUTHZ_BASE/policy?max=500")

# ── 7. Create scope-based permissions ──────────────────────────────
echo "7. Creating scope-based permissions..."
PERM_COUNT=0
EXISTING_PERMS=$(api "$AUTHZ_BASE/policy?type=scope&max=500")

PERMS_JSON=$(jq -c '.clients[0].authorizationSettings.policies[] | select(.type=="scope")' "$CONFIG_DIR/authz-bdp.json")
while IFS= read -r perm; do
  refresh_token
  perm_name=$(echo "$perm" | jq -r '.name')
  perm_strategy=$(echo "$perm" | jq -r '.decisionStrategy')

  # Resolve resource IDs
  res_names=$(echo "$perm" | jq -c '.resources // []')
  resource_ids="[]"
  for rn in $(echo "$res_names" | jq -r '.[]'); do
    rid=$(echo "$EXISTING_RESOURCES" | jq -r ".[] | select(.name==\"$rn\") | ._id // empty")
    if [[ -n "$rid" ]]; then
      resource_ids=$(echo "$resource_ids" | jq -c ". + [\"$rid\"]")
    fi
  done

  # Resolve scope IDs
  scope_names=$(echo "$perm" | jq -c '.scopes // []')
  scope_ids="[]"
  for sn in $(echo "$scope_names" | jq -r '.[]'); do
    sid="${SCOPE_IDS[$sn]:-}"
    if [[ -n "$sid" ]]; then
      scope_ids=$(echo "$scope_ids" | jq -c ". + [\"$sid\"]")
    fi
  done

  # Resolve policy IDs
  pol_names=$(echo "$perm" | jq -c '.policies // []')
  policy_ids="[]"
  for pn in $(echo "$pol_names" | jq -r '.[]'); do
    pid=$(echo "$EXISTING_POLICIES" | jq -r ".[] | select(.name==\"$pn\") | .id // empty")
    if [[ -n "$pid" ]]; then
      policy_ids=$(echo "$policy_ids" | jq -c ". + [\"$pid\"]")
    fi
  done

  existing_perm_id=$(echo "$EXISTING_PERMS" | jq -r ".[] | select(.name==\"$perm_name\") | .id // empty")

  payload="{
    \"name\": \"$perm_name\",
    \"type\": \"scope\",
    \"decisionStrategy\": \"$perm_strategy\",
    \"resources\": $resource_ids,
    \"scopes\": $scope_ids,
    \"policies\": $policy_ids
  }"

  if [[ -n "$existing_perm_id" ]]; then
    api -X PUT "$AUTHZ_BASE/permission/scope/$existing_perm_id" -d "$payload" >/dev/null
  else
    api -X POST "$AUTHZ_BASE/permission/scope" -d "$payload" >/dev/null
  fi
  PERM_COUNT=$((PERM_COUNT + 1))
done <<< "$PERMS_JSON"
echo "   $PERM_COUNT scope permissions created/updated."

# ── 8. Domain groups & realm roles (inline, no file parsing) ───────
echo ""
echo "8. Creating domain groups and realm roles..."
refresh_token
EXISTING_GROUPS=$(api "$KC_URL/admin/realms/$KC_REALM/groups")
GROUP_COUNT=0

create_group() {
  local name="$1" path="$2" attrs="$3"
  local existing_gid
  existing_gid=$(echo "$EXISTING_GROUPS" | jq -r ".[] | select(.name==\"$name\") | .id // empty")
  if [[ -z "$existing_gid" ]]; then
    api -X POST "$KC_URL/admin/realms/$KC_REALM/groups" \
      -d "{\"name\":\"$name\",\"path\":\"$path\",\"attributes\":$attrs}" >/dev/null
    GROUP_COUNT=$((GROUP_COUNT + 1))
    # Refresh to get the new group's ID for subgroups
    EXISTING_GROUPS=$(api "$KC_URL/admin/realms/$KC_REALM/groups")
  fi
}

create_subgroup() {
  local parent_name="$1" child_json="$2"
  local parent_id
  parent_id=$(api "$KC_URL/admin/realms/$KC_REALM/groups" | jq -r ".[] | select(.name==\"$parent_name\") | .id // empty")
  if [[ -n "$parent_id" ]]; then
    api -X POST "$KC_URL/admin/realms/$KC_REALM/groups/$parent_id/children" -d "$child_json" >/dev/null
    GROUP_COUNT=$((GROUP_COUNT + 1))
  fi
}

# Top-level sector groups
create_group "justice"   "/justice"   '{"sectorCode":["justice"],"description":["Justice sector - courts, civil records, prosecutions"]}'
create_group "trade"     "/trade"     '{"sectorCode":["trade"],"description":["Trade sector - customs, imports/exports, licensing"]}'
create_group "education" "/education" '{"sectorCode":["education"],"description":["Education sector - schools, enrolment, performance"]}'

# CDO subgroups
create_subgroup "justice"   '{"name":"cdo","attributes":{"role":["domain-cdo"],"description":["Justice Chief Data Officer"]}}'
create_subgroup "trade"     '{"name":"cdo","attributes":{"role":["domain-cdo"],"description":["Trade Chief Data Officer"]}}'
create_subgroup "education" '{"name":"cdo","attributes":{"role":["domain-cdo"],"description":["Education Chief Data Officer"]}}'

echo "   $GROUP_COUNT groups created/verified."

# Realm roles
echo "   Creating realm roles..."
ROLE_COUNT=0
EXISTING_ROLES_LIST=$(api "$KC_URL/admin/realms/$KC_REALM/roles")

create_role() {
  local name="$1" desc="$2"
  local existing
  existing=$(echo "$EXISTING_ROLES_LIST" | jq -r ".[] | select(.name==\"$name\") | .id // empty")
  if [[ -z "$existing" ]]; then
    api -X POST "$KC_URL/admin/realms/$KC_REALM/roles" \
      -d "{\"name\":\"$name\",\"description\":\"$desc\",\"composite\":false,\"clientRole\":false}" >/dev/null
    ROLE_COUNT=$((ROLE_COUNT + 1))
  fi
}

create_role "bdp:domains#read"                "List and read Domain entities"
create_role "bdp:domains#write"               "Create and update Domain entities"
create_role "bdp:domains#delete"              "Archive (soft-delete) Domain entities"
create_role "bdp:iceberg#cross-domain:write"  "Create Iceberg namespaces/tables outside callers domain"
create_role "bdp:catalog#cross-domain:read"   "Bypass per-domain catalog filter"

# Deciding on data access is deliberately separate from editing the catalogue.
# Whoever can tag an asset should not thereby be able to grant unmasked access
# to it -- both used to sit on bdp:catalog#write.
create_role "data-steward"                     "Curates assets and decides on access requests"

echo "   $ROLE_COUNT new realm roles created."

echo ""
echo "=== Done ==="
echo "Verify in Keycloak admin:"
echo "  $KC_URL/admin/master/console/#/$KC_REALM/clients"
echo "  -> bdp-client -> Authorization tab"
echo "  Resources: $RESOURCE_COUNT  Policies: $POLICY_COUNT  Permissions: $PERM_COUNT"
