import ArgumentParser
import FleetMateCore
import Foundation
import Rainbow

struct EntraCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "entra",
        abstract: "Query Entra ID (Azure AD) users and groups",
        subcommands: [
            UserSubcommand.self,
            GroupSubcommand.self,
            CheckGroupSubcommand.self,
            SearchGroupsSubcommand.self,
            EntraAddMemberSubcommand.self,
            EntraRemoveMemberSubcommand.self,
            EntraSetUserSubcommand.self,
            EntraAuditSubcommand.self
        ],
        defaultSubcommand: UserSubcommand.self
    )
}

// MARK: - User

struct UserSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "user",
        abstract: "Get user details from Entra ID"
    )

    @Argument(help: "User principal name (email) or ID")
    var identifier: String

    @Flag(name: .shortAndLong, help: "Include group memberships")
    var groups: Bool = false

    @Flag(name: .shortAndLong, help: "Output as JSON")
    var json: Bool = false

    func run() async throws {
        let config = try FleetMateConfig.load()
        let service = GraphService(config: config)

        guard service.isConfigured else {
            print("Microsoft Graph not configured. Set GRAPH_TENANT_ID and GRAPH_CLIENT_ID.".red)
            throw ExitCode.failure
        }

        guard let user = try await service.getUser(identifier, includeGroups: groups) else {
            print("User not found: \(identifier)".red)
            throw ExitCode.failure
        }

        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(user)
            print(String(data: data, encoding: .utf8) ?? "{}")
        } else {
            printUserDetails(user)
        }
    }

    private func printUserDetails(_ user: EntraUser) {
        let enabled = user.accountEnabled == true ? "Yes".green : "No".red

        print("\n" + "User: \(user.displayName ?? "Unknown")".bold.green + "\n")
        print("  UPN:".lightBlue + "          \(user.userPrincipalName ?? "-")")
        print("  Display Name:".lightBlue + " \(user.displayName ?? "-")")
        print("  Email:".lightBlue + "        \(user.mail ?? "-")")
        print("  Job Title:".lightBlue + "    \(user.jobTitle ?? "-")")
        print("  Department:".lightBlue + "   \(user.department ?? "-")")
        print("  Office:".lightBlue + "       \(user.officeLocation ?? "-")")
        print("  Phone:".lightBlue + "        \(user.mobilePhone ?? "-")")
        print("  Enabled:".lightBlue + "      \(enabled)")

        if let memberOf = user.memberOf, !memberOf.isEmpty {
            print("\n  Group Memberships:".bold)
            for group in memberOf.prefix(20) {
                print("    - \(group.displayName ?? group.id ?? "Unknown")")
            }
            if memberOf.count > 20 {
                print("    ... and \(memberOf.count - 20) more")
            }
        }
        print("")
    }
}

// MARK: - Group

struct GroupSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "group",
        abstract: "Get group details and members"
    )

    @Argument(help: "Group name or ID")
    var identifier: String

    @Flag(name: .shortAndLong, help: "Include member list")
    var members: Bool = false

    @Option(name: .shortAndLong, help: "Maximum members to show")
    var limit: Int = 50

    @Flag(name: .shortAndLong, help: "Output as JSON")
    var json: Bool = false

    func run() async throws {
        let config = try FleetMateConfig.load()
        let service = GraphService(config: config)

        guard service.isConfigured else {
            print("Microsoft Graph not configured.".red)
            throw ExitCode.failure
        }

        // Try to get group by ID first, then by name
        var group: EntraGroup?
        if UUID(uuidString: identifier) != nil {
            group = try await service.getGroupById(identifier)
        } else {
            group = try await service.getGroupByName(identifier)
        }

        guard let group = group else {
            print("Group not found: \(identifier)".red)
            throw ExitCode.failure
        }

        var memberList: [EntraUser] = []
        if members {
            memberList = try await service.getGroupMembers(group.id ?? "", limit: limit)
        }

        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            var output: [String: Any] = [:]
            if let groupData = try? encoder.encode(group) {
                output["group"] = try? JSONSerialization.jsonObject(with: groupData)
            }
            if members, let membersData = try? encoder.encode(memberList) {
                output["members"] = try? JSONSerialization.jsonObject(with: membersData)
            }
            let jsonData = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
            print(String(data: jsonData, encoding: .utf8) ?? "{}")
        } else {
            printGroupDetails(group, members: memberList)
        }
    }

    private func printGroupDetails(_ group: EntraGroup, members: [EntraUser]) {
        let security = group.securityEnabled == true ? "Yes".green : "No"
        let mail = group.mailEnabled == true ? "Yes".green : "No"

        print("\n" + "Group: \(group.displayName ?? "Unknown")".bold.green + "\n")
        print("  ID:".lightBlue + "           \(group.id ?? "-")")
        print("  Display Name:".lightBlue + " \(group.displayName ?? "-")")
        print("  Description:".lightBlue + "  \(group.description ?? "-")")
        print("  Mail:".lightBlue + "         \(group.mail ?? "-")")
        print("  Security:".lightBlue + "     \(security)")
        print("  Mail Enabled:".lightBlue + " \(mail)")

        if let types = group.groupTypes, !types.isEmpty {
            print("  Types:".lightBlue + "        \(types.joined(separator: ", "))")
        }

        if !members.isEmpty {
            print("\n  Members (\(members.count)):".bold)
            for member in members {
                print("    - \(member.displayName ?? member.userPrincipalName ?? "Unknown")")
            }
        }
        print("")
    }
}

