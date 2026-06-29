#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="LAN Scanner"
APP_DIR="${ROOT_DIR}/dist/${APP_NAME}.app"
DMG_NAME="lan-scanner.dmg"
DMG_PATH="${ROOT_DIR}/dist/${DMG_NAME}"
VOLUME_NAME="LAN Scanner Installer"
RW_DMG_PATH="${ROOT_DIR}/dist/lan-scanner-rw.dmg"

cd "${ROOT_DIR}"

"${ROOT_DIR}/Scripts/build-app.sh" release

for volume in "/Volumes/LAN Scanner" "/Volumes/LAN Scanner "* "/Volumes/${VOLUME_NAME}" "/Volumes/${VOLUME_NAME} "*; do
  if [[ -e "${volume}" ]]; then
    hdiutil detach "${volume}" >/dev/null || true
  fi
done

rm -rf "${DMG_PATH}" "${RW_DMG_PATH}" "${ROOT_DIR}/dist/LAN Scanner.dmg"

hdiutil create \
  -volname "${VOLUME_NAME}" \
  -size 20m \
  -fs APFS \
  "${RW_DMG_PATH}"

hdiutil attach -nobrowse -readwrite "${RW_DMG_PATH}"
trap 'hdiutil detach "/Volumes/${VOLUME_NAME}" >/dev/null 2>&1 || true' EXIT

cp -R "${APP_DIR}" "/Volumes/${VOLUME_NAME}/${APP_NAME}.app"
ln -s /Applications "/Volumes/${VOLUME_NAME}/Applications"
xattr -cr "/Volumes/${VOLUME_NAME}/${APP_NAME}.app"
codesign --force --deep --sign - "/Volumes/${VOLUME_NAME}/${APP_NAME}.app"
codesign --verify --deep --strict --verbose=2 "/Volumes/${VOLUME_NAME}/${APP_NAME}.app"

hdiutil detach "/Volumes/${VOLUME_NAME}"
trap - EXIT

hdiutil convert "${RW_DMG_PATH}" -format UDZO -o "${DMG_PATH}"
hdiutil verify "${DMG_PATH}"
rm -f "${RW_DMG_PATH}"

echo "Built ${DMG_PATH}"
