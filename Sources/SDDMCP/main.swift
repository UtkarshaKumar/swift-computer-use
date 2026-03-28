import Foundation
import AppKit

// Redirect stdout → stderr BEFORE anything else.
// Any stray print() would corrupt the JSON-RPC protocol channel.
// SDDMCPServer.swift expects to receive an output FileHandle pointing at
// the original stdout fd — that is what mcpOutput is.
let savedFD = dup(STDOUT_FILENO)
dup2(STDERR_FILENO, STDOUT_FILENO)
let mcpOutput = FileHandle(fileDescriptor: savedFD, closeOnDealloc: true)

// Run the MCP JSON-RPC loop on a BACKGROUND thread.
// The main thread must stay free to pump RunLoop.main, which is required
// for DispatchQueue.main.async dispatches inside tool handlers
// (ScreenCaptureKit, AppKit, AX APIs all need main-thread callbacks).
let server = SDDMCPServer(output: mcpOutput)
let mcpThread = Thread { server.run() }
mcpThread.name = "sdd-mcp-loop"
mcpThread.start()

// Keep main thread alive pumping RunLoop.main.
// setActivationPolicy(.accessory) prevents a Dock icon from appearing.
NSApplication.shared.setActivationPolicy(.accessory)
RunLoop.main.run()  // never returns — process lives until stdin closes
