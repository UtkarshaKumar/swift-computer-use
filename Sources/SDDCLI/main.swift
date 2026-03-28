import ArgumentParser
import Foundation
import SDDCore

@main
struct SDDCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sdd",
        abstract: "Semantic Display Daemon CLI",
        subcommands: [LogCommand.self, ClickCommand.self],
        defaultSubcommand: nil
    )
}