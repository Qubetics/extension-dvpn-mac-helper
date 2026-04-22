#!/bin/bash
# ─────────────────────────────────────────────────────────
# QubeticsVPN — Signing & Notarization Configuration
# ─────────────────────────────────────────────────────────

# Developer ID Application certificate (signs binaries / .app)
# DEVELOPER_ID_APP="Developer ID Application: Antier Solutions Private Limited (HVUWR9HCMS)"
DEVELOPER_ID_APP="Developer ID Application: Qubetics Labs LLC (X494M4XTU3)"

# Developer ID Installer certificate (signs .pkg)
# DEVELOPER_ID_INSTALLER="Developer ID Installer: Antier Solutions Private Limited (HVUWR9HCMS)"
DEVELOPER_ID_INSTALLER="Developer ID Installer: Qubetics Labs LLC (X494M4XTU3)"

# Apple Team ID
# TEAM_ID="HVUWR9HCMS"
TEAM_ID="X494M4XTU3"

# Keychain profile name for notarytool (created via `xcrun notarytool store-credentials`)
NOTARYTOOL_PROFILE="QubeticsVPN-Notarize"
