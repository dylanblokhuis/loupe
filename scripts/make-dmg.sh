#!/usr/bin/env bash
#
# Build a compressed, drag-to-install .dmg around an already-built .app bundle.
#
#   scripts/make-dmg.sh path/to/loupe.app dist/Loupe-1.2.3.dmg "Loupe 1.2.3"
#
# Runs the same way locally as it does in .github/workflows/release.yml, so a
# packaging problem can be reproduced without pushing a tag.

set -euo pipefail

APP_PATH=${1:?usage: make-dmg.sh <path/to/App.app> <path/to/out.dmg> [volume name]}
DMG_PATH=${2:?usage: make-dmg.sh <path/to/App.app> <path/to/out.dmg> [volume name]}
VOLUME_NAME=${3:-$(basename "$APP_PATH" .app)}

if [ ! -d "$APP_PATH" ]; then
	echo "make-dmg: no app bundle at $APP_PATH" >&2
	exit 1
fi

staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT

# ditto rather than cp -R: it preserves the code signature, symlinks and
# extended attributes of the bundle, which cp mangles just enough to invalidate
# a Developer ID signature.
ditto "$APP_PATH" "$staging/$(basename "$APP_PATH")"

# The /Applications symlink is what turns the mounted volume into the familiar
# drag-the-app-onto-the-folder installer.
ln -s /Applications "$staging/Applications"

mkdir -p "$(dirname "$DMG_PATH")"
rm -f "$DMG_PATH"

# hdiutil intermittently loses a race with Spotlight over the freshly written
# staging directory and bails out with "Resource busy"; a retry clears it.
for attempt in 1 2 3; do
	if hdiutil create \
		-volname "$VOLUME_NAME" \
		-srcfolder "$staging" \
		-fs HFS+ \
		-format UDZO \
		-imagekey zlib-level=9 \
		-ov \
		"$DMG_PATH"; then
		echo "make-dmg: wrote $DMG_PATH"
		exit 0
	fi
	echo "make-dmg: hdiutil create failed (attempt $attempt/3), retrying in 5s" >&2
	sleep 5
done

echo "make-dmg: hdiutil create failed after 3 attempts" >&2
exit 1
