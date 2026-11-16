#!/usr/bin/env bash
set -euo pipefail

#
# Imports Keycloak Authorization Services configuration (scopes, resources,
# policies, and permissions) into a target client from the realm export JSON.
#
# The source of truth is data/keycloak/codaxy.json — specifically the
# authorizationSettings of the given client.
#
# Prerequisites:
#   - curl
#   - jq (https://jqlang.github.io/jq/)
#
# Usage:
#   ./seed-authz-services.sh <target_url> <client_id>
#
# Examples:
#   ./seed-authz-services.sh http://localhost:8080 cxo-engineering
#   ./seed-authz-services.sh http://localhost:8080 cxo-engineering --password-stdin
#   KEYCLOAK_ADMIN=myadmin KEYCLOAK_ADMIN_PASSWORD=secret ./seed-authz-services.sh http://localhost:8080 cxo-engineering
#
# Environment variables:
#   REALM                     Target realm (default: Codaxy)
#   KEYCLOAK_ADMIN            Admin username (default: admin)
#   KEYCLOAK_ADMIN_PASSWORD   Admin password (default: admin)
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
REALM_EXPORT="${REALM_EXPORT:-${REPO_ROOT}/data/keycloak/codaxy.json}"

PASSWORD_STDIN=false
ARGS=()
for arg in "$@"; do
  if [ "$arg" = "--password-stdin" ]; then
    PASSWORD_STDIN=true
  else
    ARGS+=("$arg")
  fi
done
set -- "${ARGS[@]+"${ARGS[@]}"}"

TARGET_URL="${1:-}"
TARGET_CLIENT_ID="${2:-}"

if [ -z "${TARGET_URL}" ] || [ -z "${TARGET_CLIENT_ID}" ]; then
  echo "Usage: $0 <target_url> <client_id> [--password-stdin]"
  echo ""
  echo "Example:"
  echo "  $0 http://localhost:8080 cxo-engineering"
  exit 1
fi

REALM="${REALM:-Codaxy}"
KEYCLOAK_ADMIN="${KEYCLOAK_ADMIN:-admin}"
if [ "${PASSWORD_STDIN}" = true ]; then
  echo -n "Password: " >&2
  read -s -r KEYCLOAK_ADMIN_PASSWORD
  echo >&2
else
  KEYCLOAK_ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD:-admin}"
fi

