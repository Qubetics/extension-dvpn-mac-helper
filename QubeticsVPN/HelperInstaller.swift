//
//  HelperInstaller.swift
//  QubeticsVPN
//
//  Created by ShashiATR467 on 09/03/26.
//

import Foundation
import ServiceManagement
import Security

class HelperInstaller {

    static func installHelper() -> Bool {

        var authRef: AuthorizationRef?

        let status = AuthorizationCreate(nil,
                                         nil,
                                         [],
                                         &authRef)

        if status != errAuthorizationSuccess {
            print("Authorization failed")
            return false
        }

        var error: Unmanaged<CFError>?

        let blessResult = SMJobBless(kSMDomainSystemLaunchd,
                                     "com.qubetics.vpn.helper" as CFString,
                                     authRef,
                                     &error)

        if blessResult {
            print("Helper installed successfully")
            return true
        } else {
            print("Helper installation failed")

            if let error = error?.takeRetainedValue() {
                print(error)
            }
            return false
        }
    }
}
