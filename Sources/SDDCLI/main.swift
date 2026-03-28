import ArgumentParser
import Foundation
import SDDCore

struct SDDCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sdd",
        abstract: "Semantic Display Daemon CLI",
        subcommands: [LogCommand.self, ClickCommand.self, RunCommand.self],
        defaultSubcommand: nil
    )
}

// Top-level async entry point — required because main.swift cannot use @main
await SDDCLI.main()
