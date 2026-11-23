#!/usr/bin/env bash
#
# update-altstore-source.sh <version> <build-number> <download-url> <size-bytes> [source.json]
#
# Adds a release to altstore-source.json (AltStore / SideStore source format), keeping versions
# newest-first. Re-running for the same version replaces its entry, so it is idempotent. The
# app-level legacy fields that older AltStore clients read always mirror the newest version.
set -euo pipefail

VER="${1:?usage: $0 <version> <build-number> <download-url> <size-bytes> [source.json]}"
BUILD="${2:?}"; URL="${3:?}"; SIZE="${4:?}"
SRC="${5:-$(cd "$(dirname "$0")/.." && pwd)/altstore-source.json}"
DATE="${RELEASE_DATE:-$(date -u +%Y-%m-%d)}"
DESC="FitnessTrack ${VER}. See the GitHub release notes for what changed."

[[ "$VER" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || { echo "✗ version must be MAJOR[.MINOR[.PATCH]], got '$VER'" >&2; exit 1; }
command -v jq >/dev/null || { echo "✗ jq is required" >&2; exit 1; }
[ -f "$SRC" ] || { echo "✗ $SRC not found" >&2; exit 1; }
[[ "$SIZE" =~ ^[0-9]+$ ]] || { echo "✗ size must be a byte count, got '$SIZE'" >&2; exit 1; }

tmp="$(mktemp)"
jq --arg v "$VER" --arg b "$BUILD" --arg d "$DATE" --arg desc "$DESC" \
   --arg url "$URL" --argjson size "$SIZE" '
  (.apps[0].minOSVersion // "17.0") as $min
  | .apps[0].versions = (([{
      version: $v, buildVersion: $b, date: $d, localizedDescription: $desc,
      downloadURL: $url, size: $size, minOSVersion: $min
    }] + ((.apps[0].versions // []) | map(select(.version != $v))))
      | sort_by(.version | split(".") | map(tonumber)) | reverse)
  | .apps[0].versions[0] as $latest
  | .apps[0].version            = $latest.version
  | .apps[0].buildVersion       = $latest.buildVersion
  | .apps[0].versionDate        = $latest.date
  | .apps[0].versionDescription = $latest.localizedDescription
  | .apps[0].downloadURL        = $latest.downloadURL
  | .apps[0].size               = $latest.size
' "$SRC" > "$tmp"
mv "$tmp" "$SRC"
echo "✓ $(basename "$SRC"): FitnessTrack $VER (build $BUILD), $SIZE bytes"
