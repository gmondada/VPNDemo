//
//  ExtensionActivationManager.swift
//  VPNDemo
//
//  Created by Gabriele Mondada on 06.03.2024.
//

import Foundation
import OSLog
import SystemExtensions

private let log = OSLog(subsystem: "ch.ijk.VPNDemo", category: "ExtensionActivationManager")

@MainActor
class ExtensionActivationManager: NSObject {

    static let shared = ExtensionActivationManager()

    func activate() {
        let activationRequest = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: "ch.ijk.VPNDemo.NetExt", queue: .main)
        activationRequest.delegate = self

        OSSystemExtensionManager.shared.submitRequest(activationRequest)
    }

    func deactivate() {
        let deactivationRequest = OSSystemExtensionRequest.deactivationRequest(forExtensionWithIdentifier: "ch.ijk.VPNDemo.NetExt", queue: .main)
        deactivationRequest.delegate = self

        OSSystemExtensionManager.shared.submitRequest(deactivationRequest)
    }
}

extension ExtensionActivationManager: OSSystemExtensionRequestDelegate {
    func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties, withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        os_log("request:actionForReplacingExtension:withExtension", log: log)
        return .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        os_log("requestNeedsUserApproval", log: log)
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        os_log("request succeeded: result=%@", log: log, String(describing: result))
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        os_log("request failed: result=%@", log: log, String(describing: error))
    }
}
