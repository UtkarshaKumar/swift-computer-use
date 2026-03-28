import Foundation
import ArgumentParser
import SwiftProtobuf

struct SDD: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sdd",
        abstract: "CLI client for Semantic Display Daemon",
        subcommands: [Click.self, Type.self, Scroll.self, Stream.self, Status.self]
    )
}

struct Click: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "click",
        abstract: "Click an element by label"
    )
    
    @Option(name: .long, help: "Label of the element to click")
    var label: String
    
    func run() throws {
        var request = Sdd_ClickRequest()
        request.label = label
        
        let response: Sdd_ActionResponse = try performGRPCCall(
            method: "/sdd.SDD/Click",
            request: request
        )
        
        if response.success {
            print("Clicked: \(label)")
        } else {
            fputs("Error: \(response.error)\n", stderr)
            throw ExitCode(1)
        }
    }
}

struct Type: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "type",
        abstract: "Type text into a field"
    )
    
    @Option(name: .long, help: "Label of the field")
    var field: String
    
    @Option(name: .long, help: "Text to type")
    var value: String
    
    func run() throws {
        var request = Sdd_TypeRequest()
        request.field = field
        request.value = value
        
        let response: Sdd_ActionResponse = try performGRPCCall(
            method: "/sdd.SDD/Type",
            request: request
        )
        
        if response.success {
            print("Typed '\(value)' into: \(field)")
        } else {
            fputs("Error: \(response.error)\n", stderr)
            throw ExitCode(1)
        }
    }
}

struct Scroll: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scroll",
        abstract: "Scroll in a direction"
    )
    
    @Option(name: .long, help: "Scroll direction (up or down)")
    var direction: ScrollDirection
    
    @Option(name: .long, help: "Amount to scroll")
    var amount: Int
    
    func run() throws {
        var request = Sdd_ScrollRequest()
        request.direction = direction == .up ? .up : .down
        request.amount = Int32(amount)
        
        let response: Sdd_ActionResponse = try performGRPCCall(
            method: "/sdd.SDD/Scroll",
            request: request
        )
        
        if response.success {
            print("Scrolled \(direction.rawValue) \(amount) units")
        } else {
            fputs("Error: \(response.error)\n", stderr)
            throw ExitCode(1)
        }
    }
}

enum ScrollDirection: String, CaseIterable, ExpressibleByArgument {
    case up
    case down
}

struct Stream: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stream",
        abstract: "Stream WorldModel diffs as JSON lines"
    )
    
    func run() throws {
        let request = Sdd_StreamRequest()
        
        try streamGRPCCall(method: "/sdd.SDD/Stream", request: request) { diff in
            print(diff.jsonDiff)
        }
    }
}

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Print focused app and element"
    )
    
    func run() throws {
        let request = Sdd_StatusRequest()
        
        let response: Sdd_StatusResponse = try performGRPCCall(
            method: "/sdd.SDD/Status",
            request: request
        )
        
        if !response.error.isEmpty {
            fputs("Error: \(response.error)\n", stderr)
            throw ExitCode(1)
        }
        
        print("Focused App: \(response.focusedApp)")
        print("Focused Element: \(response.focusedElement)")
    }
}

private let host = "localhost"
private let port = 7800

private func performGRPCCall<Message: SwiftProtobuf.Message, Response: SwiftProtobuf.Message>(
    method: String,
    request: Message
) throws -> Response {
    let url = URL(string: "http://\(host):\(port)\(method)")!
    var urlRequest = URLRequest(url: url)
    urlRequest.httpMethod = "POST"
    urlRequest.setValue("application/grpc", forHTTPHeaderField: "content-type")
    urlRequest.setValue("trailers", forHTTPHeaderField: "te")
    
    let requestData = try request.jsonUTF8Data()
    
    var grpcData = Data()
    grpcData.append(contentsOf: withUnsafeBytes(of: UInt32(requestData.count).bigEndian) { Array($0) })
    grpcData.append(requestData)
    
    urlRequest.httpBody = grpcData
    
    var responseData: Data?
    var responseError: Error?
    let semaphore = DispatchSemaphore(value: 0)
    
    let task = URLSession.shared.dataTask(with: urlRequest) { data, _, error in
        responseData = data
        responseError = error
        semaphore.signal()
    }
    task.resume()
    semaphore.wait()
    
    if let error = responseError {
        throw error
    }
    
    guard let data = responseData else {
        throw GRPCError(info: "No response data")
    }
    
    guard data.count > 5 else {
        throw GRPCError(info: "Response too short")
    }
    
    let responseDataWithoutHeader = data.subdata(in: 5..<data.count)
    
    let responseMessage = try Response(jsonUTF8Data: responseDataWithoutHeader)
    
    return responseMessage
}

private func streamGRPCCall<Message: SwiftProtobuf.Message>(
    method: String,
    request: Message,
    onResponse: @escaping (Sdd_WorldModelDiff) -> Void
) throws {
    let url = URL(string: "http://\(host):\(port)\(method)")!
    var urlRequest = URLRequest(url: url)
    urlRequest.httpMethod = "POST"
    urlRequest.setValue("application/grpc", forHTTPHeaderField: "content-type")
    urlRequest.setValue("trailers", forHTTPHeaderField: "te")
    
    let requestData = try request.jsonUTF8Data()
    
    var grpcData = Data()
    grpcData.append(contentsOf: withUnsafeBytes(of: UInt32(requestData.count).bigEndian) { Array($0) })
    grpcData.append(requestData)
    
    urlRequest.httpBody = grpcData
    
    let task = URLSession.shared.dataTask(with: urlRequest) { data, _, error in
        if let error = error {
            fputs("Stream error: \(error)\n", stderr)
            return
        }
        
        guard let data = data else {
            fputs("Stream error: No data\n", stderr)
            return
        }
        
        var offset = 0
        while offset < data.count - 5 {
            let lengthData = data.subdata(in: (offset + 1)..<(offset + 5))
            let length = UInt32(bigEndian: lengthData.withUnsafeBytes { $0.load(as: UInt32.self) })
            
            let messageData = data.subdata(in: (offset + 5)..<(offset + 5 + Int(length)))
            
            do {
                let diff = try Sdd_WorldModelDiff(jsonUTF8Data: messageData)
                onResponse(diff)
            } catch {
                fputs("Parse error: \(error)\n", stderr)
            }
            
            offset += 5 + Int(length)
        }
    }
    task.resume()
    
    dispatchMain()
}

struct GRPCError: Error, CustomStringConvertible {
    let info: String
    var description: String { info }
}

SDD.main()
