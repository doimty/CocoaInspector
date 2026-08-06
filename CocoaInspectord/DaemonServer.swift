import Darwin
import Dispatch
import Foundation
import XPC

// Use a C-compatible block for XPC event handlers to avoid Swift closure
// PAC signing issues on arm64e iOS 15 (Pointer Authentication Code failure
// when Swift closures are bridged to ObjC blocks for xpc_connection_set_event_handler).
private var sharedDaemonContext: DaemonServer?

private let daemonListenerHandler: @convention(block) (xpc_object_t?) -> Void = { event in
    guard let event else { return }
    autoreleasepool {
        sharedDaemonContext?.accept(event)
    }
}

final class DaemonServer {
    private static let idleExitDelay: DispatchTimeInterval = .seconds(3)

    private let controlQueue = DispatchQueue(
        label: "wiki.qaq.inspector.daemon.control",
        qos: .utility,
        autoreleaseFrequency: .workItem
    )
    private let samplingQueue = DispatchQueue(
        label: "wiki.qaq.inspector.daemon.sampling",
        qos: .utility,
        autoreleaseFrequency: .workItem
    )
    private let authenticator = PeerAuthenticator()
    private let sampler = ProcessSampler()
    private lazy var detailSampler = DetailSampler(processes: sampler)

    private var listener: xpc_connection_t?
    private var activeSession: PeerSession?
    private var idleGeneration: UInt64 = 0

    func start() throws {
        guard listener == nil else { return }
        guard let listener = InspectorProtocol.serviceName.withCString({
            inspectorCreateMachServiceListener(
                $0,
                controlQueue,
                PrivateSystemConstant.machServiceListener
            )
        }) else {
            throw InspectorDataError.transportFailure
        }
        self.listener = listener
        sharedDaemonContext = self

        xpc_connection_set_event_handler(listener, daemonListenerHandler)
        xpc_connection_activate(listener)
    }

    private func accept(_ event: xpc_object_t) {
        guard xpc_get_type(event) == XPC_TYPE_CONNECTION else { return }
        guard activeSession == nil else {
            xpc_connection_cancel(event)
            return
        }

        guard let clientPID = authenticator.authenticate(event) else {
            xpc_connection_cancel(event)
            scheduleIdleExit()
            return
        }

        idleGeneration &+= 1
        let session = PeerSession(
            connection: event,
            clientPID: clientPID,
            controlQueue: controlQueue,
            samplingQueue: samplingQueue,
            sampler: sampler,
            detailSampler: detailSampler
        ) { [weak self] in
            self?.sessionInvalidated()
        }
        activeSession = session
        session.activate()
    }

    private func sessionInvalidated() {
        guard activeSession != nil else { return }
        activeSession = nil
        scheduleIdleExit()
    }

    private func scheduleIdleExit() {
        idleGeneration &+= 1
        let scheduledGeneration = idleGeneration
        controlQueue.asyncAfter(deadline: .now() + Self.idleExitDelay) { [weak self] in
            guard let self,
                  self.activeSession == nil,
                  self.idleGeneration == scheduledGeneration else { return }
            exit(EXIT_SUCCESS)
        }
    }
}
