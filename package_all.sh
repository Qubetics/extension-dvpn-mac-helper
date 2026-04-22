#!/bin/bash
# ─────────────────────────────────────────────────────────
# Script to Build and Package QubeticsVPN into a signed,
# notarized .pkg installer.
# ─────────────────────────────────────────────────────────

set -e

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
XCODEPROJ="$PROJECT_DIR/QubeticsVPN.xcodeproj"
BUILD_CONFIG="Release"

echo "═══════════════════════════════════════════════════════"
echo "  QubeticsVPN — Build & Package (${BUILD_CONFIG})"
echo "═══════════════════════════════════════════════════════"
echo ""

echo "Step 1: Building all targets in Xcode ($BUILD_CONFIG)..."
echo ""

# Build QubeticsVPN App
echo "  → Building QubeticsVPN.app..."
xcodebuild -project "$XCODEPROJ" -scheme QubeticsVPN -configuration "$BUILD_CONFIG" build

# Build Native Host Tool
echo "  → Building QubeticsNativeHost..."
xcodebuild -project "$XCODEPROJ" -scheme QubeticsNativeHost -configuration "$BUILD_CONFIG" build

# Build Privileged Helper Tool
echo "  → Building helper..."
xcodebuild -project "$XCODEPROJ" -scheme helper -configuration "$BUILD_CONFIG" build

echo ""
echo "Step 2: Running packaging, signing & notarization script..."
chmod +x "$PROJECT_DIR/Installer/build_pkg.sh"
"$PROJECT_DIR/Installer/build_pkg.sh"

echo ""
echo "✅ All Done! Your signed, notarized installer is ready."
