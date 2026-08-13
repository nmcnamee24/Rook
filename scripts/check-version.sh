#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
INFO_PLIST="$PROJECT_DIR/Resources/Info.plist"

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST")"

checks=(
  "$PROJECT_DIR/README.md|$version (build $build)"
  "$PROJECT_DIR/README.md|Rook $version requires macOS 26"
  "$PROJECT_DIR/Sources/RookCore/RookWeatherService.swift|Rook/$version personal weather assistant"
  "$PROJECT_DIR/CHANGELOG.md|## [$version]"
)

for check in "${checks[@]}"; do
  file="${check%%|*}"
  expected="${check#*|}"
  if ! /usr/bin/grep -Fq "$expected" "$file"; then
    echo "Version drift: expected '$expected' in ${file#$PROJECT_DIR/}" >&2
    exit 1
  fi
done

echo "Rook version $version (build $build) is consistent."
