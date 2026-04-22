//
//  VPNHelperProtocol.swift
//  QubeticsVPN
//
//  Created by ShashiATR467 on 09/03/26.
//

import Foundation

@objc public protocol VPNHelperProtocol {

    func connectVPN(configContent: String, reply: @escaping (String) -> Void)

    func disconnectVPN(reply: @escaping (String) -> Void)

    func vpnStatus(reply: @escaping (String) -> Void)
}
