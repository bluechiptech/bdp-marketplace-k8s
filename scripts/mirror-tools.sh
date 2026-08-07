#!/usr/bin/env bash
# Mirror the third-party tools/* images listed in images/tools-manifest.txt
# into a target registry with `crane cp` — digest-preserving, so the sha256
# pins in charts/bdp/values.yaml stay valid in the mirror.
#
# Default mode copies from the marketplace ACR (the registry of record).
# --from-upstream instead copies from the public upstream refs in column 2 —
# the reproducible, registry-agnostic replacement for the old undocumented
# `az acr import` procedure (works for populating ACR itself too). NOTE that
# upstream tags can move; the ACR->target mode is what guarantees the exact
# pinned digests, which is why it is the default.
#
# Usage: mirror-tools.sh [--from-upstream] <target-registry>
#   e.g. mirror-tools.sh ghcr.io/bluechiptech
# Env:  ACR   source registry for the default mode (default bdpmarketplace.azurecr.io)
#       CRANE_OPTS   extra flags for every crane call (e.g. --insecure)
set -euo pipefail

FROM_UPSTREAM=0
if [ "${1:-}" = "--from-upstream" ]; then FROM_UPSTREAM=1; shift; fi
TARGET="${1:?usage: mirror-tools.sh [--from-upstream] <target-registry>}"
SRC_REG="${ACR:-bdpmarketplace.azurecr.io}"
HERE="$(cd "$(dirname "$0")" && pwd)"
MANIFEST="$HERE/../images/tools-manifest.txt"
CRANE_OPTS="${CRANE_OPTS:-}"

fail=0
while read -r ref upstream; do
  case "$ref" in ''|\#*) continue ;; esac

  if [ "$FROM_UPSTREAM" = 1 ]; then
    src="$upstream"
  else
    src="$SRC_REG/$ref"
  fi

  case "$ref" in
    *@sha256:*)
      # digest-pinned entry: give the copy a derived tag so it is browsable
      repo="${ref%%@*}"; dig="${ref##*@}"
      dst="$TARGET/$repo:mirror-$(echo "$dig" | cut -c8-19)"
      ;;
    *)
      dst="$TARGET/$ref"
      ;;
  esac

  echo "== $src -> $dst"
  # shellcheck disable=SC2086
  crane $CRANE_OPTS cp "$src" "$dst"
  s="$(crane $CRANE_OPTS digest "$src")"
  d="$(crane $CRANE_OPTS digest "$dst")"
  if [ "$s" != "$d" ]; then
    echo "FAIL: digest mismatch for $ref ($s vs $d)" >&2
    fail=1
  fi
done < "$MANIFEST"

[ "$fail" = 0 ] || exit 1
echo "OK: tools/* mirrored to $TARGET with digests preserved"