// MARK: - Directory Audit Log

struct EntraAuditSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "audit",
        abstract: "Read the directory audit log - who changed a group, user or device"
    )

    @Option(name: [.customShort("t"), .long], help: "Object the change was made to: display name or object id")
    var target: String?

    @Option(name: [.customShort("a"), .long], help: "Exact activity name, e.g. \"Delete group\"")
    var activity: String?

    @Option(name: [.customShort("d"), .long], help: "How far back to look in days (0 for no limit)")
    var days: Int = 7

    @Option(name: .shortAndLong, help: "Maximum entries to show")
    var limit: Int = 50

    @Flag(name: .shortAndLong, help: "Output as JSON")
    var json: Bool = false

    func run() async throws {
        let config = try FleetMateConfig.load()
        let service = GraphService(config: config)

        guard service.isConfigured else {
            print("Microsoft Graph not configured.".red)
            throw ExitCode.failure
        }

        let filter = DirectoryAuditQuery.filter(target: target, activity: activity, days: days)
        let events = try await service.getDirectoryAudits(filter: filter, limit: limit)

        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(events)
            print(String(data: data, encoding: .utf8) ?? "[]")
            return
        }

        guard !events.isEmpty else {
            print("No matching audit entries.".yellow)
            // An empty result is ambiguous here in a way it is not elsewhere: the
            // log is retained for a limited window and the permission is not
            // granted by default, so say what would explain it.
            print("The directory audit log retains roughly 30 days, and reading it needs AuditLog.Read.All.".lightBlack)
            print("A wrong --activity name also matches nothing; it is compared exactly.".lightBlack)
            return
        }

        print("")
        for event in events {
            let when = String((event.activityDateTime ?? "-").prefix(16)).replacingOccurrences(of: "T", with: " ")
            let actor = event.actorIsApplication ? event.actor.cyan : event.actor
            let outcome = (event.result ?? "-").lowercased() == "success"
                ? (event.result ?? "-").green
                : (event.result ?? "-").red

            print("\(when)  \(event.activityDisplayName ?? "-")".bold)
            print("  by:".lightBlue + "     \(actor)")
            print("  target:".lightBlue + " \(event.targets)")
            print("  result:".lightBlue + " \(outcome)")
            print("")
        }

        print("\(events.count) entr\(events.count == 1 ? "y" : "ies"). Applications are shown in cyan.".lightBlack)
    }
}

// MARK: - Check Group Membership

struct CheckGroupSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "check-group",
        abstract: "Check if a user is a member of a group"
    )

    @Argument(help: "User principal name (email)")
    var user: String

    @Argument(help: "Group name or ID")
    var group: String

    @Flag(name: .shortAndLong, help: "Output as JSON")
    var json: Bool = false

    func run() async throws {
        let config = try FleetMateConfig.load()
        let service = GraphService(config: config)

        guard service.isConfigured else {
            print("Microsoft Graph not configured.".red)
            throw ExitCode.failure
        }

        let isMember = try await service.checkGroupMembership(user: user, group: group)

        if json {
            print("{\"user\": \"\(user)\", \"group\": \"\(group)\", \"isMember\": \(isMember)}")
        } else {
            if isMember {
                print("\n" + "YES".green.bold + " - \(user) is a member of \(group)\n")
            } else {
                print("\n" + "NO".red.bold + " - \(user) is NOT a member of \(group)\n")
            }
        }
    }
}

// MARK: - Search Groups

struct SearchGroupsSubcommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search-groups",
        abstract: "Search for groups by name"
    )

    @Argument(help: "Search query (group name prefix)")
    var query: String

    @Option(name: .shortAndLong, help: "Maximum results")
    var limit: Int = 20

    @Flag(name: .shortAndLong, help: "Output as JSON")
    var json: Bool = false

    func run() async throws {
        let config = try FleetMateConfig.load()
        let service = GraphService(config: config)

        guard service.isConfigured else {
            print("Microsoft Graph not configured.".red)
            throw ExitCode.failure
        }

        let groups = try await service.searchGroups(query, limit: limit)

        if groups.isEmpty {
            print("\nNo groups found matching: \(query)".yellow + "\n")
            return
        }

        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(groups)
            print(String(data: data, encoding: .utf8) ?? "[]")
        } else {
            print("\n" + "Groups matching '\(query)'".bold + " (\(groups.count) found)\n")

            for group in groups {
                let security = group.securityEnabled == true ? "[S]".cyan : ""
                print("\(security) \(group.displayName ?? "Unknown")".bold)
                if let desc = group.description, !desc.isEmpty {
                    print("    \(desc.prefix(80))")
                }
            }
            print("")
        }
    }
}
