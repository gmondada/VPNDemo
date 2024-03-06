//
//  TunnelViewModel.swift
//  VPNDemo
//
//  Created by Gabriele Mondada on 06.03.2024.
//

import Foundation
import Combine

@MainActor
class TunnelViewModel: ObservableObject {

    @Published var isOn: Bool = false {
        didSet {
            if !fromDataModel {
                if isOn {
                    TunnelManager.shared.start();
                } else {
                    TunnelManager.shared.stop();
                }
            }
        }
    }

    private var fromDataModel = false
    private var subscription: Cancellable?

    init() {
        subscription = TunnelManager.shared.statePublisher.sink { [weak self] state in
            if let self {
                self.fromDataModel = true
                switch state {
                case .detecting, .disconnected, .disconnecting:
                    self.isOn = false
                case .connecting, .connected:
                    self.isOn = true
                }
                self.fromDataModel = false
            }
        }
    }
}
