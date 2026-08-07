#!/usr/bin/env bash
# Verify a registry-swapped render of charts/bdp:
#   1. zero azurecr.io references remain anywhere in the rendered manifests;
#   2. the rendered image set is EXACTLY the default render's image set with
#      the registry prefix swapped — same repository paths, same digests.
# Used by scripts/release.sh after generating the values file, and standalone.
#
# Usage: verify-render.sh <registry> [values-file]
#   e.g. verify-render.sh ghcr.io/bluechiptech charts/bdp/values-ghcr.yaml
# When values-file is omitted it is generated on the fly.
set -euo pipefail

REG="${1:?usage: verify-render.sh <registry> [values-file]}"
VALUES="${2:-}"
HERE="$(cd "$(dirname "$0")" && pwd)"
CHART="$HERE/../charts/bdp"
ACR_HOST="bdpmarketplace.azurecr.io"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [ -z "$VALUES" ]; then
  VALUES="$TMP/values-swapped.yaml"
  "$HERE/gen-registry-values.sh" "$REG" "$VALUES"
fi

helm template bdp "$CHART" > "$TMP/default.yaml"
helm template bdp "$CHART" -f "$VALUES" > "$TMP/swapped.yaml"

if grep -n 'azurecr\.io' "$TMP/swapped.yaml"; then
  echo "FAIL: azurecr.io references remain in the swapped render (above)" >&2
  exit 1
fi
echo "OK: no azurecr.io references in the swapped render"

# image: lines only, quotes stripped, sorted unique
extract_images() {
  grep -E '^\s*(- )?image: ' "$1" | sed -E 's/^\s*(- )?image: *"?([^" ]+)"?.*/\2/' | sort -u
}
extract_images "$TMP/default.yaml" | sed "s|$ACR_HOST|$REG|g" > "$TMP/expected.txt"
extract_images "$TMP/swapped.yaml" > "$TMP/actual.txt"

if ! diff -u "$TMP/expected.txt" "$TMP/actual.txt"; then
  echo "FAIL: swapped render's images are not a pure registry-prefix swap of the default render" >&2
  exit 1
fi
echo "OK: $(wc -l < "$TMP/actual.txt") images differ from the default render only in registry prefix"
