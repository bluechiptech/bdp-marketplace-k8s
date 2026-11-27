#!/usr/bin/env bash
# bdp-tools-fixer: repairs, automatically, the data-tool install problems that
# were fixed by hand on the MTN install (2026-11-26). Data tools (MinIO,
# Iceberg, ...) are installed LATER from the BDP UI by bdp-service-manager,
# not by this chart, so the fixes cannot be one-off install steps -- this runs
# on a schedule and acts only when it finds something to fix. Every task is
# idempotent and independent: one failing never stops the others.
#
#   1. Copy the registry pull secret into the tools namespace.
#   2. Attach it to every ServiceAccount there (service-manager never adds
#      imagePullSecrets to tool charts, so every tool image from the private
#      registry went ImagePullBackOff), and restart pods stuck pulling.
#   3. Rewrite images whose public registry is gone (MinIO removed quay.io and
#      Docker Hub images) to the mirror -- deployments, statefulsets, and
#      unfinished jobs (job pod templates are immutable: recreated).
#   4. MinIO: make sure the platform's access key (bdp-platform-secrets, used
#      by storage-manager, service-manager, catalog, ...) exists as a MinIO
#      user, and that the Iceberg "warehouse" bucket exists.
#   5. Lakekeeper (Apache Iceberg): create the warehouse when missing. The
#      platform only does this while configuring Trino, so without Trino the
#      Iceberg page showed "Failed to load tables".
#
# Env (set by templates/tools-fixer.yaml): TOOLS_NS, PULL_SECRET, REWRITES
# (JSON map prefix -> replacement), MINIO_ACCESS_KEY, MINIO_SECRET_KEY,
# MINIO_POD_LABEL, MINIO_ENDPOINT, LK_SERVICE, LK_PORT, LK_WAREHOUSE,
# LK_BUCKET, KC_URL
set -uo pipefail
export PATH="/tools:$PATH"
NS="$TOOLS_NS"
k() { kubectl -n "$NS" "$@"; }
log() { echo "[$(date +%H:%M:%S)] $*"; }

# jq: rewrite an image whose prefix (followed by : or @) is in $m.
JQ_RW='def rw($m): . as $img
  | ([$m | to_entries[] | select(($img | startswith(.key + ":")) or ($img | startswith(.key + "@")))] | first) as $e
  | if $e then $e.value + $img[($e.key | length):] else $img end;'

# ── 1. pull secret into the tools namespace ─────────────────────────────
task_pull_secret() {
  [[ -n "$PULL_SECRET" && -s /pull/.dockerconfigjson ]] || return 0
  kubectl create secret generic "$PULL_SECRET" -n "$NS" \
    --type=kubernetes.io/dockerconfigjson \
    --from-file=.dockerconfigjson=/pull/.dockerconfigjson \
    --dry-run=client -o json | k apply -f - >/dev/null \
    && log "pull secret $PULL_SECRET present in $NS"
}

