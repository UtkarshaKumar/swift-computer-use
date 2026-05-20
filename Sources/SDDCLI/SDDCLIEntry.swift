import ArgumentParser
import Foundation
import SDDCore

@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
@main
struct SDDCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sdd",
        abstract: "swift-computer-use CLI",
        subcommands: [LogCommand.self, ClickCommand.self, RunCommand.self, RecordCommand.self,
                      StatusCommand.self, OverrideCommand.self, StopCommand.self],
        defaultSubcommand: nil
    )
}
