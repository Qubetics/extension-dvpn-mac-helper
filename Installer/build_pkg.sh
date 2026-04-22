#!/bin/bash
# ─────────────────────────────────────────────────────────
# QubeticsVPN — Build, Sign, Notarize & Staple the .pkg
# ─────────────────────────────────────────────────────────

set -e

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER_DIR="$PROJECT_DIR/Installer"
SCRIPTS_DIR="$INSTALLER_DIR/scripts"
ROOT_DIR="$INSTALLER_DIR/Root"

# ── Load signing configuration ──────────────────────────
source "$INSTALLER_DIR/signing_config.sh"

# ── 1. Find built binaries in DerivedData ────────────────
DERIVED_DATA_BASE="$HOME/Library/Developer/Xcode/DerivedData"
LATEST_DD_DIR=$(ls -td "$DERIVED_DATA_BASE"/QubeticsVPN-* 2>/dev/null | head -n 1)

if [ -z "$LATEST_DD_DIR" ]; then
    echo "Error: Could not find QubeticsVPN in DerivedData ($DERIVED_DATA_BASE)."
    echo "Please build the project in Xcode first."
    exit 1
fi

echo "Found DerivedData at: $LATEST_DD_DIR"

# Try to find the built products (prefer Release over Debug)
for CONFIG in "Release" "Debug"; do
    DD_PATH="$LATEST_DD_DIR/Build/Products/$CONFIG"
    if [ -d "$DD_PATH" ]; then
        echo "Checking $CONFIG build products..."
        if [ -f "$DD_PATH/QubeticsNativeHost" ]; then
            DERIVED_DATA="$DD_PATH"
            echo "  ✓ Found build products in $CONFIG"
            break
        fi
    fi
done

if [ -z "$DERIVED_DATA" ]; then
    echo "Error: Could not find QubeticsNativeHost binary in $LATEST_DD_DIR/Build/Products/"
    echo "Make sure you have built the 'QubeticsNativeHost' target in Xcode."
    exit 1
fi

APP_SOURCE="$DERIVED_DATA/QubeticsVPN.app"
NATIVE_HOST_SOURCE="$DERIVED_DATA/QubeticsNativeHost"
HELPER_SOURCE="$DERIVED_DATA/com.qubetics.vpn.helper"
HELPER_PLIST_SOURCE="$PROJECT_DIR/helper/com.qubetics.vpn.helper.plist"

echo "Using build products from: $DERIVED_DATA"

PKG_UNSIGNED="$INSTALLER_DIR/QubeticsVPN-Installer-unsigned.pkg"
PKG_OUTPUT="$INSTALLER_DIR/QubeticsVPN-Installer.pkg"
IDENTIFIER="com.qubetics.vpn.app"
VERSION="1.0"

# ═══════════════════════════════════════════════════════════
# STEP 1: Prepare the packaging root
# ═══════════════════════════════════════════════════════════
echo ""
echo "═══ Step 1: Preparing packaging root ═══"

rm -rf "$ROOT_DIR"

mkdir -p "$ROOT_DIR/Applications"
mkdir -p "$ROOT_DIR/Library/Application Support/QubeticsVPN"
mkdir -p "$ROOT_DIR/Library/PrivilegedHelperTools"
mkdir -p "$ROOT_DIR/Library/LaunchDaemons"

# Copy the App
if [ -d "$APP_SOURCE" ]; then
    cp -R "$APP_SOURCE" "$ROOT_DIR/Applications/"
else
    echo "Error: QubeticsVPN.app not found in DerivedData!"
    exit 1
fi

# Copy the Native Host standalone binary
if [ -f "$NATIVE_HOST_SOURCE" ]; then
    cp "$NATIVE_HOST_SOURCE" "$ROOT_DIR/Library/Application Support/QubeticsVPN/"
    chmod +x "$ROOT_DIR/Library/Application Support/QubeticsVPN/QubeticsNativeHost"
else
    echo "Error: QubeticsNativeHost binary not found in DerivedData!"
    exit 1
fi

