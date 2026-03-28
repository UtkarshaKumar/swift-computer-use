import GRPCCore
import GRPCProtobuf
import Foundation

// SDDServiceImpl registers all four RPC handlers from sdd.proto.
// All handlers use StreamingServerRequest/StreamingServerResponse (grpc-swift 2.x API).
// StreamWorldState is server-streaming; the others are unary.
struct SDDServiceImpl: RegistrableRPCService {
    func registerMethods<Transport: ServerTransport>(with router: inout RPCRouter<Transport>) {

        // Unary: GetElementTree — returns root element stub; real AX tree wired in Phase 2
        router.registerHandler(
            forMethod: MethodDescriptor(
                service: ServiceDescriptor(fullyQualifiedService: "sdd.SDD"),
                method: "GetElementTree"
            ),
            deserializer: ProtobufDeserializer<Sdd_GetElementTreeRequest>(),
            serializer: ProtobufSerializer<Sdd_ElementTree>()
        ) { request, _ in
            var root = Sdd_Element()
            root.id = "root"
            root.role = "AXApplication"
            root.title = "SDD"
            root.isEnabled = true

            var tree = Sdd_ElementTree()
            tree.rootElementID = root.id
            tree.nodes = [root]
            return StreamingServerResponse(single: ServerResponse(message: tree))
        }

        // Unary: ExecuteAction — echoes element_id back; real ActionExecutor wired in Phase 2
        router.registerHandler(
            forMethod: MethodDescriptor(
                service: ServiceDescriptor(fullyQualifiedService: "sdd.SDD"),
                method: "ExecuteAction"
            ),
            deserializer: ProtobufDeserializer<Sdd_ActionRequest>(),
            serializer: ProtobufSerializer<Sdd_ActionResult>()
        ) { request, _ in
            var req = Sdd_ActionRequest()
            for try await msg in request.messages { req = msg; break }
            var result = Sdd_ActionResult()
            result.success = true
            result.elementID = req.elementID
            result.timestampMs = Int64(Date().timeIntervalSince1970 * 1000)
            return StreamingServerResponse(single: ServerResponse(message: result))
        }

        // Unary: GetScreenshot — empty payload stub; real ScreenCaptureKit wired in Phase 2
        router.registerHandler(
            forMethod: MethodDescriptor(
                service: ServiceDescriptor(fullyQualifiedService: "sdd.SDD"),
                method: "GetScreenshot"
            ),
            deserializer: ProtobufDeserializer<Sdd_ScreenshotRequest>(),
            serializer: ProtobufSerializer<Sdd_Screenshot>()
        ) { request, _ in
            var req = Sdd_ScreenshotRequest()
            for try await msg in request.messages { req = msg; break }
            var screenshot = Sdd_Screenshot()
            screenshot.format = req.format.isEmpty ? "png" : req.format
            screenshot.timestampMs = Int64(Date().timeIntervalSince1970 * 1000)
            return StreamingServerResponse(single: ServerResponse(message: screenshot))
        }

        // Server-streaming: StreamWorldState
        // Emits one full-refresh diff then closes. WorldModel subscription wired in Phase 2.
        router.registerHandler(
            forMethod: MethodDescriptor(
                service: ServiceDescriptor(fullyQualifiedService: "sdd.SDD"),
                method: "StreamWorldState"
            ),
            deserializer: ProtobufDeserializer<Sdd_StreamRequest>(),
            serializer: ProtobufSerializer<Sdd_WorldStateDiff>()
        ) { request, _ in
            return StreamingServerResponse(of: Sdd_WorldStateDiff.self) { writer in
                var diff = Sdd_WorldStateDiff()
                diff.timestampMs = Int64(Date().timeIntervalSince1970 * 1000)
                diff.fullRefresh = true
                try await writer.write(diff)
                return [:]
            }
        }
    }
}
