//
//  ContentView.swift
//  VPNDemo
//
//  Created by Gabriele Mondada on 02.03.2024.
//

import SwiftUI

struct ContentView: View {

    @ObservedObject var tunnelViewModel: TunnelViewModel

    var body: some View {
        VStack {
            Toggle("VPN Tunnel", isOn: $tunnelViewModel.isOn)
                .toggleStyle(.switch)
        }
        .padding()
    }
}

#Preview {
    ContentView(tunnelViewModel: TunnelViewModel())
}
