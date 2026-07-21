#!/usr/bin/env bash
# Build, sign, and publish a Linux release of the Monet desktop app to GitLab.
#
# This is the trusted-local-build counterpart to the macOS DMG release: there is
# deliberately no GitLab CI runner, so releases are cut by hand on a trusted Linux
# machine and pushed to GitLab. The app's auto-updater (tauri-plugin-updater) then
# discovers them via the stable "latest release" permalink configured in
# tauri.conf.json (plugins.updater.endpoints).
#
# Prerequisites on the build machine:
#   - Rust toolchain + `cargo tauri` CLI, and the AppImage/deb build deps.
#   - The updater SIGNING KEY exported into the environment BEFORE running. These
#     are the minisign keys from `cargo tauri signer generate`; the matching
#     PUBLIC key is committed in tauri.conf.json (plugins.updater.pubkey):
#         export TAURI_SIGNING_PRIVATE_KEY="$(cat ~/.config/monet-signing/monet_updater.key)"
#         export TAURI_SIGNING_PRIVATE_KEY_PASSWORD="$(cat ~/.config/monet-signing/monet_updater.pw)"
#   - A GitLab token with api scope:  export GITLAB_TOKEN=…
#
# Usage:
#   desktop/scripts/release-linux.sh <version>     # e.g. 1.0.19  (no leading v)
set -euo pipefail

VERSION="${1:?usage: release-linux.sh <version>   e.g. 1.0.19}"
GITLAB="${GITLAB_URL:-https://gitlab.ericandjoe.work}"
PROJECT_ID="${PROJECT_ID:-12}"
: "${GITLAB_TOKEN:?set GITLAB_TOKEN (api scope)}"
: "${TAURI_SIGNING_PRIVATE_KEY:?export TAURI_SIGNING_PRIVATE_KEY (updater private key)}"
: "${TAURI_SIGNING_PRIVATE_KEY_PASSWORD:?export TAURI_SIGNING_PRIVATE_KEY_PASSWORD}"

DESKTOP="$(cd "$(dirname "$0")/.." && pwd)"
cd "$DESKTOP/src-tauri"

# 1. The bundle version must match the release version, or the updater's version
#    comparison (manifest vs running app) will be wrong.
CFG_VER=$(grep -m1 '"version"' tauri.conf.json | sed -E 's/.*"version" *: *"([^"]+)".*/\1/')
[ "$CFG_VER" = "$VERSION" ] || { echo "ERROR: tauri.conf.json version ($CFG_VER) != $VERSION"; exit 1; }

# 2. Build + sign. createUpdaterArtifacts=true + the signing env emits the
#    detached <AppImage>.sig alongside the bundles.
echo ">> building + signing bundles for v$VERSION"
cargo tauri build --bundles appimage deb

APPDIR="target/release/bundle/appimage"
DEBDIR="target/release/bundle/deb"
APP_NAME="Monet_${VERSION}_amd64.AppImage"
DEB_NAME="Monet_${VERSION}_amd64.deb"
APPIMAGE="$APPDIR/$APP_NAME"
DEB="$DEBDIR/$DEB_NAME"
SIG_FILE="$APPDIR/$APP_NAME.sig"
[ -f "$APPIMAGE" ] || { echo "ERROR: $APPIMAGE not found"; exit 1; }
[ -f "$SIG_FILE" ] || { echo "ERROR: $SIG_FILE not found (signing key not applied?)"; exit 1; }
SIGNATURE="$(cat "$SIG_FILE")"

# 3. Upload the binaries to the generic package registry (publicly downloadable
#    because the project is public).
PKG="$GITLAB/api/v4/projects/$PROJECT_ID/packages/generic/monet/$VERSION"
gl() { curl -sS --fail-with-body --header "PRIVATE-TOKEN: $GITLAB_TOKEN" "$@"; }
echo ">> uploading $APP_NAME + $DEB_NAME to the package registry"
gl --upload-file "$APPIMAGE" "$PKG/$APP_NAME" >/dev/null
gl --upload-file "$DEB"      "$PKG/$DEB_NAME"  >/dev/null

# 4. Build the Tauri static-JSON updater manifest and upload it too.
MANIFEST="$(mktemp)"
cat > "$MANIFEST" <<JSON
{
  "version": "$VERSION",
  "notes": "Monet v$VERSION — see the release page for details.",
  "pub_date": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "platforms": {
    "linux-x86_64": {
      "signature": "$SIGNATURE",
      "url": "$PKG/$APP_NAME"
    }
  }
}
JSON
echo ">> uploading latest.json"
gl --upload-file "$MANIFEST" "$PKG/latest.json" >/dev/null
rm -f "$MANIFEST"

# 5. Upsert the GitLab release and attach the Linux assets. The release for this
#    tag may already exist (e.g. the macOS DMG was published first), so create it
#    only if missing, then add asset links idempotently. The latest.json link uses
#    direct_asset_path=/latest.json so the updater endpoint
#    (…/releases/permalink/latest/downloads/latest.json) resolves to it.
REL="$GITLAB/api/v4/projects/$PROJECT_ID/releases"
add_link() { # name  direct_asset_path  link_type
  local code
  code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
    -H "PRIVATE-TOKEN: $GITLAB_TOKEN" -H "Content-Type: application/json" \
    "$REL/v$VERSION/assets/links" \
    --data "{\"name\":\"$1\",\"url\":\"$PKG/$1\",\"direct_asset_path\":\"$2\",\"link_type\":\"$3\"}")
  case "$code" in
    201) echo "   + linked $1" ;;
    4*)  echo "   = $1 already linked (HTTP $code)" ;;
    *)   echo "   ! $1 link failed (HTTP $code)"; return 1 ;;
  esac
}

if [ "$(curl -sS -o /dev/null -w '%{http_code}' -H "PRIVATE-TOKEN: $GITLAB_TOKEN" "$REL/v$VERSION")" = "200" ]; then
  echo ">> release v$VERSION already exists — attaching Linux assets"
else
  echo ">> creating GitLab release v$VERSION"
  gl --request POST "$REL" --header "Content-Type: application/json" --data @- >/dev/null <<JSON
{ "tag_name": "v$VERSION", "name": "Monet v$VERSION", "ref": "main",
  "description": "Monet v$VERSION (Linux: AppImage self-updates; .deb via download)." }
JSON
fi
add_link "$APP_NAME"   "/$APP_NAME"   "package"
add_link "$DEB_NAME"   "/$DEB_NAME"   "package"
add_link "latest.json" "/latest.json" "other"

echo ">> done. Released v$VERSION"
echo "   updater endpoint: $GITLAB/eric/Monet/-/releases/permalink/latest/downloads/latest.json"
