#!/usr/bin/env bash
# Vendors the kokoro-swift package so SPM can resolve its local Misaki
# sub-package (remote branch deps can't contain path deps).
#
# Usage:  ./Scripts/fetch-kokoro.sh   then   xcodegen
set -euo pipefail

cd "$(dirname "$0")/.."
mkdir -p Vendor

if [ -d Vendor/kokoro-swift/.git ]; then
  echo "→ Updating existing Vendor/kokoro-swift…"
  git -C Vendor/kokoro-swift pull --ff-only
else
  echo "→ Cloning kokoro-swift into Vendor/…"
  git clone --depth 1 https://github.com/mweinbach/kokoro-swift.git Vendor/kokoro-swift
fi

echo
echo "✓ Vendored. Products declared by the package:"
grep -A 10 'products:' Vendor/kokoro-swift/Package.swift | head -20 || true
echo
echo "Next:  xcodegen && open Athena.xcodeproj"
