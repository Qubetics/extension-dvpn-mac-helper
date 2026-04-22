import Foundation
import os.log

class VPNHelperService: NSObject, VPNHelperProtocol {
    private static let log = OSLog(subsystem: "com.qubetics.vpn.helper", category: "VPNHelperService")
    private let configPath = "/usr/local/etc/wireguard/wg0.conf"
    private let interfaceName = "wg0"

    private let wgEnv = ["PATH": "/Library/Application Support/QubeticsVPN/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"]

    private func findExecutable(name: String) -> String? {
        let searchPaths = [
            "/Library/Application Support/QubeticsVPN/bin/\(name)",
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
            "/bin/\(name)"
        ]
        let fileManager = FileManager.default
        for path in searchPaths {
            if fileManager.fileExists(atPath: path) {
                return path
            }
        }
        return nil
    }

    /// Find bash 4+ for running wg-quick.
    /// macOS ships bash 3.2 (GPLv2) but wg-quick requires bash 4+.
    /// We search: bundled bash → Homebrew bash → fall back to /bin/bash (will fail).
    private func findBash4() -> String {
        let candidates = [
            "/Library/Application Support/QubeticsVPN/bin/bash",
            "/opt/homebrew/bin/bash",
            "/usr/local/bin/bash"
        ]
        let fm = FileManager.default
        for path in candidates {
            if fm.fileExists(atPath: path) {
                os_log("Found bash 4+ at: %{public}@", log: VPNHelperService.log, type: .info, path)
                return path
            }
        }
        os_log("WARNING: No bash 4+ found, falling back to /bin/bash (wg-quick may fail)",
               log: VPNHelperService.log, type: .error)
        return "/bin/bash"
    }

    func isTunnelActive() -> Bool {
        guard let wgPath = findExecutable(name: "wg") else { return false }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: wgPath)
        // Use "all" instead of "wg0" because macOS wireguard-go names interfaces utunX
        process.arguments = ["show", "all", "latest-handshakes"]

        let pipe = Pipe()
        process.standardOutput = pipe

        try? process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // Output format: "utunX\tpeer_pubkey\ttimestamp"
        // If timestamp is "0" or empty, no handshake has occurred yet
        let lines = output.components(separatedBy: "\n")
        for line in lines {
            let parts = line.components(separatedBy: "\t")
            if let timestamp = parts.last, !timestamp.isEmpty, timestamp != "0" {
                return true
            }
        }
        return false
    }

    func isInterfaceUp() -> Bool {
        // Check if any wireguard-go socket exists (interface is up)
        let fm = FileManager.default
        let sockDir = "/var/run/wireguard"
        guard let files = try? fm.contentsOfDirectory(atPath: sockDir) else { return false }
        return files.contains { $0.hasSuffix(".sock") }
    }

    private func ensureSocketDirectory() {
        let sockDir = "/var/run/wireguard"
        let fm = FileManager.default
        if !fm.fileExists(atPath: sockDir) {
            try? fm.createDirectory(atPath: sockDir, withIntermediateDirectories: true)
            var attrs = [FileAttributeKey: Any]()
            attrs[.posixPermissions] = 0o755
            try? fm.setAttributes(attrs, ofItemAtPath: sockDir)
        }
    }

    func connectVPN(configContent: String, reply: @escaping (String) -> Void) {
        os_log("connectVPN started", log: VPNHelperService.log, type: .info)

        guard let wgQuickPath = findExecutable(name: "wg-quick") else {
            reply("Error: wg-quick not found")
            return
        }

        // Run in background to avoid blocking the XPC queue
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            let configDir = "/usr/local/etc/wireguard"
            let fileManager = FileManager.default
            
            if !fileManager.fileExists(atPath: configDir) {
                try? fileManager.createDirectory(atPath: configDir, withIntermediateDirectories: true)
                var attrs = [FileAttributeKey: Any]()
                attrs[.posixPermissions] = 0o700
                try? fileManager.setAttributes(attrs, ofItemAtPath: configDir)
            }

            // Write and secure config
            do {
                try configContent.write(toFile: self.configPath, atomically: true, encoding: .utf8)
                var attrs = [FileAttributeKey: Any]()
                attrs[.posixPermissions] = 0o600
                try fileManager.setAttributes(attrs, ofItemAtPath: self.configPath)
            } catch {
                reply("Error writing config file: \(error.localizedDescription)")
                return
            }

            // Find bash 4+ to invoke wg-quick through (bypasses shebang)
            let bashPath = self.findBash4()

            // Cleanup existing interface gracefully
            let downProcess = Process()
            downProcess.executableURL = URL(fileURLWithPath: bashPath)
            downProcess.arguments = [wgQuickPath, "down", self.interfaceName]
            downProcess.environment = self.wgEnv
            try? downProcess.run()
            downProcess.waitUntilExit()

            // Also ensure socket directory exists
            self.ensureSocketDirectory()

            Thread.sleep(forTimeInterval: 0.5)

            // Up — invoke: bash4 /path/to/wg-quick up wg0
            let process = Process()
            process.executableURL = URL(fileURLWithPath: bashPath)
            process.arguments = [wgQuickPath, "up", self.interfaceName]
            process.environment = self.wgEnv
            
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            
            do {
                try process.run()
                process.waitUntilExit()
                
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                os_log("wg-quick output: %{public}@", log: VPNHelperService.log, type: .info, output)

                if process.terminationStatus == 0 {
                    // ... (rest of the handshake check loop)
                    for _ in 1...10 {
                        Thread.sleep(forTimeInterval: 0.5)
                        if self.isTunnelActive() {
                            reply("VPN Connected")
                            return
                        }
                    }
                    
                    // If we reach here, handshake failed. 
                    reply("VPN Connection Failed: Handshake Timeout. Output: \(output)")
                } else {
                    reply("VPN Connection Failed. Status: \(process.terminationStatus). Output: \(output)")
                }
            } catch {
                reply("Error running wg-quick: \(error.localizedDescription)")
            }
        }
    }

    func disconnectVPN(reply: @escaping (String) -> Void) {
        os_log("disconnectVPN started", log: VPNHelperService.log, type: .info)
        guard let wgQuickPath = findExecutable(name: "wg-quick") else {
            reply("Error: wg-quick not found")
            return
        }
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let bashPath = self.findBash4()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: bashPath)
            process.arguments = [wgQuickPath, "down", self.interfaceName]
            process.environment = self.wgEnv
            try? process.run()
            process.waitUntilExit()
            reply("VPN Disconnected")
        }
    }

    func vpnStatus(reply: @escaping (String) -> Void) {
        if isTunnelActive() {
            reply("connected")
        } else if isInterfaceUp() {
            reply("connecting")
        } else {
            reply("disconnected")
        }
    }
}
