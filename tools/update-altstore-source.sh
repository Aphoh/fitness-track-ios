#!/usr/bin/env bash
#
# update-altstore-source.sh <version> <build-number> <download-url> <size-bytes> [source.json]
#
# Prepends a release to altstore-source.json (AltStore / SideStore source format). Re-running for
# the same version replaces its entry, so it is idempotent. Also mirrors the app-level legacy
# fields that older AltStore clients read.
set -euo pipefail

VER="${1:?usage: $0 <version> <build-number> <download-url> <size-bytes> [source.json]}"
BUILD="${2:?}"; URL="${3:?}"; SIZE="${4:?}"
SRC="${5:-$(cd "$(dirname "$0")/.." && pwd)/altstore-source.json}"
DATE="${RELEASE_DATE:-$(date -u +%Y-%m-%d)}"
DESC="FitnessTrack ${VER}. See the GitHub release notes for what changed."

command -v jq >/dev/null || { echo "✗ jq is required" >&2; exit 1; }
[ -f "$SRC" ] || { echo "✗ $SRC not found" >&2; exit 1; }
[[ "$SIZE" =~ ^[0-9]+$ ]] || { echo "✗ size must be a byte count, got '$SIZE'" >&2; exit 1; }

tmp="$(mktemp)"
jq --arg v "$VER" --arg b "$BUILD" --arg d "$DATE" --arg desc "$DESC" \
   --arg url "$URL" --argjson size "$SIZE" '
  (.apps[0].minOSVersion // "17.0") as $min
  | .apps[0].versions = ([{
      version: $v, buildVersion: $b, date: $d, localizedDescription: $desc,
      downloadURL: $url, size: $size, minOSVersion: $min
    }] + ((.apps[0].versions // []) | map(select(.version != $v))))
  | .apps[0].version            = $v
  | .apps[0].buildVersion       = $b
  | .apps[0].versionDate        = $d
  | .apps[0].versionDescription = $desc
  | .apps[0].downloadURL        = $url
  | .apps[0].size               = $size
' "$SRC" > "$tmp"
mv "$tmp" "$SRC"
echo "✓ $(basename "$SRC"): FitnessTrack $VER (build $BUILD), $SIZE bytes"
