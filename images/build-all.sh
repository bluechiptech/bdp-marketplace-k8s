#!/usr/bin/env bash
# Build and push every BDP image from the staged dist/ tree.
# Usage: build-all.sh <registry-prefix> <version>
#   e.g. build-all.sh myacr.azurecr.io/bdp 1.0.0
set -euo pipefail
REGISTRY="${1:?usage: build-all.sh <registry-prefix> <version>}"
VERSION="${2:?usage: build-all.sh <registry-prefix> <version>}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

[ -d "$ROOT/dist/lib" ] || { echo "ERROR: run collect-artifacts.sh first (dist/ missing)"; exit 1; }

SERVICES=$(ls "$ROOT/dist/lib" | sed 's/\.jar$//')

for svc in $SERVICES; do
  echo "== $svc =="
  if [ "$svc" = "bdp-provisioner" ]; then
    # provisioner ships the helm CLI for data-tool installs
    docker build -f "$HERE/Dockerfile.provisioner" -t "$REGISTRY/$svc:$VERSION" "$ROOT"
  else
    docker build -f "$HERE/Dockerfile.service" --build-arg SERVICE="$svc" \
      -t "$REGISTRY/$svc:$VERSION" "$ROOT"
  fi
  docker push "$REGISTRY/$svc:$VERSION"
done

echo "== bdp-ui =="
docker build -f "$HERE/Dockerfile.ui" -t "$REGISTRY/bdp-ui:$VERSION" "$ROOT"
docker push "$REGISTRY/bdp-ui:$VERSION"

echo "== bdp-seed =="
docker build -f "$HERE/Dockerfile.seed" -t "$REGISTRY/bdp-seed:$VERSION" "$ROOT"
docker push "$REGISTRY/bdp-seed:$VERSION"

echo "OK: $(echo "$SERVICES" | wc -w) services + ui + seed pushed to $REGISTRY @ $VERSION"