# Copy the Privileged Helper binary
if [ -f "$HELPER_SOURCE" ]; then
    cp "$HELPER_SOURCE" "$ROOT_DIR/Library/PrivilegedHelperTools/"
else
    echo "Error: com.qubetics.vpn.helper binary not found in DerivedData!"
    exit 1
fi

# Copy the LaunchDaemon plist
if [ -f "$HELPER_PLIST_SOURCE" ]; then
    cp "$HELPER_PLIST_SOURCE" "$ROOT_DIR/Library/LaunchDaemons/"
else
    echo "Error: com.qubetics.vpn.helper.plist not found in helper folder!"
    exit 1
fi

# ── 1.5. Bundle WireGuard tools (Universal Binaries) ──────
echo "  → Bundling WireGuard tools as universal binaries..."
BIN_DIR="$ROOT_DIR/Library/Application Support/QubeticsVPN/bin"
mkdir -p "$BIN_DIR"

# Detect arm64 and x86_64 Homebrew prefixes
ARM_BREW="/opt/homebrew"
X86_BREW="/usr/local"

# Helper: try to make a universal binary from two arch-specific sources.
# If only one arch is available, just copy that one.
make_universal() {
    local TOOL_NAME="$1"
    local ARM_SRC="$ARM_BREW/bin/$TOOL_NAME"
    local X86_SRC="$X86_BREW/bin/$TOOL_NAME"
    local DEST="$BIN_DIR/$TOOL_NAME"

    if [ -f "$ARM_SRC" ] && [ -f "$X86_SRC" ]; then
        lipo -create -output "$DEST" "$ARM_SRC" "$X86_SRC" 2>/dev/null && {
            echo "    ✓ Bundled $TOOL_NAME (universal arm64+x86_64)"
            return 0
        }
    fi
    # Fall back: copy whichever arch is available locally
    for SRC in "$ARM_SRC" "$X86_SRC" "$(which "$TOOL_NAME" 2>/dev/null)"; do
        if [ -f "$SRC" ]; then
            cp "$SRC" "$DEST"
            ARCH=$(lipo -archs "$DEST" 2>/dev/null || file "$DEST" | grep -o 'arm64\|x86_64' | head -1)
            echo "    ✓ Bundled $TOOL_NAME ($ARCH only — cross-arch machine will need WireGuard installed)"
            return 0
        fi
    done
    echo "    ⚠ $TOOL_NAME not found — skipping"
    return 1
}

# Bundle wg (control tool — not a shell script, must be a native binary)
make_universal "wg"

# Bundle wireguard-go (tunnel daemon — must be a native binary)
make_universal "wireguard-go"

# wg-quick is a bash script — copy it and patch shebang to use system /bin/bash
# System /bin/bash is ALWAYS a universal binary on macOS — never use Homebrew bash here.
WG_QUICK_PATH=""
for P in "$ARM_BREW/bin/wg-quick" "$X86_BREW/bin/wg-quick" "$(which wg-quick 2>/dev/null)"; do
    if [ -f "$P" ]; then
        WG_QUICK_PATH="$P"
        break
    fi
done

if [ -n "$WG_QUICK_PATH" ]; then
    cp "$WG_QUICK_PATH" "$BIN_DIR/wg-quick"
    # Keep the original shebang — the helper will invoke wg-quick explicitly
    # through our bundled bash 4+, so the shebang doesn't matter.
    chmod +x "$BIN_DIR/wg-quick"
    echo "    ✓ Bundled wg-quick"
else
    echo "    ⚠ wg-quick not found — skipping"
fi

# Bundle Homebrew bash 4+ and its dylib dependencies.
# macOS system /bin/bash is v3.2 (GPLv2) — wg-quick REQUIRES bash 4+.
# The helper will invoke: /bundled/bash /bundled/wg-quick up wg0
# bypassing the shebang entirely.
echo "  → Bundling bash 4+ and dependencies..."
BASH_PATH=""
for P in "$ARM_BREW/bin/bash" "$X86_BREW/bin/bash" "$(which bash 2>/dev/null | grep -v /bin/bash)"; do
    if [ -f "$P" ]; then
        BASH_PATH="$P"
        break
    fi
