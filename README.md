# QubeticsVPN macOS Helper

Native macOS plumbing that lets a Chrome extension bring a WireGuard tunnel up and
down. Chrome cannot create network interfaces or run privileged commands, so this
repo supplies the three pieces that can: a Native Messaging host that Chrome can
launch, a root-level XPC helper that actually runs `wg-quick`, and a signed `.pkg`
that installs both plus a self-contained copy of the WireGuard tools.

There is no UI. The `.app` exists only as a fallback installer for the privileged
helper; everything a user sees lives in the Chrome extension.

The extension side (Qubetics Wallet, a separate repo) drives this host from
`src/services/dvpn/agent.js`. If you are integrating against it, start with
[docs/chrome-extension-integration.md](docs/chrome-extension-integration.md).

---

## 1. Components

| Target / file | Installed as | Runs as | Job |
|---|---|---|---|
| `QubeticsNativeHost` | `/Library/Application Support/QubeticsVPN/QubeticsNativeHost` | the logged-in user, spawned by Chrome | Speaks Chrome Native Messaging on stdin/stdout, forwards to the helper over XPC |
| `helper` | `/Library/PrivilegedHelperTools/com.qubetics.vpn.helper` | `root`, launched on demand by `launchd` | Writes `wg0.conf`, runs `wg-quick up/down`, reports tunnel state |
| `QubeticsVPN.app` | `/Applications/QubeticsVPN.app` | the logged-in user | Headless. Calls `SMJobBless` to install the helper, then quits. Only needed if the `.pkg` path is bypassed |
| `Shared/VPNHelperProtocol.swift` | compiled into all three | — | The `@objc` XPC interface: `connectVPN`, `disconnectVPN`, `vpnStatus` |

Bundled alongside the native host in `/Library/Application Support/QubeticsVPN/bin`:
`wg`, `wireguard-go`, `wg-quick`, and a Homebrew `bash`. The bundled bash matters —
`wg-quick` is a bash 4+ script and macOS still ships bash 3.2, so the helper invokes
`bash /path/to/wg-quick up wg0` explicitly rather than relying on the shebang.

---

## 2. Layout after install

```
/Applications/QubeticsVPN.app
/Library/Application Support/QubeticsVPN/
├── QubeticsNativeHost
└── bin/{wg, wireguard-go, wg-quick, bash, *.dylib}
/Library/PrivilegedHelperTools/com.qubetics.vpn.helper
/Library/LaunchDaemons/com.qubetics.vpn.helper.plist
/Library/Google/Chrome/NativeMessagingHosts/com.qubetics.vpn.json
~/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.qubetics.vpn.json

# created at runtime
/usr/local/etc/wireguard/wg0.conf     (0600, root)
/var/run/wireguard/*.sock
```

---

## 3. How a connect flows

```
Chrome extension
   │  chrome.runtime.connectNative("com.qubetics.vpn")
   ▼
QubeticsNativeHost                       (user, one process per port)
   │  reads 4-byte LE length + JSON from stdin
   │  replies {"status":"connecting"} immediately
   │  NSXPCConnection(machServiceName:"com.qubetics.vpn.helper", options:.privileged)
   ▼
launchd  ──spawns on demand──▶  com.qubetics.vpn.helper   (root)
   │  writes config to /usr/local/etc/wireguard/wg0.conf (0600)
   │  bash wg-quick down wg0        (clean up any stale tunnel)
   │  ensures /var/run/wireguard exists
   │  bash wg-quick up   wg0
   │  polls `wg show all latest-handshakes` 10× every 0.5s
   ▼  reply: "VPN Connected" | "VPN Connection Failed: ..."
QubeticsNativeHost
   │  waits up to 30s on a semaphore
   ▼  {"status":"connected"} or {"status":"failed","message":"..."}
Chrome extension
```

Two points that trip people up:

- **Connect emits two messages**, `connecting` then the terminal result. A
  `chrome.runtime.sendNativeMessage` call only ever surfaces the first one, so the
  extension must use a long-lived port. Same for disconnect (`disconnecting` first).
