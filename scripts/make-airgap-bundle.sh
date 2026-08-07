#!/usr/bin/env bash
# Build the offline/air-gap bundle for a release:
#
#   releases/bdp-airgap-<version>.tar.gz
#     IMPORT.md                    how to load everything inside the gap
#     import-bundle.sh             the only tool a site runs (needs crane+helm)
#     images/oci/<name>/           one OCI-layout dir per image (digest intact)
#     images/images-manifest.txt   <dir> <repo> <digest> <tag|->
#     charts/bdp-<version>.tgz     umbrella chart
#     charts/tools/*.tgz           tool charts from charts-manifest.txt
#     values-airgap.yaml.tpl       registry-swapped values (placeholder)
#     SHA256SUMS
#
# The image set is parsed from charts/bdp/values.yaml — by design the complete
# enumeration of every image the platform can pull (the cpa air-gap contract)
# — plus any digest-pinned extras in images/tools-manifest.txt.
#
# Usage: make-airgap-bundle.sh <version>
# Env:   ACR (default bdpmarketplace.azurecr.io), CRANE_OPTS
set -euo pipefail

VERSION="${1:?usage: make-airgap-bundle.sh <version>}"
ACR="${ACR:-bdpmarketplace.azurecr.io}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
VALUES="$ROOT/charts/bdp/values.yaml"
CRANE_OPTS="${CRANE_OPTS:-}"

BUNDLE="bdp-airgap-$VERSION"
OUT="$ROOT/releases/$BUNDLE"
rm -rf "$OUT"
mkdir -p "$OUT/images/oci" "$OUT/charts/tools"

