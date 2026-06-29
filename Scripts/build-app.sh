#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${1:-release}"
APP_NAME="LAN Scanner"
EXECUTABLE_NAME="LANScanner"
APP_DIR="${ROOT_DIR}/dist/${APP_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
BUILD_DIR="${ROOT_DIR}/.build/${CONFIGURATION}"

if [[ "${CONFIGURATION}" != "debug" && "${CONFIGURATION}" != "release" ]]; then
  echo "Usage: Scripts/build-app.sh [debug|release]" >&2
  exit 1
fi

cd "${ROOT_DIR}"

if [[ "${CONFIGURATION}" == "release" ]]; then
  swift build -c release
else
  swift build
fi

rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

cp "${BUILD_DIR}/${EXECUTABLE_NAME}" "${MACOS_DIR}/${EXECUTABLE_NAME}"
cp "${ROOT_DIR}/Resources/Info.plist" "${CONTENTS_DIR}/Info.plist"
if [[ -f "${ROOT_DIR}/Resources/LANScannerIcon.icns" ]]; then
  cp "${ROOT_DIR}/Resources/LANScannerIcon.icns" "${RESOURCES_DIR}/LANScannerIcon.icns"
fi
if [[ -f "${ROOT_DIR}/Resources/LANScannerIcon.svg" ]]; then
  cp "${ROOT_DIR}/Resources/LANScannerIcon.svg" "${RESOURCES_DIR}/LANScannerIcon.svg"
fi
if [[ -f "${ROOT_DIR}/Resources/GhostIcon.icns" ]]; then
  cp "${ROOT_DIR}/Resources/GhostIcon.icns" "${RESOURCES_DIR}/GhostIcon.icns"
fi
if [[ -f "${ROOT_DIR}/Resources/GhostIcon.svg" ]]; then
  cp "${ROOT_DIR}/Resources/GhostIcon.svg" "${RESOURCES_DIR}/GhostIcon.svg"
fi
chmod +x "${MACOS_DIR}/${EXECUTABLE_NAME}"

xattr -cr "${APP_DIR}"
codesign --force --deep --sign - "${APP_DIR}"
codesign --verify --deep --strict --verbose=2 "${APP_DIR}"

echo "Built ${APP_DIR}"