- **"Connected" means a handshake was observed**, not just that `wg-quick`
  succeeded. If the interface comes up but the peer never answers within ~5s, the
  helper reports a handshake timeout as a failure.

Tunnel state is derived, never cached:

| Helper check | Meaning |
|---|---|
| `wg show all latest-handshakes` has a non-zero timestamp | `connected` |
| a `.sock` exists in `/var/run/wireguard` but no handshake | `connecting` |
| neither | `disconnected` |

---

## 4. Message protocol

Standard Chrome Native Messaging framing: a 4-byte little-endian `uint32` length
followed by that many bytes of UTF-8 JSON, both directions. Chrome handles the
framing for you; this section is the payload contract.

### Requests

| `action` | Other fields | Notes |
|---|---|---|
| `connect` | `configContent` (string, required) | A full WireGuard `.conf` file as text |
| `disconnect` | — | |
| `status` | — | |

An unknown action gets `{"error": "unknown action"}`.

### Responses

| Request | Messages emitted, in order |
|---|---|
| `connect` | `{"status":"connecting"}` → `{"status":"connected","message":"VPN Connected"}` or `{"status":"failed","message":"<reason>"}` |
| `connect` with no `configContent` | `{"status":"failed","message":"No config received from extension"}` (single message) |
| `disconnect` | `{"status":"disconnecting"}` → `{"status":"disconnected","message":"VPN Disconnected"}` or `{"status":"failed","message":"<reason>"}` |
| `status` | `{"status":"connected"}`, `{"status":"connecting"}`, `{"status":"disconnected"}`, or `{"status":"error: helper_missing"}` |

Timeouts inside the host: 30s for connect and disconnect, 5s for status (a status
timeout is reported as `disconnected`). `error: helper_missing` means
`/Library/PrivilegedHelperTools/com.qubetics.vpn.helper` is not on disk — the
installer never ran, or the helper was removed.

### Config format

Whatever you pass as `configContent` is written verbatim to `wg0.conf`, so it has to
be a valid `wg-quick` config:

```ini
[Interface]
PrivateKey = <base64>
Address = 10.8.0.2/32
DNS = 1.1.1.1,8.8.8.8
MTU = 1300

[Peer]
PublicKey = <base64>
AllowedIPs = 0.0.0.0/0
Endpoint = 13.60.226.99:51820
PersistentKeepalive = 25
```

---

## 5. Building and packaging

### Prerequisites on the build machine

- Xcode with the `QubeticsVPN`, `QubeticsNativeHost` and `helper` schemes
- Homebrew `wireguard-tools`, `wireguard-go` and `bash` — `build_pkg.sh` copies these
  into the package. Install them for both architectures (`/opt/homebrew` and
  `/usr/local`) if you want universal binaries; with only one arch present the script
  warns and ships that arch alone
- `Developer ID Application` and `Developer ID Installer` certificates for the team in
  [Installer/signing_config.sh](Installer/signing_config.sh)
- A notarytool keychain profile named `QubeticsVPN-Notarize`:
  ```bash
  xcrun notarytool store-credentials QubeticsVPN-Notarize \
    --apple-id <you@example.com> --team-id X494M4XTU3 --password <app-specific-password>
  ```

### One command

```bash
./package_all.sh
```

That builds all three targets in Release, then hands off to
[Installer/build_pkg.sh](Installer/build_pkg.sh), which:

1. locates the newest `QubeticsVPN-*` DerivedData folder and stages a package root
2. bundles `wg` / `wireguard-go` as universal binaries via `lipo`, copies `wg-quick`,
   copies Homebrew bash and rewrites its dylib references to `@executable_path`
3. code-signs every binary with Developer ID and hardened runtime, including the copy
   of the helper embedded in the app bundle (Xcode signs that one with a development
   cert and `get-task-allow`, which Apple rejects)
4. `pkgbuild` → `productsign` → `notarytool submit --wait` → `stapler staple`

Output: `Installer/QubeticsVPN-Installer.pkg`. The script fails loudly on a rejected
notarization and prints Apple's log.