# ── 2. attach it to every ServiceAccount; restart stuck pods ────────────
task_service_accounts() {
  [[ -n "$PULL_SECRET" ]] || return 0
  k get sa -o json | jq -c --arg ps "$PULL_SECRET" '.items[]
      | select([.imagePullSecrets[]?.name] | index($ps) | not)
      | {name: .metadata.name, ips: ((.imagePullSecrets // []) + [{name: $ps}])}' \
  | while read -r sa; do
      name=$(jq -r .name <<<"$sa")
      k patch sa "$name" --type=merge -p "$(jq -c '{imagePullSecrets: .ips}' <<<"$sa")" >/dev/null \
        && log "serviceaccount $name: added $PULL_SECRET"
    done
  # Pods that failed to pull before their ServiceAccount had the secret keep
  # failing until recreated. Only controller-owned pods (they come back).
  k get pods -o json | jq -r --arg ps "$PULL_SECRET" '.items[]
      | select(.metadata.ownerReferences != null)
      | select([.status.containerStatuses[]?, .status.initContainerStatuses[]?
                | .state.waiting.reason // ""] | any(. == "ImagePullBackOff" or . == "ErrImagePull"))
      | select([.spec.imagePullSecrets[]?.name] | index($ps) | not)
      | .metadata.name' \
  | while read -r pod; do
      k delete pod "$pod" --wait=false >/dev/null && log "restarted $pod (stuck pulling, had no pull secret)"
    done
}

# ── 3. image rewrites ───────────────────────────────────────────────────
task_rewrite_images() {
  [[ "$REWRITES" != "{}" ]] || return 0
  k get deploy,sts -o json | jq -r --argjson m "$REWRITES" "$JQ_RW"'
      .items[] | . as $w
      | (.spec.template.spec.containers + (.spec.template.spec.initContainers // []))[]
      | select(.image != (.image | rw($m)))
      | "\($w.kind | ascii_downcase)/\($w.metadata.name) \(.name)=\(.image | rw($m))"' \
  | while read -r res pair; do
      k set image "$res" "$pair" >/dev/null && log "$res: image -> ${pair#*=}"
      if [[ -n "$PULL_SECRET" ]]; then
        k patch "$res" -p "{\"spec\":{\"template\":{\"spec\":{\"imagePullSecrets\":[{\"name\":\"$PULL_SECRET\"}]}}}}" >/dev/null
      fi
    done
  # Jobs: only unfinished ones whose image needs rewriting -> recreate.
  k get jobs -o json | jq -r --argjson m "$REWRITES" "$JQ_RW"'
      .items[]
      | select(([.status.conditions[]? | select(.type == "Complete" and .status == "True")] | length) == 0)
      | select([(.spec.template.spec.containers + (.spec.template.spec.initContainers // []))[]
                | select(.image != (.image | rw($m)))] | length > 0)
      | .metadata.name' \
  | while read -r job; do
      spec=$(k get job "$job" -o json | jq -c --argjson m "$REWRITES" --arg ps "$PULL_SECRET" "$JQ_RW"'
          def nolabels: (. // {}) | with_entries(select(.key | test("controller-uid|job-name") | not));
          del(.metadata.uid, .metadata.resourceVersion, .metadata.creationTimestamp,
              .metadata.managedFields, .metadata.generation, .status, .spec.selector)
          | .metadata.labels |= nolabels
          | .spec.template.metadata.labels |= nolabels
          | .spec.template.spec.containers |= map(.image |= rw($m))
          | if .spec.template.spec.initContainers then .spec.template.spec.initContainers |= map(.image |= rw($m)) else . end
          | if $ps != "" then .spec.template.spec.imagePullSecrets =
              (((.spec.template.spec.imagePullSecrets // []) + [{name: $ps}]) | unique_by(.name)) else . end') || continue
      k delete job "$job" --wait=true >/dev/null \
        && echo "$spec" | k create -f - >/dev/null \
        && log "job $job recreated with mirrored images"
    done
}

# ── 4. MinIO platform user + warehouse bucket ───────────────────────────
MINIO_OK=0
task_minio() {
  [[ -n "${MINIO_ACCESS_KEY:-}" && -n "${MINIO_SECRET_KEY:-}" ]] || return 0
  local pod
  pod=$(k get pods -l "$MINIO_POD_LABEL" --field-selector=status.phase=Running \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  [[ -n "$pod" ]] || return 0
  # Credentials go in on stdin, never on a command line (ps would show them).
  k exec -i "$pod" -- sh -s <<EOF >/dev/null 2>&1 || { log "minio: could not reach mc in $pod"; return 0; }
set -e
mc alias set local http://localhost:9000 "\$MINIO_ROOT_USER" "\$MINIO_ROOT_PASSWORD"
if ! mc admin user info local '$MINIO_ACCESS_KEY'; then
  mc admin user add local '$MINIO_ACCESS_KEY' '$MINIO_SECRET_KEY'
fi
mc admin policy attach local consoleAdmin --user '$MINIO_ACCESS_KEY' || true
mc mb --ignore-existing local/$LK_BUCKET
EOF
  MINIO_OK=1
  log "minio: platform user and bucket $LK_BUCKET ensured"
}

# ── 5. Lakekeeper warehouse ─────────────────────────────────────────────
task_lakekeeper() {
  [[ "$MINIO_OK" == 1 ]] || return 0
  k get svc "$LK_SERVICE" >/dev/null 2>&1 || return 0
  local lk="http://$LK_SERVICE.$NS.svc.cluster.local:$LK_PORT" auth=() code body
  code=$(curl -s -m 15 -o /tmp/wh.json -w '%{http_code}' "$lk/management/v1/warehouse")
  if [[ "$code" == 401 ]]; then
    # Newer builds turn on OIDC for Lakekeeper; use its service account.
    local tok
    tok=$(curl -s -m 15 "$KC_URL/realms/bdp/protocol/openid-connect/token" \
          -d grant_type=client_credentials -d client_id=bdp-lakekeeper \
          -d client_secret=bdp-lakekeeper-secret | jq -r '.access_token // empty')
    [[ -n "$tok" ]] || { log "lakekeeper: needs a token and none could be obtained"; return 0; }
    auth=(-H "Authorization: Bearer $tok")
    code=$(curl -s -m 15 "${auth[@]}" -o /tmp/wh.json -w '%{http_code}' "$lk/management/v1/warehouse")
  fi
  if [[ "$code" == 200 ]] && jq -e --arg w "$LK_WAREHOUSE" '[.warehouses[]?.name] | index($w)' /tmp/wh.json >/dev/null; then
    return 0
  fi
  # Not bootstrapped yet answers 4xx/5xx on the list; bootstrap is a no-op
  # (409) when already done.
  curl -s -m 15 "${auth[@]}" -o /dev/null -X POST "$lk/management/v1/bootstrap" \
    -H 'Content-Type: application/json' -d '{"accept-terms-of-use":true}'
  body=$(jq -n --arg w "$LK_WAREHOUSE" --arg b "$LK_BUCKET" --arg e "$MINIO_ENDPOINT" \
              --arg ak "$MINIO_ACCESS_KEY" --arg sk "$MINIO_SECRET_KEY" '{
    "warehouse-name": $w,
    "storage-profile": {type: "s3", bucket: $b, region: "us-east-1", "path-style-access": true,
                        endpoint: $e, flavor: "minio", "sts-enabled": false},
    "storage-credential": {type: "s3", "credential-type": "access-key",
                           "aws-access-key-id": $ak, "aws-secret-access-key": $sk}}')
  code=$(curl -s -m 30 "${auth[@]}" -o /tmp/create.json -w '%{http_code}' -X POST \
         "$lk/management/v1/warehouse" -H 'Content-Type: application/json' -d "$body")
  case "$code" in
    2*)  log "lakekeeper: created warehouse $LK_WAREHOUSE" ;;
    409) ;;
    *)   log "lakekeeper: warehouse create returned HTTP $code: $(head -c 300 /tmp/create.json)" ;;
  esac
}

task_pull_secret
task_service_accounts
task_rewrite_images
task_minio
task_lakekeeper
exit 0
