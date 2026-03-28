import Foundation
import GRPCCore
import GRPCInProcessTransport
import SwiftProtobuf

let inProcess = InProcessTransport()
let server = GRPCServer(transport: inProcess.server, services: [])

print("SDD gRPC server starting on localhost:7800...")

Task {
    do {
        try await server.serve()
        print("SDD gRPC server started")
        print("Version: 0.1.0")
    } catch {
        print("Server error: \(error)")
    }
}

RunLoop.current.run()