echo "== Collecting image list from values.yaml"
# Every registry/image|repository/digest|sha block, normalized to
# "<repo> <sha256:digest> <tag|->", de-duplicated.
awk '
  /registry: bdpmarketplace\.azurecr\.io/ { inblk=1; repo=""; dig=""; tag="-"; next }
  inblk && /^[[:space:]]*(image|repository):/ { repo=$2 }
  inblk && /^[[:space:]]*tag:/     { tag=$2; gsub(/"/,"",tag) }
  inblk && /^[[:space:]]*(digest|sha):/ {
    dig=$2
    if (dig !~ /^sha256:/) dig="sha256:" dig
    if (repo != "" && dig ~ /^sha256:[0-9a-f]{64}$/ && !(seen[repo"@"dig]++))
      print repo, dig, tag
    inblk=0
  }
  inblk && !/^[[:space:]]*(#|$|image:|repository:|tag:|digest:|sha:)/ { inblk=0 }
' "$VALUES" > "$OUT/images/images-list.txt"

# digest-pinned extras from the tools manifest not already covered
grep -Eo '^tools/[^ ]+@sha256:[0-9a-f]{64}' "$ROOT/images/tools-manifest.txt" 2>/dev/null \
  | while IFS=@ read -r repo dig; do
      grep -q "^$repo $dig" "$OUT/images/images-list.txt" || echo "$repo $dig -"
    done >> "$OUT/images/images-list.txt" || true

n=$(wc -l < "$OUT/images/images-list.txt")
echo "   $n images"

echo "== Pulling images from $ACR as OCI layouts"
: > "$OUT/images/images-manifest.txt"
i=0
while read -r repo dig tag; do
  i=$((i+1))
  # dir must be unique per (repo, digest) — the same repo can ship two digests
  # (e.g. tools/k8s-sidecar 2.8.1 for grafana and 2.5.0 for loki), and an OCI
  # layout with two index entries is ambiguous for crane push
  dir="$(echo "$repo" | tr '/' '_')-$(echo "$dig" | cut -c8-19)"
  printf '   [%d/%d] %s@%s\n' "$i" "$n" "$repo" "${dig:0:19}..."
  # shellcheck disable=SC2086
  crane $CRANE_OPTS pull --format oci "$ACR/$repo@$dig" "$OUT/images/oci/$dir"
  printf '%s %s %s %s\n' "$dir" "$repo" "$dig" "$tag" >> "$OUT/images/images-manifest.txt"
done < "$OUT/images/images-list.txt"
rm "$OUT/images/images-list.txt"

echo "== Pulling tool charts"
grep -Ev '^\s*(#|$)' "$ROOT/charts/charts-manifest.txt" | while IFS=: read -r name ver; do
  echo "   charts/$name:$ver"
  helm pull "oci://$ACR/charts/$name" --version "$ver" -d "$OUT/charts/tools" \
    || echo "   WARNING: charts/$name:$ver not pulled — fix charts-manifest.txt" >&2
done

echo "== Packaging umbrella chart"
helm package "$ROOT/charts/bdp" -d "$OUT/charts" >/dev/null
ls "$OUT/charts"/bdp-*.tgz

echo "== Generating values template + import script"
"$HERE/gen-registry-values.sh" "__LOCAL_REGISTRY__" "$OUT/values-airgap.yaml.tpl"

cat > "$OUT/import-bundle.sh" <<'IMPORT_EOF'
#!/usr/bin/env bash
# Load this BDP air-gap bundle into a local registry, then print the install
# command. Needs: crane (>=0.19) and helm (>=3.14). For a plain-HTTP registry
# export CRANE_OPTS=--insecure HELM_OPTS=--plain-http (crane already speaks
# http to localhost without flags).
# Usage: import-bundle.sh <local-registry>     e.g. registry.corp.local:5000
set -euo pipefail
REG="${1:?usage: import-bundle.sh <local-registry>}"
cd "$(dirname "$0")"
CRANE_OPTS="${CRANE_OPTS:-}"
HELM_OPTS="${HELM_OPTS:-}"

echo "== Verifying checksums"
sha256sum -c SHA256SUMS --quiet

echo "== Pushing images"
while read -r dir repo dig tag; do
  # untagged entries get a digest-derived tag so two digests of the same repo
  # (e.g. tools/k8s-sidecar) don't fight over one tag; pods pull by digest
  [ "$tag" = "-" ] && tag="imported-$(echo "$dig" | cut -c8-19)"
  # shellcheck disable=SC2086
  crane $CRANE_OPTS push "images/oci/$dir" "$REG/$repo:$tag"
  got=$(crane $CRANE_OPTS digest "$REG/$repo:$tag")
  [ "$got" = "$dig" ] || { echo "FAIL: $repo digest $got != $dig" >&2; exit 1; }
  echo "   OK $repo:$tag @ ${dig:0:19}..."
done < images/images-manifest.txt

echo "== Pushing charts"
for tgz in charts/tools/*.tgz charts/bdp-*.tgz; do
  [ -e "$tgz" ] || continue
  # shellcheck disable=SC2086
  helm push $HELM_OPTS "$tgz" "oci://$REG/charts"
done

echo "== Generating values-airgap.yaml"
sed "s|__LOCAL_REGISTRY__|$REG|g" values-airgap.yaml.tpl > values-airgap.yaml

cat <<EOF

Done. Install with:

  helm install bdp charts/bdp-*.tgz -n bdp --create-namespace \\
    -f values-airgap.yaml \\
    --set global.externalDomain=<your-domain> \\
    --set sharedStorage.storageClass=<an-RWX-storageclass> \\
    --timeout 20m --wait

If the registry requires authentication, additionally set
  global.registryCredentials.create=true (registry/username/password) and
  global.imagePullSecrets[0].name=bdp-registry-cred
See IMPORT.md for TLS, storage and ingress notes.
EOF
IMPORT_EOF
chmod +x "$OUT/import-bundle.sh"

cat > "$OUT/IMPORT.md" <<EOF
# BDP air-gap bundle $VERSION

Everything a disconnected site needs to run the BDP platform: all container
images as OCI layouts (digests identical to the release pins), the umbrella
Helm chart, the tool charts, and an import script.

## Prerequisites inside the gap
- a container registry reachable by the cluster's kubelets
  (for testing: \`docker run -d -p 5000:5000 registry:2\`)
- \`crane\` >= 0.19 and \`helm\` >= 3.14 on the machine doing the import
- a Kubernetes cluster with a default StorageClass, an RWX-capable
  StorageClass if shared tool storage is wanted, and an ingress controller

## Import
    ./import-bundle.sh <local-registry>

The script verifies SHA256SUMS, pushes every image (asserting the digest
survived), pushes the charts as OCI artifacts to oci://<registry>/charts,
renders values-airgap.yaml, and prints the install command.

## Notes
- Plain-HTTP registry: \`export CRANE_OPTS=--insecure\` before importing, and
  the cluster's container runtime must trust the insecure registry.
- Private registry: create the pull secret via
  \`global.registryCredentials.create=true\` + list it in
  \`global.imagePullSecrets\` (see the chart's values.yaml comments); loki
  additionally needs \`loki.imagePullSecrets\`, alloy
  \`alloy.global.image.pullSecrets\`.
- Storage: \`sharedStorage.storageClass\` must name a real RWX class or set
  \`sharedStorage.enabled=false\`; never set it to "" (that disables dynamic
  provisioning). \`global.storageClass\` overrides the platform PVC class.
- Ingress: install ingress-nginx (no cloud annotations needed on-prem; add
  MetalLB or equivalent for a LoadBalancer IP on bare metal). If pods cannot
  reach the external Keycloak host through the LB (no hairpin), set
  \`global.keycloakHostAliasIp\` to the ingress controller's ClusterIP.
- values-airgap.yaml also sets global.airgapRegistry, so tools provisioned at
  runtime pull their charts and images from your local registry as well.
EOF

echo "== Checksums + tarball"
( cd "$OUT" && find . -type f ! -name SHA256SUMS -print0 | xargs -0 sha256sum > SHA256SUMS )
tar -C "$ROOT/releases" -czf "$ROOT/releases/$BUNDLE.tar.gz" "$BUNDLE"
du -h "$ROOT/releases/$BUNDLE.tar.gz" | cut -f1 | xargs echo "OK: releases/$BUNDLE.tar.gz"
