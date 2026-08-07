#!/usr/bin/env bash
# Pin freshly built image digests into charts/bdp/values.yaml.
#
# Reads a digests file of lines "<repo> <sha256:...>" (as written by
# scripts/release.sh step 2, e.g. "bdp/bdp-auth-service sha256:ab..."), then
# rewrites the digest under EVERY block in values.yaml whose image/repository
# is that repo — the global.azure.images entries and any subchart override
# block alike (seed and emit both point at bdp/bdp-seed and both get updated).
# Finally bumps the display-only global.bdpImageTag to <version>.
#
# Fails hard if the digests file yields no valid pins or any pinned repo was
# not found in values.yaml. The edit is deliberately left uncommitted: review
# it with `git diff charts/bdp/values.yaml` — this replaces the old manual
# "pin in the chart" step of the publish procedure.
#
# Usage: pin-digests.sh <digests-file> <version>
set -euo pipefail

DIGESTS="${1:?usage: pin-digests.sh <digests-file> <version>}"
VERSION="${2:?usage: pin-digests.sh <digests-file> <version>}"
HERE="$(cd "$(dirname "$0")" && pwd)"
VALUES="$HERE/../charts/bdp/values.yaml"

[ -s "$DIGESTS" ] || { echo "ERROR: $DIGESTS missing or empty" >&2; exit 1; }

trap 'rm -f "$VALUES.tmp"' EXIT

# Path passed via the environment, NOT `awk -v` — -v runs escape-sequence
# processing on the value, which corrupts Windows-style paths (backslashes).
DIGESTS_FILE="$DIGESTS" awk '
BEGIN {
  digests = ENVIRON["DIGESTS_FILE"]
  loaded = 0
  while ((getline line < digests) > 0) {
    if (split(line, a, " ") == 2 && a[2] ~ /^sha256:[0-9a-f]{64}$/) { pin[a[1]] = a[2]; loaded++ }
  }
  close(digests)
  if (loaded == 0) { print "ERROR: no valid \"<repo> sha256:...\" lines in " digests > "/dev/stderr"; bad = 1; exit 2 }
  repo = ""
}
{
  # an image/repository line names the repo the NEXT digest line belongs to
  if (match($0, /^ *(image|repository): */)) {
    repo = $0
    sub(/^ *(image|repository): */, "", repo)
    sub(/ *(#.*)?$/, "", repo)
  } else if (repo != "" && (repo in pin) && match($0, /^( *)digest: sha256:[0-9a-f]{64} *$/)) {
    indent = $0
    sub(/digest:.*/, "", indent)
    $0 = indent "digest: " pin[repo]
    replaced[repo]++
    repo = ""
  } else if ($0 !~ /^ *(tag|sha|digest):/ && $0 !~ /^ *#/ && $0 !~ /^ *$/) {
    # any other content line ends the block
    repo = ""
  }
  print
}
END {
  if (bad) exit 2
  missing = 0
  for (r in pin) if (!(r in replaced)) {
    printf "ERROR: no digest line found for %s in values.yaml\n", r > "/dev/stderr"
    missing = 1
  }
  if (missing) exit 3
  printf "pinned %d repos\n", length(replaced) > "/dev/stderr"
}
' "$VALUES" > "$VALUES.tmp"

# display-only release marker
sed -i "s/^  bdpImageTag: \".*\"/  bdpImageTag: \"$VERSION\"/" "$VALUES.tmp"

mv "$VALUES.tmp" "$VALUES"
echo "OK: digests pinned, bdpImageTag=$VERSION"
echo "Review with: git diff charts/bdp/values.yaml"
