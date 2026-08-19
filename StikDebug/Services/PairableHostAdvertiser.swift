import Foundation
import Network

/// Publishes the iOS 27 pairable-host service and relays the Settings
/// connection to idevice's loopback listener.
final class PairableHostAdvertiser {
    private var listener: NWListener?
    private var activeRelay: PairingRelayPipe?
    private var loopbackPort: UInt16 = 0

    func publish(
        port: UInt16,
        serviceIdentifier: String,
        name: String,
        model: String,
        authTag: String,
        version: String,
        minimumVersion: String
    ) {
        stop()
        loopbackPort = port

        var txt = NWTXTRecord()
        txt["name"] = name
        txt["identifier"] = serviceIdentifier
        txt["authTag"] = authTag
        txt["model"] = model
        txt["flags"] = "1"
        txt["ver"] = version
        txt["minVer"] = minimumVersion

        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.includePeerToPeer = true

            let listener = try NWListener(using: parameters)
            listener.service = NWListener.Service(
                name: serviceIdentifier,
                type: "_remotepairing-pairable-host._tcp",
                domain: "local",
                txtRecord: txt
            )
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    LogManager.shared.addInfoLog("本机配对服务已发布")
                case .failed(let error):
                    LogManager.shared.addErrorLog("本机配对服务发布失败：\(error.localizedDescription)")
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.relay(connection)
            }
            listener.start(queue: .global(qos: .userInitiated))
            self.listener = listener
        } catch {
            LogManager.shared.addErrorLog("本机配对监听失败：\(error.localizedDescription)")
        }
    }

    func stop() {
        activeRelay?.cancel()
        activeRelay = nil
        listener?.cancel()
        listener = nil
    }

    private func relay(_ inbound: NWConnection) {
        activeRelay?.cancel()
        guard loopbackPort > 0,
              let port = NWEndpoint.Port(rawValue: loopbackPort) else {
            inbound.cancel()
            return
        }

        let outbound = NWConnection(host: NWEndpoint.Host("127.0.0.1"), port: port, using: .tcp)
        let pipe = PairingRelayPipe(inbound: inbound, outbound: outbound)
        activeRelay = pipe
        pipe.start()
    }
}

private final class PairingRelayPipe {
    private let inbound: NWConnection
    private let outbound: NWConnection
    private let queue = DispatchQueue(label: "com.pikminhelper.pairing.relay")

    init(inbound: NWConnection, outbound: NWConnection) {
        self.inbound = inbound
        self.outbound = outbound
    }

    func start() {
        inbound.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.cancel() }
            if case .cancelled = state { self?.cancel() }
        }
        outbound.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.pump(from: self.inbound, to: self.outbound)
                self.pump(from: self.outbound, to: self.inbound)
            case .failed, .cancelled:
                self.cancel()
            default:
                break
            }
        }
        inbound.start(queue: queue)
        outbound.start(queue: queue)
    }

    func cancel() {
        inbound.cancel()
        outbound.cancel()
    }

    private func pump(from: NWConnection, to: NWConnection) {
        from.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            if error != nil {
                self.cancel()
                return
            }
            guard let data, !data.isEmpty else {
                if complete { self.cancel() } else { self.pump(from: from, to: to) }
                return
            }
            to.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if error != nil || complete {
                    self.cancel()
                } else {
                    self.pump(from: from, to: to)
                }
            })
        }
    }
}
