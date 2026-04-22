//
//  main.swift
//  helper
//
//  Created by ShashiATR467 on 09/03/26.
//

import Foundation

let delegate = HelperListenerDelegate()

let listener = NSXPCListener(machServiceName: "com.qubetics.vpn.helper")

listener.delegate = delegate

listener.resume()

print("VPN Helper is running...")

RunLoop.main.run()

