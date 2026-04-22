# Using the native host from the Chrome extension

How the Qubetics Wallet extension drives this native host on macOS, and what you
need in place for it to work. The extension side lives in a separate repo; all
references below are to `src/...` inside it.

On Windows and Linux the extension talks to a local HTTP agent (`wg-agent`) on
`127.0.0.1:51821-51830`. macOS has no such agent — Chrome Native Messaging takes its
place, and `QubeticsNativeHost` is the endpoint.

---

## 1. Where the two sides meet

Everything on the extension side is in **`src/services/dvpn/agent.js`**:

```js
const NATIVE_HOST = "com.qubetics.vpn";   // must match the manifest "name"
```

That file exposes one API that both transports implement, and uses the string
`"native"` as a sentinel `baseUrl` meaning "this is macOS, go through the port
instead of fetch":

| `agent.js` export | HTTP transport (win/linux) | macOS native transport | Host action |
|---|---|---|---|
| `findRunningAgent()` | `GET /health` across 10 ports | opens the port, sends `status` | `status` |
| `getAgentStatus(baseUrl)` | `GET /status` | sends `status` | `status` |
| `startAgentTunnel({baseUrl, config})` | `POST /start` | sends `connect` + `configContent` | `connect` |
| `stopAgentTunnel(baseUrl)` | `POST /stop` | sends `disconnect` | `disconnect` |
| `resetNativePendingState()` | — | drops the cached port and pending promise | — |

`detectOS()` in `src/helpers/dvpn.helpers.js` picks the branch, off
`navigator.platform`. Callers (`DVpn.jsx`, `ServersNodes.jsx`, `MenuFooter.jsx`,
`DvpnSetting.jsx`) never know which transport they got — they just carry `baseUrl`
around, and on macOS it is the literal string `"native"`.

