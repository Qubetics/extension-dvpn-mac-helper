//
//  main.swift
//  QubeticsNativeHost
//
//  Created by ShashiATR467 on 11/03/26.
//

import Foundation

 if CommandLine.arguments.contains("--test") {

     let helper = HelperClient.shared
     helper.connectVPN(configContent: "test") { response in
         print("Test response: \(response)")
     }

     print("Test message sent to helper")

     sleep(2)
     exit(0)
 }

// Static WireGuard config for testing
// let staticConfig = """
// [Interface]
// PrivateKey = +L/SYj7k96JBNIQmBaG1a/RoKBCkceX/7b5a/wGsxWc=
// Address = 10.8.0.2/32
// DNS = 1.1.1.1,8.8.8.8,9.9.9.9
// MTU = 1300

// [Peer]
// PublicKey = klVLHSfHxQ8IM/7vVT+6dBjjBloIVYZ4JQGHzSPagxY=
// AllowedIPs = 0.0.0.0/0
// Endpoint = 13.60.226.99:51820
// PersistentKeepalive = 25
// """
// let staticConfig = """
// [Interface]
// PrivateKey = +L/SYj7k96JBNIQmBaG1a/RoKBCkceX/7b5a/wGsxWc=
// Address = 10.8.0.2/32
// ListenPort = 51820
// DNS = 1.1.1.1,8.8.8.8,9.9.9.9
// MTU = 1300
// [Peer]
// PublicKey = klVLHSfHxQ8IM/7vVT+6dBjjBloIVYZ4JQGHzSPagxY=
// AllowedIPs = 10.8.0.0/24
// Endpoint = 13.60.226.99:51820
// PersistentKeepalive = 25
// """


func readMessage() -> Data? {
    let stdin = FileHandle.standardInput

    let lengthData = stdin.readData(ofLength: 4)
    if lengthData.count != 4 { return nil }

    let length = lengthData.withUnsafeBytes { $0.load(as: UInt32.self) }

    return stdin.readData(ofLength: Int(length))
}

func sendMessage(_ message: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: message)
    var length = UInt32(data.count)

    let stdout = FileHandle.standardOutput
    stdout.write(Data(bytes: &length, count: 4))
    stdout.write(data)
}

while let messageData = readMessage() {

    if let json = try? JSONSerialization.jsonObject(with: messageData) as? [String: Any],
       let action = json["action"] as? String {

        switch action {

        case "connect":

            // Send immediate "connecting" status
            // let configContent = json["configContent"] as? String ?? staticConfig
            guard let configContent = json["configContent"] as? String else {
                sendMessage([
                    "status": "failed",
                    "message": "No config received from extension"
                ])
                continue
            }
            sendMessage(["status": "connecting"])

            // Wait for the helper to finish wg-quick
            let semaphore = DispatchSemaphore(value: 0)
            var helperResponse = ""

            HelperClient.shared.connectVPN(configContent: configContent) { response in
                helperResponse = response
                semaphore.signal()
            }

            // Wait up to 30 seconds for wg-quick to finish
            let result = semaphore.wait(timeout: .now() + 30)

            if result == .timedOut {
                sendMessage(["status": "failed", "message": "Connection timed out"])
            } else if helperResponse.contains("Connected") {
                sendMessage(["status": "connected", "message": helperResponse])
            } else {
                sendMessage(["status": "failed", "message": helperResponse])
            }

        case "disconnect":

            sendMessage(["status": "disconnecting"])

            let semaphore = DispatchSemaphore(value: 0)
            var helperResponse = ""

            HelperClient.shared.disconnectVPN { response in
                helperResponse = response
                semaphore.signal()
            }

            let result = semaphore.wait(timeout: .now() + 30)

            if result == .timedOut {
                sendMessage(["status": "failed", "message": "Disconnection timed out"])
            } else if helperResponse.contains("Disconnected") {
                sendMessage(["status": "disconnected", "message": helperResponse])
            } else {
                sendMessage(["status": "failed", "message": helperResponse])
            }

        case "status":
            // Check if helper exists on disk first for reliability
            let helperPath = "/Library/PrivilegedHelperTools/com.qubetics.vpn.helper"
            if !FileManager.default.fileExists(atPath: helperPath) {
                sendMessage(["status": "error: helper_missing"])
                continue
            }

            let semaphore = DispatchSemaphore(value: 0)
            var vpnState = "disconnected"

            HelperClient.shared.vpnStatus { response in
                vpnState = response
                semaphore.signal()
            }

            let result = semaphore.wait(timeout: .now() + 5)

            if result == .timedOut {
                sendMessage(["status": "disconnected"])
            } else {
                sendMessage(["status": vpnState])
            }

        default:

            sendMessage([
                "error": "unknown action"
            ])
        }
    }
}
