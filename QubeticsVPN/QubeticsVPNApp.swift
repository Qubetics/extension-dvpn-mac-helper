//
//  QubeticsVPNApp.swift
//  QubeticsVPN
//
//  Created by ShashiATR467 on 09/03/26.
//

import SwiftUI

@main
struct QubeticsVPNApp: App {
    
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        // A truly headless app cannot have a WindowGroup on launch. 
        // We use Settings to ensure no main window pops up.
        Settings {
            EmptyView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        
        // Hide the application completely (from the Dock and menubar) 
        // if Info.plist LSUIElement is not set.
        NSApp.setActivationPolicy(.prohibited)
        
        print("Starting Headless Helper Installation...")
        
        let success = HelperInstaller.installHelper()
        if success {
            print("Helper installed. Quitting.")
        } else {
            print("Helper installation failed. Quitting.")
        }
        
        // Terminate immediately after the password prompt is resolved
        NSApp.terminate(nil)
    }
}
