#!/bin/bash
# Publishes a GitHub release: universal build (Apple silicon + Intel), signed ad hoc — Fenestra has no
# Developer ID, so it is not notarized and users confirm it once (see docs/install.md). The asset is always
# named Fenestra.zip, so .../releases/latest/download/Fenestra.zip points to the newest version.
#
#   ./release.sh 1.1.0                                  notes = the commits since the previous release
#   NOTES="- Search Safari tabs" ./release.sh 1.1.0     notes written by hand
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:?Usage : ./release.sh <version>, par exemple 1.1.0}"
TAG="v$VERSION"

if [ -n "$(git status --porcelain)" ]; then echo "Des modifications ne sont pas commitées." >&2; exit 1; fi
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then echo "Le tag $TAG existe déjà." >&2; exit 1; fi

# The version shown by macOS (Finder › Get Info).
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $VERSION" Resources/Info.plist
if [ -n "$(git status --porcelain)" ]; then git commit -q -m "Version $VERSION" Resources/Info.plist; fi

UNIVERSAL=1 CODESIGN_IDENTITY=- ./build.sh
codesign --verify --deep --strict build/Fenestra.app
rm -f build/Fenestra.zip
ditto -c -k --sequesterRsrc --keepParent build/Fenestra.app build/Fenestra.zip

PREVIOUS="$(git describe --tags --abbrev=0 2>/dev/null || true)"
if [ -n "${NOTES:-}" ]; then
  CHANGES="$NOTES"
elif [ -n "$PREVIOUS" ]; then
  CHANGES="$(git log --format='- %s' "$PREVIOUS..HEAD")"
else
  CHANGES="First release."
fi

git tag "$TAG"
git push -q origin HEAD "$TAG"

NOTES_FILE="$(mktemp)"
printf "## What's new\n\n%s\n\n" "$CHANGES" > "$NOTES_FILE"
cat docs/install.md >> "$NOTES_FILE"
gh release create "$TAG" build/Fenestra.zip --title "Fenestra $VERSION" --notes-file "$NOTES_FILE"
rm -f "$NOTES_FILE"