done

if [ -n "$BASH_PATH" ]; then
    cp "$BASH_PATH" "$BIN_DIR/bash"
    echo "    ✓ Bundled bash from $BASH_PATH"

    # Bundle bash's Homebrew dylib dependencies and relink them
    LIBS=$(otool -L "$BASH_PATH" | grep -E "/opt/homebrew|/usr/local/opt" | awk '{print $1}')
    for LIB in $LIBS; do
        if [ -f "$LIB" ]; then
            LIB_NAME=$(basename "$LIB")
            cp "$LIB" "$BIN_DIR/"
            chmod 644 "$BIN_DIR/$LIB_NAME"
            install_name_tool -change "$LIB" "@executable_path/$LIB_NAME" "$BIN_DIR/bash"
            echo "    ✓ Bundled $LIB_NAME and relinked"
        fi
    done
else
    echo "    ⚠ Homebrew bash not found — wg-quick will fail on macOS (system bash is v3.2)"
fi

chmod +x "$SCRIPTS_DIR/postinstall"

# ═══════════════════════════════════════════════════════════
# STEP 2: Code-sign all binaries with Hardened Runtime
# ═══════════════════════════════════════════════════════════
echo ""
echo "═══ Step 2: Code-signing binaries (Hardened Runtime) ═══"

# Sign the standalone helper binary (in /Library/PrivilegedHelperTools/)
echo "  → Signing com.qubetics.vpn.helper (standalone)..."
codesign --force --options runtime --timestamp \
    --sign "$DEVELOPER_ID_APP" \
    "$ROOT_DIR/Library/PrivilegedHelperTools/com.qubetics.vpn.helper"

# Sign the native host binary
echo "  → Signing QubeticsNativeHost..."
codesign --force --options runtime --timestamp \
    --sign "$DEVELOPER_ID_APP" \
    "$ROOT_DIR/Library/Application Support/QubeticsVPN/QubeticsNativeHost"

# Sign the embedded helper INSIDE the app bundle first (before signing the app)
# Xcode builds this with Apple Development cert + get-task-allow, which Apple rejects.
# We must re-sign it with Developer ID + hardened runtime + no get-task-allow.
EMBEDDED_HELPER="$ROOT_DIR/Applications/QubeticsVPN.app/Contents/Library/LaunchServices/com.qubetics.vpn.helper"
if [ -f "$EMBEDDED_HELPER" ]; then
    echo "  → Signing embedded helper (inside QubeticsVPN.app)..."
    codesign --force --options runtime --timestamp \
        --sign "$DEVELOPER_ID_APP" \
        "$EMBEDDED_HELPER"
else
    echo "  ⚠ No embedded helper found at LaunchServices (skipping)"
fi

# Sign the main app (must be done AFTER signing any embedded binaries)
echo "  → Signing QubeticsVPN.app..."
codesign --force --options runtime --timestamp \
    --sign "$DEVELOPER_ID_APP" \
    "$ROOT_DIR/Applications/QubeticsVPN.app"

# Sign bundled WireGuard and bash binaries + dylibs
echo "  → Signing bundled binaries and libraries..."
if [ -d "$BIN_DIR" ]; then
    # Sign dylibs first (bash dependencies)
    find "$BIN_DIR" -maxdepth 1 -name "*.dylib" -exec echo "    Signing {}..." \; \
        -exec codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID_APP" {} \;
    # Sign native Mach-O binaries (wg-quick is a bash script, skip it)
    for BINARY in "wg" "wireguard-go" "bash"; do
        if [ -f "$BIN_DIR/$BINARY" ]; then
            echo "    Signing $BINARY..."
            codesign --force --options runtime --timestamp \
                --sign "$DEVELOPER_ID_APP" \
                "$BIN_DIR/$BINARY"
        fi
    done
fi