### What the installer does at install time

[Installer/scripts/postinstall](Installer/scripts/postinstall) scans every Chrome
profile under `/Users/*` for an extension whose manifest name contains "qubetics",
collects the IDs it finds, adds the fallback ID
`oabinpbnodlcmbnohnnbnbjpfkpclhim`, and writes them all into `allowed_origins` of the
native messaging manifest. It writes the manifest system-wide and again per user,
fixes ownership on the helper and the WireGuard tools, creates `/var/run/wireguard`,
and `launchctl load -w`s the LaunchDaemon.

The consequence worth remembering: **the manifest is generated from whatever is
installed in Chrome at install time.** Install the extension first, then the `.pkg`.
See [docs/chrome-extension-integration.md](docs/chrome-extension-integration.md) for
how to avoid that ordering trap during development.

---

## 6. Verifying an install

```bash
# native messaging manifest and the IDs it trusts
cat "/Library/Google/Chrome/NativeMessagingHosts/com.qubetics.vpn.json"

# helper daemon registered and loadable
sudo launchctl print system/com.qubetics.vpn.helper | head

# talk to the host directly, bypassing Chrome (prints a length-prefixed reply)
printf '\x08\x00\x00\x00{"action":"status"}' | \
  "/Library/Application Support/QubeticsVPN/QubeticsNativeHost"
```

Note the length prefix must match the JSON byte count, so the snippet above is
illustrative — in practice use the Python helper in the integration doc.

Helper logs go to the unified log:

```bash
log stream --predicate 'subsystem == "com.qubetics.vpn.helper"' --info
```

---

## 7. Troubleshooting

| Symptom | Likely cause |
|---|---|
| `Specified native messaging host not found` in Chrome | Manifest missing, or Chrome is reading a different profile directory. Check both the system and per-user paths |
| `Access to the specified native messaging host is forbidden` | The extension's ID is not in `allowed_origins`. Reinstall the `.pkg` after loading the extension, or add the ID by hand |
| `error: helper_missing` | Helper binary absent. Reinstall, or launch `/Applications/QubeticsVPN.app` once to `SMJobBless` it |
| `Error: wg-quick not found` | The bundled `bin` directory did not ship — the build machine had no Homebrew WireGuard when `build_pkg.sh` ran |
| `VPN Connection Failed: Handshake Timeout` | Tunnel came up but the peer never responded. Wrong keys, wrong endpoint, or the server is down |
| Connect fails only on Intel (or only on Apple silicon) | `lipo` had one arch available at build time. Build on a machine with both Homebrew prefixes populated |
| Nothing happens, no error | You used `sendNativeMessage` and only saw `connecting`. Switch to `connectNative` |

---

## 8. Security notes

Worth knowing before this ships further:

- `HelperListenerDelegate` accepts **every** XPC connection without verifying the
  client's code signature. Any local process can reach the root helper over the Mach
  service and ask it to write a WireGuard config and bring up a tunnel. Pinning the
  caller with `SecCodeCopySigningInformation` / an audit-token check belongs on the
  roadmap.
- `configContent` is written to disk verbatim and handed to `wg-quick`, which runs as
  root and will execute `PostUp`/`PreUp` hooks if the config contains them. The host
  does not validate or strip them.
- [helper/helper.entitlements](helper/helper.entitlements) sets `get-task-allow` for
  debugging. Release signing in `build_pkg.sh` re-signs without entitlements, which
  drops it — keep it that way.
- `disconnectVPN` reports `"VPN Disconnected"` regardless of `wg-quick`'s exit status,
  so a failed teardown looks like a success to the extension.

---

## 9. License

MIT — see [LICENSE](LICENSE).

The WireGuard tools the installer bundles are separately licensed and are **not**
covered by it: `wg` / `wg-quick` from `wireguard-tools` and `wireguard-go` are
GPLv2, and the bundled Homebrew `bash` is GPLv3. Shipping them inside the `.pkg` is
a distribution, so the corresponding source offer applies to those components.
