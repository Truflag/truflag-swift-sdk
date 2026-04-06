#!/usr/bin/env bash
set -euo pipefail

TARGET_PATH="${1:-../truflag-swift-sdk}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SDK_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

mkdir -p "${TARGET_PATH}"

if command -v rsync >/dev/null 2>&1; then
  rsync -a \
    --delete \
    --exclude '.build' \
    --exclude '.swiftpm' \
    --exclude '.DS_Store' \
    "${SDK_DIR}/" "${TARGET_PATH}/"
else
  rm -rf "${TARGET_PATH}"
  mkdir -p "${TARGET_PATH}"
  cp -R "${SDK_DIR}/." "${TARGET_PATH}/"
  rm -rf "${TARGET_PATH}/.build" "${TARGET_PATH}/.swiftpm"
fi

if [ ! -d "${TARGET_PATH}/.git" ]; then
  git -C "${TARGET_PATH}" init >/dev/null
fi

cat <<EOF
Standalone SDK exported to: ${TARGET_PATH}

Next steps:
  1) cd ${TARGET_PATH}
  2) git remote add origin <your-swift-sdk-repo-url>
  3) swift test
  4) pod lib lint TruflagSDK.podspec --allow-warnings
  5) git add . && git commit -m "Release prep"
EOF
