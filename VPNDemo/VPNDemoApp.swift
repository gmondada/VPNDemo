//
//  VPNDemoApp.swift
//  VPNDemo
//
//  Created by Gabriele Mondada on 02.03.2024.
//

import SwiftUI

@main @MainActor
struct VPNDemoApp: App {

    let model = TunnelViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(tunnelViewModel: model)
        }
    }
}