# --- Extract authorizationSettings from codaxy.json ---
echo "Reading authorization settings for '${TARGET_CLIENT_ID}' from ${REALM_EXPORT}..."
AUTHZ_SETTINGS=$(jq --arg cid "${TARGET_CLIENT_ID}" '
  .clients[] | select(.clientId == $cid) | .authorizationSettings
' "${REALM_EXPORT}")

if [ -z "${AUTHZ_SETTINGS}" ] || [ "${AUTHZ_SETTINGS}" = "null" ]; then
  echo "ERROR: No authorizationSettings found for '${TARGET_CLIENT_ID}' in ${REALM_EXPORT}" >&2
  exit 1
fi

SOURCE_SCOPES=$(echo "${AUTHZ_SETTINGS}" | jq '.scopes')
SOURCE_RESOURCES=$(echo "${AUTHZ_SETTINGS}" | jq '.resources')
SOURCE_POLICIES=$(echo "${AUTHZ_SETTINGS}" | jq '[.policies[] | select(.type == "role")]')
SOURCE_PERMISSIONS=$(echo "${AUTHZ_SETTINGS}" | jq '[.policies[] | select(.type != "role")]')

echo "  Found: $(echo "${SOURCE_SCOPES}" | jq 'length') scopes, $(echo "${SOURCE_RESOURCES}" | jq 'length') resources, $(echo "${SOURCE_POLICIES}" | jq 'length') policies, $(echo "${SOURCE_PERMISSIONS}" | jq 'length') permissions"

# --- Authenticate ---
echo ""
echo "Authenticating with ${TARGET_URL}..."
TOKEN=$(curl -sS -X POST "${TARGET_URL}/realms/master/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "username=${KEYCLOAK_ADMIN}" \
  -d "password=${KEYCLOAK_ADMIN_PASSWORD}" \
  -d "grant_type=password" \
  -d "client_id=admin-cli" | jq -r '.access_token')

if [ "${TOKEN}" = "null" ] || [ -z "${TOKEN}" ]; then
  echo "ERROR: Failed to authenticate with Keycloak at ${TARGET_URL}" >&2
  exit 1
fi

# --- Resolve target client UUID ---
echo "Resolving client UUID for '${TARGET_CLIENT_ID}' in realm '${REALM}'..."
CLIENT_UUID=$(curl -sS -X GET \
  "${TARGET_URL}/admin/realms/${REALM}/clients?clientId=${TARGET_CLIENT_ID}" \
  -H "Authorization: Bearer ${TOKEN}" | jq -r '.[0].id')

if [ "${CLIENT_UUID}" = "null" ] || [ -z "${CLIENT_UUID}" ]; then
  echo "ERROR: Client '${TARGET_CLIENT_ID}' not found in realm '${REALM}'" >&2
  exit 1
fi
echo "  Client UUID: ${CLIENT_UUID}"

AUTHZ_BASE="${TARGET_URL}/admin/realms/${REALM}/clients/${CLIENT_UUID}/authz/resource-server"

# --- 1. Sync Scopes ---
echo ""
echo "--- Syncing scopes ---"

EXISTING_SCOPES=$(curl -sS -X GET "${AUTHZ_BASE}/scope?max=500" \
  -H "Authorization: Bearer ${TOKEN}" | jq -r '.[].name')

scopes_created=0
scopes_skipped=0

for row in $(echo "${SOURCE_SCOPES}" | jq -r '.[] | @base64'); do
  scope_json=$(echo "${row}" | base64 --decode)
  scope_name=$(echo "${scope_json}" | jq -r '.name')

  if echo "${EXISTING_SCOPES}" | grep -qxF "${scope_name}"; then
    echo "  [skip] ${scope_name}"
    scopes_skipped=$((scopes_skipped + 1))
    continue
  fi

  payload=$(echo "${scope_json}" | jq '{name, displayName, iconUri}')
  HTTP_CODE=$(curl -sS -o /dev/null -w "%{http_code}" -X POST "${AUTHZ_BASE}/scope" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "${payload}")

  if [ "${HTTP_CODE}" = "201" ] || [ "${HTTP_CODE}" = "200" ]; then
    echo "  [created] ${scope_name}"
    scopes_created=$((scopes_created + 1))
  elif [ "${HTTP_CODE}" = "409" ]; then
    echo "  [skip] ${scope_name} (conflict)"
    scopes_skipped=$((scopes_skipped + 1))
  else
    echo "  [error] ${scope_name} — HTTP ${HTTP_CODE}"
  fi
done

echo "  Scopes — created: ${scopes_created}, skipped: ${scopes_skipped}"

# --- 2. Sync Resources ---
echo ""
echo "--- Syncing resources ---"

EXISTING_RESOURCES=$(curl -sS -X GET "${AUTHZ_BASE}/resource?max=500" \
  -H "Authorization: Bearer ${TOKEN}" | jq -r '.[].name')

resources_created=0
resources_skipped=0

for row in $(echo "${SOURCE_RESOURCES}" | jq -r '.[] | @base64'); do
  resource_json=$(echo "${row}" | base64 --decode)
  resource_name=$(echo "${resource_json}" | jq -r '.name')

  if echo "${EXISTING_RESOURCES}" | grep -qxF "${resource_name}"; then
    echo "  [skip] ${resource_name}"
    resources_skipped=$((resources_skipped + 1))
    continue
  fi

  payload=$(echo "${resource_json}" | jq '{name, type, ownerManagedAccess, attributes, uris, scopes: [.scopes[]? | {name}], icon_uri}')
  HTTP_CODE=$(curl -sS -o /dev/null -w "%{http_code}" -X POST "${AUTHZ_BASE}/resource" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "${payload}")

  if [ "${HTTP_CODE}" = "201" ] || [ "${HTTP_CODE}" = "200" ]; then
    echo "  [created] ${resource_name}"
    resources_created=$((resources_created + 1))
  elif [ "${HTTP_CODE}" = "409" ]; then
    echo "  [skip] ${resource_name} (conflict)"
    resources_skipped=$((resources_skipped + 1))
  else
    echo "  [error] ${resource_name} — HTTP ${HTTP_CODE}"
  fi
done

echo "  Resources — created: ${resources_created}, skipped: ${resources_skipped}"

# --- 3. Sync Policies (role-based, must precede permissions) ---
echo ""
echo "--- Syncing policies ---"

EXISTING_POLICIES=$(curl -sS -X GET "${AUTHZ_BASE}/policy?max=500&permission=false" \
  -H "Authorization: Bearer ${TOKEN}" | jq -r '.[].name')

policies_created=0
policies_skipped=0

for row in $(echo "${SOURCE_POLICIES}" | jq -r '.[] | @base64'); do
  policy_json=$(echo "${row}" | base64 --decode)
  policy_name=$(echo "${policy_json}" | jq -r '.name')

  if echo "${EXISTING_POLICIES}" | grep -qxF "${policy_name}"; then
    echo "  [skip] ${policy_name}"
    policies_skipped=$((policies_skipped + 1))
    continue
  fi

  # The config.roles field in realm export is a JSON string like:
  # "[{\"id\":\"cxo-engineering/Admin\",\"required\":true}]"
  # Convert to the API format: roles: [{id: "<role-name>", required: bool}]
  roles_str=$(echo "${policy_json}" | jq -r '.config.roles')
  roles_array=$(echo "${roles_str}" | jq '.')

  payload=$(echo "${policy_json}" | jq --argjson roles "${roles_array}" '{
    name,
    description,
    type: "role",
    logic,
    decisionStrategy,
    roles: $roles
  }')

  HTTP_CODE=$(curl -sS -o /dev/null -w "%{http_code}" -X POST "${AUTHZ_BASE}/policy/role" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "${payload}")

  if [ "${HTTP_CODE}" = "201" ] || [ "${HTTP_CODE}" = "200" ]; then
    echo "  [created] ${policy_name}"
    policies_created=$((policies_created + 1))
  elif [ "${HTTP_CODE}" = "409" ]; then
    echo "  [skip] ${policy_name} (conflict)"
    policies_skipped=$((policies_skipped + 1))
  else
    error_msg=$(curl -sS -X POST "${AUTHZ_BASE}/policy/role" \
      -H "Authorization: Bearer ${TOKEN}" \
      -H "Content-Type: application/json" \
      -d "${payload}" | jq -r '.errorMessage // .error // empty')
    echo "  [error] ${policy_name} — HTTP ${HTTP_CODE}: ${error_msg}"
  fi
done

echo "  Policies — created: ${policies_created}, skipped: ${policies_skipped}"

# --- 4. Sync Permissions (scope-based) ---
echo ""
echo "--- Syncing permissions ---"

# Refresh target state for ID resolution
TARGET_POLICIES_JSON=$(curl -sS -X GET "${AUTHZ_BASE}/policy?max=500&permission=false" \
  -H "Authorization: Bearer ${TOKEN}")
TARGET_RESOURCES_JSON=$(curl -sS -X GET "${AUTHZ_BASE}/resource?max=500" \
  -H "Authorization: Bearer ${TOKEN}")
TARGET_SCOPES_JSON=$(curl -sS -X GET "${AUTHZ_BASE}/scope?max=500" \
  -H "Authorization: Bearer ${TOKEN}")

EXISTING_PERMISSIONS=$(curl -sS -X GET "${AUTHZ_BASE}/permission?max=500" \
  -H "Authorization: Bearer ${TOKEN}" | jq -r '.[].name')

permissions_created=0
permissions_skipped=0
permissions_errors=0

for row in $(echo "${SOURCE_PERMISSIONS}" | jq -r '.[] | @base64'); do
  perm_json=$(echo "${row}" | base64 --decode)
  perm_name=$(echo "${perm_json}" | jq -r '.name')
  perm_type=$(echo "${perm_json}" | jq -r '.type')

  if echo "${EXISTING_PERMISSIONS}" | grep -qxF "${perm_name}"; then
    echo "  [skip] ${perm_name}"
    permissions_skipped=$((permissions_skipped + 1))
    continue
  fi

  # Resolve resource names from config to target IDs
  resources_str=$(echo "${perm_json}" | jq -r '.config.resources // "[]"')
  resource_names=$(echo "${resources_str}" | jq -r '.[]')
  target_resource_ids="[]"
  if [ -n "${resource_names}" ]; then
    target_resource_ids=$(echo "${TARGET_RESOURCES_JSON}" | jq --argjson names "${resources_str}" '
      [.[] | select(.name as $n | $names | index($n)) | ._id // .id]
    ')
  fi

  # Resolve scope names from config to target IDs
  scopes_str=$(echo "${perm_json}" | jq -r '.config.scopes // "[]"')
  target_scope_ids="[]"
  scope_names=$(echo "${scopes_str}" | jq -r '.[]' 2>/dev/null || true)
  if [ -n "${scope_names}" ]; then
    target_scope_ids=$(echo "${TARGET_SCOPES_JSON}" | jq --argjson names "${scopes_str}" '
      [.[] | select(.name as $n | $names | index($n)) | .id]
    ')
  fi

  # Resolve policy names from config to target IDs
  policies_str=$(echo "${perm_json}" | jq -r '.config.applyPolicies // "[]"')
  target_policy_ids="[]"
  policy_names=$(echo "${policies_str}" | jq -r '.[]' 2>/dev/null || true)
  if [ -n "${policy_names}" ]; then
    target_policy_ids=$(echo "${TARGET_POLICIES_JSON}" | jq --argjson names "${policies_str}" '
      [.[] | select(.name as $n | $names | index($n)) | .id]
    ')
  fi

  payload=$(jq -n \
    --arg name "${perm_name}" \
    --arg desc "$(echo "${perm_json}" | jq -r '.description // ""')" \
    --arg logic "$(echo "${perm_json}" | jq -r '.logic')" \
    --arg ds "$(echo "${perm_json}" | jq -r '.decisionStrategy')" \
    --argjson resources "${target_resource_ids}" \
    --argjson scopes "${target_scope_ids}" \
    --argjson policies "${target_policy_ids}" \
    '{
      name: $name,
      description: $desc,
      type: "scope",
      logic: $logic,
      decisionStrategy: $ds,
      resources: $resources,
      scopes: $scopes,
      policies: $policies
    }')

  HTTP_CODE=$(curl -sS -o /dev/null -w "%{http_code}" -X POST "${AUTHZ_BASE}/permission/scope" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "${payload}")

  if [ "${HTTP_CODE}" = "201" ] || [ "${HTTP_CODE}" = "200" ]; then
    echo "  [created] ${perm_name}"
    permissions_created=$((permissions_created + 1))
  elif [ "${HTTP_CODE}" = "409" ]; then
    echo "  [skip] ${perm_name} (conflict)"
    permissions_skipped=$((permissions_skipped + 1))
  else
    echo "  [error] ${perm_name} — HTTP ${HTTP_CODE}"
    permissions_errors=$((permissions_errors + 1))
  fi
done

echo "  Permissions — created: ${permissions_created}, skipped: ${permissions_skipped}, errors: ${permissions_errors}"

# --- Summary ---
echo ""
echo "=== Import Complete ==="
echo "  Target:      ${TARGET_URL} / ${REALM} / ${TARGET_CLIENT_ID}"
echo "  Scopes:      created=${scopes_created} skipped=${scopes_skipped}"
echo "  Resources:   created=${resources_created} skipped=${resources_skipped}"
echo "  Policies:    created=${policies_created} skipped=${policies_skipped}"
echo "  Permissions: created=${permissions_created} skipped=${permissions_skipped} errors=${permissions_errors}"
