//
//  HelperClient.swift
//  QubeticsVPN
//
//  Created by ShashiATR467 on 09/03/26.
//

import Foundation

class HelperClient {

    static let shared = HelperClient()

    private var connection: NSXPCConnection?

    private init() {
        connect()
    }

    private func connect() {

        connection = NSXPCConnection(
            machServiceName: "com.qubetics.vpn.helper",
            options: .privileged
        )

        connection?.remoteObjectInterface =
            NSXPCInterface(with: VPNHelperProtocol.self)

        connection?.invalidationHandler = {
            print("XPC connection invalidated")
        }

        connection?.interruptionHandler = {
            print("XPC connection interrupted")
        }

        connection?.resume()
    }
    func connectVPN(configContent: String, completion: @escaping (String) -> Void) {

        let proxy = connection?.remoteObjectProxyWithErrorHandler { error in
            print("XPC Error:", error)
            completion("XPC Error: \(error.localizedDescription)")
        } as? VPNHelperProtocol

        proxy?.connectVPN(configContent: configContent) { response in
            print("Helper response:", response)
            completion(response)
        }
    }

    func disconnectVPN(completion: @escaping (String) -> Void) {

        let proxy = connection?.remoteObjectProxyWithErrorHandler { error in
            print("XPC Error:", error)
            completion("XPC Error: \(error.localizedDescription)")
        } as? VPNHelperProtocol

        proxy?.disconnectVPN { response in
            print("Helper response:", response)
            completion(response)
        }
    }

    func vpnStatus(completion: @escaping (String) -> Void) {

        let proxy = connection?.remoteObjectProxyWithErrorHandler { error in
            print("XPC Error:", error)
            completion("error: helper_missing")
        } as? VPNHelperProtocol

        proxy?.vpnStatus { response in
            completion(response)
        }
    }
}