The wire protocol itself (actions, responses, framing) is documented in the
[README](../README.md#4-message-protocol).

---

## 2. What has to be true before it works

### 2.1 The `nativeMessaging` permission

Already present in `public/manifest.json`. Without it `chrome.runtime.connectNative`
throws.

### 2.2 A stable extension ID

Chrome derives an unpacked extension's ID from its path, so it changes per machine
and per checkout. The native host only answers extensions listed in
`allowed_origins`, so the ID has to be pinned.

The extension does this with a `key` in the manifest:

- `EXTENSION_PUBLIC_KEY` in `.env` (see `.env.example`)
- `scripts/add-manifest-key.js`, wired as `postbuild`, injects it into
  `build/manifest.json`

```bash
npm run build      # runs webpack + react-scripts build, then add-manifest-key.js
```

If `EXTENSION_PUBLIC_KEY` is unset the script prints a warning and skips — the build
still loads, but with a different ID, and every native call will fail with
*"Access to the specified native messaging host is forbidden."* That warning in the
build log is the single most common cause of a broken dev setup.

The production ID this host ships with as a fallback is
`oabinpbnodlcmbnohnnbnbjpfkpclhim`.

### 2.3 The ID has to be in `allowed_origins`

The installer's `postinstall` builds `allowed_origins` by scanning Chrome profiles
for an extension whose manifest `name` contains "qubetics" (case-insensitive), so:

- **Load the extension first, install the `.pkg` second.** The other order leaves
  only the fallback ID in the manifest.
- Renaming the extension away from "Qubetics Wallet" breaks the discovery.

To add an ID without reinstalling:

```bash
sudo python3 - <<'PY'
import json, pathlib
EXT_ID = "paste-your-extension-id-here"
for p in [pathlib.Path("/Library/Google/Chrome/NativeMessagingHosts/com.qubetics.vpn.json"),
          pathlib.Path.home() / "Library/Application Support/Google/Chrome/NativeMessagingHosts/com.qubetics.vpn.json"]:
    if not p.exists():
        continue
    m = json.loads(p.read_text())
    origin = f"chrome-extension://{EXT_ID}/"
    if origin not in m["allowed_origins"]:
        m["allowed_origins"].append(origin)
        p.write_text(json.dumps(m, indent=4))
        print("added to", p)
PY
```

Chrome re-reads the manifest on each `connectNative`, so no browser restart is
needed — but the extension caches the port in `persistentNativePort`, which is why
`resetNativePendingState()` nulls it. Reopen the side panel after editing.

---

## 3. A connect, end to end

From `DVpn.jsx` `startConnectionFromNode`:

```
 1. stopAgentTunnel(baseUrl)        best-effort teardown of a stale tunnel
 2. disconnectVpn(...)              cancel any orphaned provider session
 3. connectVpnWithWireguardConfig() backend session → WireGuard config text
 4. findRunningAgent()              → { reachable: true, baseUrl: "native" }
 5. startAgentTunnel({ baseUrl: "native", config })
       port.postMessage({ action: "connect", configContent: config })
       ← { status: "connecting" }           (ignored, no resolver matches)
       ← { status: "connected" }            resolves activeResolvers.connect
 6. isRunning = true                trusted from the connect ack, not re-queried
```

Step 6 matters: on macOS the code deliberately skips the follow-up `getAgentStatus`
call, because a second `status` round-trip would race the polling loop and leave the
spinner stuck. The HTTP path does re-query.

The config in step 3 comes from `buildWireguardConfigFromSessionResponse` in
`src/services/dvpn/wireguard.js` and is passed through to the helper verbatim:

```ini
[Interface]
PrivateKey = <client private key>
Address = <addrs[0] from the decoded provider payload>
DNS = 1.1.1.1
MTU = 1420

[Peer]
PublicKey = <metadata[0].public_key>
AllowedIPs = 0.0.0.0/0,::/0
Endpoint = <result.addrs[0]>:<metadata[0].port>
PersistentKeepalive = 25
```

---

## 4. Timeouts, layer by layer

Four independent timers sit on the same operation. They are not perfectly nested:

| Layer | connect | disconnect | status |
|---|---|---|---|
| `agent.js` | 35s | 35s | 4s in `findRunningAgent`, 5s in `getAgentStatus` |
| `QubeticsNativeHost` | 30s | 30s | 5s |
| helper (`wg-quick` + handshake poll) | ~5s of handshake polling after `wg-quick` returns | — | synchronous |

Two consequences:

- **`findRunningAgent` gives up at 4s, the host at 5s.** On a cold start, where
  `launchd` still has to spawn the root helper, the extension can report
  `reachable: false` for a check the host would have answered a second later. This is
  exactly what the macOS grace period in `checkAgentHealth` papers over — it requires
  two consecutive failures before showing the install screen.
- Connect is 35s in the extension against 30s in the host, so the host's own
  `{"status":"failed","message":"Connection timed out"}` normally wins and the user
  gets a real message instead of a generic one.

---

## 5. Gotchas

**Use a port, never `sendNativeMessage`.** Connect and disconnect each emit two
messages (`connecting`/`disconnecting`, then the result). `sendNativeMessage` only
delivers the first and then tears the process down.

**Each `connectNative` spawns a new host process.** It lives until stdin closes. The
extension keeps one port for the page's lifetime, so closing the side panel kills the
host process.

**Killing the host does not drop the tunnel.** `wg-quick` runs out of the root
LaunchDaemon, which `launchd` keeps independent of the host process. A tunnel brought
up by a side panel that was then closed stays up — that is why the UI re-queries
`status` on mount rather than assuming `disconnected`.

**"connected" means a handshake was recorded, not that the peer is reachable now.**
`isTunnelActive()` reads `wg show all latest-handshakes` and accepts any non-zero
timestamp. A tunnel whose peer died minutes ago still reports `connected` for as long
as the interface is up.

**`disconnect` always reports success.** The helper replies `"VPN Disconnected"`
regardless of `wg-quick`'s exit status, so a failed teardown looks clean to the
extension. Confirm with a follow-up `status` if it matters.

**The host writes debug output to stdout.** `HelperClient.swift` is compiled into the
native-host target (an explicit membership exception in `project.pbxproj`) and calls
`print("Helper response:", response)` and `print("XPC Error:", error)`. Those land on
fd 1 — the same pipe Chrome parses for length-prefixed frames. Swift block-buffers a
piped stdout, so the garbage usually flushes only at process exit and goes unnoticed;
if that 4KB buffer ever fills mid-session, Chrome reads the text as a frame length and
drops the port with no useful error. Any logging added to the host, or to anything it
links, must go to stderr:

```swift
FileHandle.standardError.write("Helper response: \(response)\n".data(using: .utf8)!)
```

---

## 6. Minimal client, for anything that isn't this extension

```js
const connectVpn = (configContent) =>
  new Promise((resolve, reject) => {
    const port = chrome.runtime.connectNative("com.qubetics.vpn");
    const timer = setTimeout(() => {
      port.disconnect();
      reject(new Error("timed out"));
    }, 35000);

    port.onMessage.addListener((msg) => {
      if (msg.status === "connecting") return;       // progress, keep waiting
      clearTimeout(timer);
      port.disconnect();
      msg.status === "connected"
        ? resolve(msg)
        : reject(new Error(msg.message || msg.status || msg.error));
    });

    port.onDisconnect.addListener(() => {
      clearTimeout(timer);
      reject(new Error(chrome.runtime.lastError?.message || "host disconnected"));
    });

    port.postMessage({ action: "connect", configContent });
  });
```

---

## 7. Debugging checklist

1. **Extension console** (side panel → Inspect, or the service worker). The native
   path logs under `[dVPN Native]`, including every message received.
2. **`chrome.runtime.lastError` on disconnect** tells you which failure it is:
   - *Specified native messaging host not found* → manifest missing or wrong profile
   - *Access to the specified native messaging host is forbidden* → ID not in
     `allowed_origins`
   - *Native host has exited* → the host crashed, or its stdout got corrupted
3. **Check which IDs are trusted:**
   ```bash
   cat "/Library/Google/Chrome/NativeMessagingHosts/com.qubetics.vpn.json"
   ```
4. **Watch the helper:**
   ```bash
   log stream --predicate 'subsystem == "com.qubetics.vpn.helper"' --info
   ```
5. **Prove the tunnel independently of the extension:**
   ```bash
   sudo "/Library/Application Support/QubeticsVPN/bin/wg" show
   ```
6. **`error: helper_missing`** is the host telling you
   `/Library/PrivilegedHelperTools/com.qubetics.vpn.helper` is not on disk. Reinstall
   the `.pkg`, or run `/Applications/QubeticsVPN.app` once to `SMJobBless` it.
