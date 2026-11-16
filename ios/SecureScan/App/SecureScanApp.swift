//
//  SecureScanApp.swift
//  SecureScan
//

import SwiftUI

@main
struct SecureScanApp: App {
    var body: some Scene {
        WindowGroup {
            // >>> UX2 Studio harness (DEBUG only): SECURESCAN_STUDIO=<scene> shows a capture-screen scene for CI screenshots.
            #if DEBUG
            if let scene = StudioLaunch.scene { StudioView(scene: scene) } else { JobsListView().secureSuiteSync() }  // SecureSuite sync hook
            #else
            JobsListView().secureSuiteSync()  // SecureSuite sync hook (docs/SYNC.md)
            #endif
            // <<< UX2 Studio harness
        }
    }
}