# Verify signatures
echo ""
echo "  Verifying signatures..."
codesign -dvv "$ROOT_DIR/Library/PrivilegedHelperTools/com.qubetics.vpn.helper" 2>&1 | grep -E "Authority|Signature|Runtime"
codesign -dvv "$ROOT_DIR/Library/Application Support/QubeticsVPN/QubeticsNativeHost" 2>&1 | grep -E "Authority|Signature|Runtime"
if [ -f "$EMBEDDED_HELPER" ]; then
    codesign -dvv "$EMBEDDED_HELPER" 2>&1 | grep -E "Authority|Signature|Runtime"
fi
codesign -dvv "$ROOT_DIR/Applications/QubeticsVPN.app" 2>&1 | grep -E "Authority|Signature|Runtime"
echo "  ✓ All binaries signed"

# ═══════════════════════════════════════════════════════════
# STEP 3: Build the .pkg
# ═══════════════════════════════════════════════════════════
echo ""
echo "═══ Step 3: Building .pkg ═══"

pkgbuild --root "$ROOT_DIR" \
         --scripts "$SCRIPTS_DIR" \
         --identifier "$IDENTIFIER" \
         --version "$VERSION" \
         "$PKG_UNSIGNED"

echo "  ✓ Unsigned .pkg created"

# ═══════════════════════════════════════════════════════════
# STEP 4: Sign the .pkg with Developer ID Installer
# ═══════════════════════════════════════════════════════════
echo ""
echo "═══ Step 4: Signing .pkg with Developer ID Installer ═══"

productsign --sign "$DEVELOPER_ID_INSTALLER" \
    "$PKG_UNSIGNED" \
    "$PKG_OUTPUT"

rm -f "$PKG_UNSIGNED"
echo "  ✓ Signed .pkg created at $PKG_OUTPUT"

# Verify pkg signature
echo ""
echo "  Verifying .pkg signature..."
pkgutil --check-signature "$PKG_OUTPUT"

# ═══════════════════════════════════════════════════════════
# STEP 5: Notarize the .pkg with Apple
# ═══════════════════════════════════════════════════════════
echo ""
echo "═══ Step 5: Submitting .pkg to Apple for notarization ═══"
echo "  (This may take a few minutes...)"

# Capture output to check for "Invalid" status (notarytool returns exit 0 even for Invalid)
NOTARY_OUTPUT=$(xcrun notarytool submit "$PKG_OUTPUT" \
    --keychain-profile "$NOTARYTOOL_PROFILE" \
    --wait 2>&1)

echo "$NOTARY_OUTPUT"

# Check for failure: either non-zero exit code or "Invalid" / "Rejected" in output
if echo "$NOTARY_OUTPUT" | grep -qiE "status: (Invalid|Rejected)"; then
    echo ""
    echo "⚠️  Notarization REJECTED by Apple!"
    # Extract submission ID and fetch detailed log
    SUBMISSION_ID=$(echo "$NOTARY_OUTPUT" | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)
    if [ -n "$SUBMISSION_ID" ]; then
        echo ""
        echo "  Fetching detailed rejection log..."
        xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$NOTARYTOOL_PROFILE" 2>&1
    fi
    exit 1
fi

if ! echo "$NOTARY_OUTPUT" | grep -qi "status: Accepted"; then
    echo ""
    echo "⚠️  Notarization did not return 'Accepted'. Check output above."
    exit 1
fi

echo "  ✓ Notarization accepted by Apple!"

# ═══════════════════════════════════════════════════════════
# STEP 6: Staple the notarization ticket to the .pkg
# ═══════════════════════════════════════════════════════════
echo ""
echo "═══ Step 6: Stapling notarization ticket ═══"

xcrun stapler staple "$PKG_OUTPUT"
echo "  ✓ Notarization ticket stapled"

# ═══════════════════════════════════════════════════════════
# Clean up
# ═══════════════════════════════════════════════════════════
rm -rf "$ROOT_DIR"

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  ✅ Done! Signed & notarized installer:"
echo "     $PKG_OUTPUT"
echo "═══════════════════════════════════════════════════════════"
