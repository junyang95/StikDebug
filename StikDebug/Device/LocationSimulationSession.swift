import Foundation

/// Owns the actual tunnel and controller used to send location commands.
/// Callers serialize access on LocationSimulationCommandQueue.
final class LocationSimulationSession<Connection, Controller> {
    struct Dependencies {
        let verifyBinding: (Connection) throws -> Void
        let makeController: (Connection) throws -> Controller
        let set: (Controller, Double, Double) throws -> Void
        let clear: (Controller) throws -> Void
        let freeController: (Controller) -> Void
        let freeConnection: (Connection) -> Void
    }

    private let dependencies: Dependencies
    private var identity: String?
    private var connection: Connection?
    private var controller: Controller?

    init(dependencies: Dependencies) { self.dependencies = dependencies }

    func set(identity: String, latitude: Double, longitude: Double,
             connect: () throws -> Connection) throws {
        if self.identity != identity { disconnect() }
        if let controller {
            do {
                try dependencies.set(controller, latitude, longitude)
                return
            } catch {
                // A replacement tunnel must read its own target identity and verify again.
                disconnect()
            }
        }
        do {
            let connection = try connect()
            self.connection = connection
            self.identity = identity
            try dependencies.verifyBinding(connection)
            let controller = try dependencies.makeController(connection)
            self.controller = controller
            try dependencies.set(controller, latitude, longitude)
        } catch {
            disconnect()
            throw error
        }
    }

    /// Recovery never requires a credential, including after an App restart.
    /// Keep an existing target when settings change so its simulated position can be cleared.
    func clear(connect: () throws -> Connection) throws {
        defer { disconnect() }
        if controller == nil {
            let connection = try connect()
            self.connection = connection
            self.controller = try dependencies.makeController(connection)
        }
        if let controller { try dependencies.clear(controller) }
    }

    func disconnect() {
        if let controller { dependencies.freeController(controller) }
        if let connection { dependencies.freeConnection(connection) }
        controller = nil
        connection = nil
        identity = nil
    }
}
