import ArgumentParser
import FleetMateCore
import Foundation
import Rainbow

private func entraServiceOrExit() throws -> GraphService {
    let config = try FleetMateConfig.load()
    let service = GraphService(config: config)
    guard service.isConfigured else {
        print("Microsoft Graph not configured.".red)
        throw ExitCode.failure
    }
    return service
}

// MARK: - Add group member

struct EntraAddMemberSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add-member",
        abstract: "Add a directory object (user/device) to a group"
    )

    @Argument(help: "Group name or id")
    var group: String

    @Argument(help: "Object id of the user or device to add")
    var objectId: String

    func run() async throws {
        let service = try entraServiceOrExit()
        try await service.addGroupMember(group: group, objectId: objectId)
        print("Added \(objectId) to \(group)".green)
    }
}

// MARK: - Remove group member

struct EntraRemoveMemberSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove-member",
        abstract: "Remove a directory object from a group"
    )

    @Argument(help: "Group name or id")
    var group: String

    @Argument(help: "Object id of the member to remove")
    var objectId: String

    func run() async throws {
        let service = try entraServiceOrExit()
        try await service.removeGroupMember(group: group, objectId: objectId)
        print("Removed \(objectId) from \(group)".green)
    }
}

// MARK: - Enable/disable user account

struct EntraSetUserSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set-user",
        abstract: "Enable or disable a user account"
    )

    @Argument(help: "User principal name or id")
    var user: String

    @Flag(help: "Enable the account")
    var enable: Bool = false

    @Flag(help: "Disable the account")
    var disable: Bool = false

    func run() async throws {
        guard enable != disable else {
            print("Specify exactly one of --enable or --disable.".red)
            throw ExitCode.failure
        }
        let service = try entraServiceOrExit()
        try await service.setUserAccountEnabled(user, enabled: enable)
        print("\(enable ? "Enabled" : "Disabled") account for \(user)".green)
    }
}
