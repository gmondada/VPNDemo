//
//  TunnelManager.swift
//  VPNDemo
//
//  Created by Gabriele Mondada on 02.03.2024.
//

import Foundation
import NetworkExtension
import OSLog
import Combine

private let log = OSLog(subsystem: "ch.ijk.VPNDemo", category: "TunnelManager")

@MainActor
class TunnelManager {

    enum State {
        case detecting
        case disconnected
        case connecting
        case connected
        case disconnecting
    }

    enum TunnelError: Error {
        case tunnelCreationFailure
    }

    private enum Request {
        case none
        case detect
        case start
        case stop
    }

    private enum InternalState {
        case waitingRequest
        case processingRequest
        case waitingStableState
    }

    static let shared = TunnelManager()

    private var stateSubject = CurrentValueSubject<State, Never>(State.detecting)
    var state: State { stateSubject.value }
    var statePublisher: AnyPublisher<State, Never> { stateSubject.eraseToAnyPublisher() }
    
    private var errorSubject = PassthroughSubject<Error, Never>()
    var errorPublisher: AnyPublisher<Error, Never> { errorSubject.eraseToAnyPublisher() }

    private var configuration: NETunnelProviderManager?
    private var request = Request.detect
    private var processingRequest = Request.detect
    private var internalState = InternalState.waitingRequest
    private var connectionStateObserver: NSObjectProtocol?
    private var requestsForRunningStateMachine = 0

    func start() {
        request = .start
        runStateMachine()
    }

    func stop() {
        request = .stop
        runStateMachine()
    }

    private init() {
        request = .detect
        runStateMachine()
    }

    /**
     * This can be called at any moment. It is typically invoked each time there is a new request and
     * each time the tunnel state changes.
     */
    private func runStateMachine() {
        if requestsForRunningStateMachine == 1 {
            requestsForRunningStateMachine = 2
        } else if requestsForRunningStateMachine == 0 {
            requestsForRunningStateMachine = 1
            Task { @MainActor in
                while requestsForRunningStateMachine > 0 {
                    let nextInternalState: InternalState
                    switch internalState {
                    case .waitingRequest:
                        nextInternalState = await runWaitingRequestState()
                    case .processingRequest:
                        nextInternalState = await runProcessingRequestState()
                    case .waitingStableState:
                        nextInternalState = await runWaitingStableStateState()
                    }

                    if internalState != nextInternalState {
                        internalState = nextInternalState
                    } else {
                        requestsForRunningStateMachine -= 1
                    }
                    updatePublicState()
                }
            }
        }
    }

    private func runWaitingRequestState() async -> InternalState {
        if request != .none {
            processingRequest = request
            request = .none
            return .processingRequest
        } else {
            return .waitingRequest
        }
    }

    private func runProcessingRequestState() async -> InternalState {
        if processingRequest == .detect {
            // just detect, no problem if there is no configuration
            if configuration == nil {
                if let configuration = try? await getMainConfiguration() {
                    self.configuration = configuration
                    registerConnectionStateObserver(connection: configuration.connection)
                }
            }
            return .waitingRequest
        }

        if configuration?.connection.status == .invalid {
            // this configuration has probably been removed by the user in the System Settings
            configuration = nil
            unregisterConnectionStateObserver()
        }

        if configuration == nil && (processingRequest == .start || processingRequest == .stop) {
            // we need a valid configuration and if there is no one, we need to create it
            do {
                if let configuration = try await getMainConfiguration() {
                    self.configuration = configuration
                    registerConnectionStateObserver(connection: configuration.connection)
                } else {
                    try await removeAllConfigurations()
                    try await createMainConfiguration()
                    if let configuration = try await getMainConfiguration() {
                        self.configuration = configuration
                        registerConnectionStateObserver(connection: configuration.connection)
                    } else {
                        throw TunnelError.tunnelCreationFailure
                    }
                }
            } catch {
                errorSubject.send(error)
                return .waitingRequest
            }
        }

        if let configuration {
            if processingRequest == .start {
                do {
                    try configuration.connection.startVPNTunnel()
                    return .waitingStableState
                } catch {
                    errorSubject.send(error)
                    return .waitingRequest
                }
            }
            if processingRequest == .stop {
                configuration.connection.stopVPNTunnel()
                return .waitingStableState
            }
        }

        return .waitingRequest
    }

    private func runWaitingStableStateState() async -> InternalState {
        let connectionState = configuration?.connection.status ?? .disconnected
        let transitioning = connectionState == .connecting || connectionState == .disconnecting || connectionState == .reasserting
        if transitioning {
            return .waitingStableState
        } else {
            return .waitingRequest
        }
    }

    private func updatePublicState() {
        let connectionState = configuration?.connection.status ?? .invalid
        let transitioning = connectionState == .connecting || connectionState == .disconnecting || connectionState == .reasserting
        if transitioning && request == .start {
            // we prefer publishing a state which correspond to the waiting request
            stateSubject.value = .connecting
        } else if transitioning && request == .stop {
            // we prefer publishing a state which correspond to the waiting request
            stateSubject.value = .disconnecting
        } else {
            stateSubject.value = state(from: connectionState)
        }
    }

    private func removeAllConfigurations() async throws {
        let configurations = try await NETunnelProviderManager.loadAllFromPreferences()
        for configuration in configurations {
            configuration.connection.stopVPNTunnel()
            try await configuration.removeFromPreferences()
        }
    }

    private func createMainConfiguration() async throws {
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = "ch.ijk.VPNDemo.NetExt" // does not seem to be useful
        proto.serverAddress = "TunnelServer" // we need one, it's diplayed in System Settings, but it's not really used

        let manager = NETunnelProviderManager()
        manager.protocolConfiguration = proto
        manager.localizedDescription = "Demo VPN Tunnel"
        manager.isEnabled = true

        try await manager.saveToPreferences()
    }

    private func getMainConfiguration() async throws -> NETunnelProviderManager? {
        let configurations = try await NETunnelProviderManager.loadAllFromPreferences()
        if configurations.count == 1, let configuration = configurations.first, configuration.protocolConfiguration is NETunnelProviderProtocol {
            return configuration
        } else {
            return nil
        }
    }

    private func state(from connectionState: NEVPNStatus) -> State {
        switch connectionState {
        case .invalid:
            return .disconnected
        case .disconnected:
            return .disconnected
        case .connecting:
            return .connecting
        case .connected:
            return .connected
        case .reasserting:
            return .connecting
        case .disconnecting:
            return .disconnecting
        @unknown default:
            return .disconnected
        }
    }

    private func registerConnectionStateObserver(connection: NEVPNConnection) {
        unregisterConnectionStateObserver()
        connectionStateObserver = NotificationCenter.default.addObserver(forName: NSNotification.Name.NEVPNStatusDidChange, object: connection, queue: nil, using: { [weak self] notification in
            if let self {
                DispatchQueue.main.async {
                    self.runStateMachine()
                }
            }
        })
    }

    private func unregisterConnectionStateObserver() {
        if let connectionStateObserver {
            NotificationCenter.default.removeObserver(connectionStateObserver)
        }
        connectionStateObserver = nil
    }
}
