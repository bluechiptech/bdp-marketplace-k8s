#!/usr/bin/env bash
# One-command portable release: build once, publish everywhere.
#
#   1. build + push the 24 platform images to the ACR (unchanged build path:
#      images/build-all.sh, exactly the documented marketplace procedure)
#   2. record the pushed digests
#   3. (--pin) pin those digests into charts/bdp/values.yaml + bump bdpImageTag
#   4. crane cp every platform image, the mirrored bitnami trio and the
#      tools/* images to the second registry (digest-preserving, so ONE set of
#      digest pins is valid in ACR, GHCR and every air-gapped mirror)
#   5. mirror the tool charts (OCI artifacts) and push the umbrella chart
#   6. regenerate charts/bdp/values-ghcr.yaml and verify the swapped render
#   7. (unless --skip-bundle) emit the offline/air-gap bundle
#
# Usage: release.sh [flags] <version>          e.g. release.sh --pin 1.0.7
# Flags: --skip-build   images already in the ACR at <version>
#        --pin          rewrite digests in values.yaml (review via git diff)
#        --skip-ghcr    ACR-only release (steps 4-6 skipped)
#        --skip-bundle  no offline bundle
#        --refresh-manifests  refresh images/tools-manifest.txt + charts/
#                       charts-manifest.txt repo lists from the ACR, then exit
# Env:   ACR    (default bdpmarketplace.azurecr.io)
#        GHCR   (default ghcr.io/bluechiptech)
#        GHCR_USER / GHCR_TOKEN   GHCR credentials (token: write:packages)
#
# NOTE: the first push to GHCR creates PRIVATE packages. Make bdp-*, tools/*
# and charts/* public in the GitHub org's package settings, or install with
# global.registryCredentials/global.imagePullSecrets (see docs/INSTALL-GENERIC.md).
set -euo pipefail

ACR="${ACR:-bdpmarketplace.azurecr.io}"
GHCR="${GHCR:-ghcr.io/bluechiptech}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
VALUES="$ROOT/charts/bdp/values.yaml"

SKIP_BUILD=0 PIN=0 SKIP_GHCR=0 SKIP_BUNDLE=0 REFRESH=0
VERSION=""
for arg in "$@"; do
  case "$arg" in
    --skip-build)  SKIP_BUILD=1 ;;
    --pin)         PIN=1 ;;
    --skip-ghcr)   SKIP_GHCR=1 ;;
    --skip-bundle) SKIP_BUNDLE=1 ;;
    --refresh-manifests) REFRESH=1 ;;
    -*) echo "unknown flag $arg" >&2; exit 1 ;;
    *) VERSION="$arg" ;;
  esac
done

log() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

acr_name="${ACR%%.*}"

refresh_manifests() {
  log "Refreshing manifests from $ACR"
  command -v az >/dev/null || { echo "ERROR: az CLI required for --refresh-manifests" >&2; exit 1; }
  echo "-- repos under tools/ (merge into images/tools-manifest.txt by hand where new):"
  az acr repository list -n "$acr_name" -o tsv | grep '^tools/' | while read -r repo; do
    tags=$(az acr repository show-tags -n "$acr_name" --repository "$repo" -o tsv | tr '\n' ',' | sed 's/,$//')
    printf '  %-45s tags: %s\n' "$repo" "${tags:-<none>}"
  done
  echo "-- repos under charts/ (merge into charts/charts-manifest.txt):"
  az acr repository list -n "$acr_name" -o tsv | grep '^charts/' | while read -r repo; do
    tags=$(az acr repository show-tags -n "$acr_name" --repository "$repo" -o tsv | tr '\n' ',' | sed 's/,$//')
    printf '  %-45s versions: %s\n' "${repo#charts/}" "${tags:-<none>}"
  done
  echo "Compare the output against the two manifest files and commit the updates."
}

if [ "$REFRESH" = 1 ]; then refresh_manifests; exit 0; fi

[ -n "$VERSION" ] || { echo "usage: release.sh [flags] <version>" >&2; exit 1; }

log "Preflight"
for tool in docker helm crane az; do
  command -v "$tool" >/dev/null || { echo "ERROR: $tool not found on PATH" >&2; exit 1; }
done
az acr login -n "$acr_name"
if [ "$SKIP_GHCR" = 0 ]; then
  : "${GHCR_USER:?set GHCR_USER}" "${GHCR_TOKEN:?set GHCR_TOKEN (write:packages)}"
  ghcr_host="${GHCR%%/*}"
  echo "$GHCR_TOKEN" | crane auth login "$ghcr_host" -u "$GHCR_USER" --password-stdin
  echo "$GHCR_TOKEN" | helm registry login "$ghcr_host" -u "$GHCR_USER" --password-stdin
