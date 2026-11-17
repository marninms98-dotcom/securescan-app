//
//  SimDemo.swift
//  SecureScan
//
//  The app in a simulator (appetize.io, Xcode), where there is no camera and no
//  LiDAR: launched with no SECURESCAN_* settings, it opens the demo job (a
//  simulated house, no client data) with one of every mark and the moisture
//  model, and every camera screen shows the Studio's synthetic room through the
//  real capture HUD - saves, Adjust, the model and looking around all work - so
//  each screen can be clicked through. Debug simulator builds only.
//

import SwiftUI

enum SimDemo {
    /// On in a Debug simulator build launched without automation settings
    /// (SECURESCAN_SIM_DEMO=1 / 0 forces it on / off).
    static var active: Bool {
        #if DEBUG && targetEnvironment(simulator)
        let env = ProcessInfo.processInfo.environment
        if let v = env["SECURESCAN_SIM_DEMO"] { return v == "1" }
        return !env.keys.contains { $0.hasPrefix("SECURESCAN_") }
        #else
        return false
        #endif
    }

    /// The demo job's plan with the 3D tab's demo marks written in (once, at creation), so the
    /// plan, 3D, Items and the moisture model all show them.
    static func addMarks(_ folder: JobFolder) {
        #if DEBUG
        guard let data = try? Data(contentsOf: folder.planURL),
              let plan = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let out = try? PlanDocument.data(DollhouseMarks.withDemoMarks(plan)) else { return }
        try? out.write(to: folder.planURL, options: .atomic)
        #endif
    }
}

/// A camera screen in the simulator: the Studio's room, live.
struct SimCameraView: View {
    let onClose: () -> Void

    var body: some View {
        #if DEBUG
        StudioView(scene: "sim-live", onClose: onClose)
        #else
        VStack(spacing: DS.Space.margin) {
            Text("The camera needs an iPhone").font(DS.Font.headline)
            PrimaryButton("Close") { onClose() }
        }
        .padding(DS.Space.margin)
        #endif
    }
}
