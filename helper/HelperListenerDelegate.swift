//
//  HelperListenerDelegate.swift
//  QubeticsVPN
//
//  Created by ShashiATR467 on 09/03/26.
//

import Foundation

class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {

        let exportedObject = VPNHelperService()

        newConnection.exportedInterface = NSXPCInterface(with: VPNHelperProtocol.self)
        newConnection.exportedObject = exportedObject

        newConnection.resume()

        return true
    }
}
