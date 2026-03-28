import Foundation

// Redirect stdout → stderr BEFORE anything else.
// Any stray print() would corrupt the JSON-RPC protocol channel.
// SDDMCPServer.swift expects to receive an output FileHandle pointing at
// the original stdout fd — that is what mcpOutput is.
let savedFD = dup(STDOUT_FILENO)
dup2(STDERR_FILENO, STDOUT_FILENO)
let mcpOutput = FileHandle(fileDescriptor: savedFD, closeOnDealloc: true)

SDDMCPServer(output: mcpOutput).run()
