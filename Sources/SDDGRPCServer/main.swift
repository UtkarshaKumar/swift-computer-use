import GRPCCore
import GRPCNIOTransportHTTP2
import Foundation

// SDD gRPC server — listens on 0.0.0.0:7800 (plaintext HTTP/2)
// All four SDD RPC methods registered; StreamWorldState stub emits one diff then closes.
// Phase 2 wires in WorldModel events and ScreenCaptureKit.
//
// NOTE: @main cannot be used in main.swift (top-level code file); use Task + RunLoop instead.
let server = GRPCServer(
    transport: .http2NIOPosix(
        address: .ipv4(host: "0.0.0.0", port: 7800),
        transportSecurity: .plaintext
    ),
    services: [SDDServiceImpl()]
)

print("SDD gRPC server v0.1.0 — listening on 0.0.0.0:7800")
print("Methods: GetElementTree, ExecuteAction, GetScreenshot, StreamWorldState")

Task {
    do {
        try await server.serve()
    } catch {
        print("Server error: \(error)")
        exit(1)
    }
}

RunLoop.main.run()