fi

# The bdp/* repos this release builds: everything under dist/lib + ui + seed
if [ -d "$ROOT/dist/lib" ]; then
  BDP_REPOS=$(ls "$ROOT/dist/lib" | sed 's/\.jar$//;s|^|bdp/|'; echo "bdp/bdp-ui"; echo "bdp/bdp-seed")
else
  # dist/ absent (e.g. --skip-build on a fresh checkout): fall back to the
  # bdp/bdp-* repos pinned in values.yaml
  BDP_REPOS=$(grep -Eo 'image: bdp/[a-z0-9-]+' "$VALUES" | sed 's/^image: //' | sort -u | grep '^bdp/bdp-')
  [ "$SKIP_BUILD" = 1 ] || { echo "ERROR: dist/lib missing — run collect-artifacts.sh first" >&2; exit 1; }
fi

RELDIR="$ROOT/releases/$VERSION"
mkdir -p "$RELDIR"

if [ "$SKIP_BUILD" = 0 ]; then
  log "Step 1: build + push to $ACR (documented marketplace procedure)"
  "$ROOT/images/build-all.sh" "$ACR/bdp" "$VERSION"
fi

log "Step 2: record digests -> releases/$VERSION/digests.txt"
: > "$RELDIR/digests.txt"
for repo in $BDP_REPOS; do
  dig=$(crane digest "$ACR/$repo:$VERSION")
  printf '%s %s\n' "$repo" "$dig" | tee -a "$RELDIR/digests.txt"
done

if [ "$PIN" = 1 ]; then
  log "Step 3: pin digests into charts/bdp/values.yaml"
  "$HERE/pin-digests.sh" "$RELDIR/digests.txt" "$VERSION"
fi

if [ "$SKIP_GHCR" = 0 ]; then
  log "Step 4a: copy platform images $ACR -> $GHCR (digest-preserving)"
  while read -r repo dig; do
    crane cp "$ACR/$repo:$VERSION" "$GHCR/$repo:$VERSION"
    [ "$(crane digest "$GHCR/$repo:$VERSION")" = "$dig" ] \
      || { echo "FAIL: digest changed copying $repo" >&2; exit 1; }
  done < "$RELDIR/digests.txt"

  log "Step 4b: copy the re-hosted bitnami images at their pinned digests"
  for repo in bdp/postgresql bdp/redis bdp/keycloak; do
    dig=$(awk -v r="$repo" '$0 ~ "image: "r"$" {f=1; next} f && /digest:/ {print $2; exit}' "$VALUES")
    [ -n "$dig" ] || { echo "FAIL: no digest for $repo in values.yaml" >&2; exit 1; }
    crane cp "$ACR/$repo@$dig" "$GHCR/$repo:mirror-$(echo "$dig" | cut -c8-19)"
  done

  log "Step 4c: mirror tools/* images"
  ACR="$ACR" "$HERE/mirror-tools.sh" "$GHCR"

  log "Step 5: mirror tool charts + push umbrella chart"
  grep -Ev '^\s*(#|$)' "$ROOT/charts/charts-manifest.txt" | while IFS=: read -r name ver; do
    crane cp "$ACR/charts/$name:$ver" "$GHCR/charts/$name:$ver"
  done
  "$HERE/gen-registry-values.sh" "$GHCR" "$ROOT/charts/bdp/values-ghcr.yaml"
  pkgdir=$(mktemp -d)
  helm package "$ROOT/charts/bdp" -d "$pkgdir" >/dev/null
  tgz=$(ls "$pkgdir"/bdp-*.tgz)
  helm push "$tgz" "oci://$GHCR/charts"
  helm push "$tgz" "oci://$ACR/charts"
  rm -rf "$pkgdir"

  log "Step 6: verify swapped render"
  "$HERE/verify-render.sh" "$GHCR" "$ROOT/charts/bdp/values-ghcr.yaml"
fi

if [ "$SKIP_BUNDLE" = 0 ]; then
  log "Step 7: offline bundle"
  ACR="$ACR" "$HERE/make-airgap-bundle.sh" "$VERSION"
fi

log "Release $VERSION done"
echo "  digests: releases/$VERSION/digests.txt"
[ "$SKIP_GHCR" = 0 ]   && echo "  ghcr:    $GHCR/bdp/*:$VERSION (+ tools/*, charts/*)"
[ "$SKIP_BUNDLE" = 0 ] && echo "  bundle:  releases/bdp-airgap-$VERSION.tar.gz"
[ "$PIN" = 1 ]         && echo "  REVIEW:  git diff charts/bdp/values.yaml (pinned digests) and commit"
exit 0
