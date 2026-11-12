import XCTest

// `server add|list|rm` (ADR-0015): a personal Mac sets up a Server in one command and keeps
// the Server list. A fake remote plays the Server — its installed version, the installer, and
// its own `mytokens` driven through `runCommand` with a store and role of its own — so every
// step runs both ends without ssh or a keychain.
final class ServerSetupTests: XCTestCase {
    private var laptop = InMemorySecretStore()
    private var server = InMemorySecretStore()
    private var serverRole = InMemoryHostRoleSetting()
    private var list = InMemoryServerList()
    private var remote = RecordingRemote()
    private var installedThere: String?          // the Server's MyTokens version; nil: none
    private var releaseInstalls = "0.2.0"         // what the installer puts there
    private var installFails = false
    private var selftestFails = false
    private let script = Data("#!/bin/bash\necho install\n".utf8)
    private let today = Date(timeIntervalSince1970: 1_794_441_600)

    override func setUp() {
        laptop = InMemorySecretStore()
        server = InMemorySecretStore()
        serverRole = InMemoryHostRoleSetting()
        list = InMemoryServerList()
        installedThere = nil
        releaseInstalls = "0.2.0"
        installFails = false
        selftestFails = false
        remote = RecordingRemote { [unowned self] command, stdin in
            switch command {
            case remoteVersionCommand:
                return CommandResult(stdout: (self.installedThere ?? "none") + "\n", stderr: "", exitCode: 0)
            case remoteInstallCommand:
                XCTAssertEqual(stdin, self.script)
                if self.installFails { return CommandResult(stdout: "", stderr: "curl: (22) 404\n", exitCode: 22) }
                self.installedThere = self.releaseInstalls
                return CommandResult(stdout: "installed\n", stderr: "", exitCode: 0)
            case remoteSetRoleCommand: return self.onServer(["host", "server"])
            case remoteSelftestCommand:
                if self.selftestFails { return CommandResult(stdout: "SELFTEST FAIL\n", stderr: "", exitCode: 1) }
                return self.onServer(["selftest"])
            case remoteExportCommand: return self.onServer(["get", "--unpushed"])
            case remotePutCommand: return self.onServer(["put", "--stdin"], stdin: stdin)
            default: return CommandResult(stdout: "", stderr: "unexpected command \(command)\n", exitCode: 127)
            }
        }
    }

    private func onLaptop(_ argv: [String], input: [String: String]? = nil, role: HostRole = .personal) -> CommandResult {
        runCommand(argv, Dependencies(role: InMemoryHostRoleSetting(role), store: { [laptop] _ in laptop },
                                      input: { _ in CannedSecretInput(values: input) }, remote: remote,
                                      stdin: { Data() }, now: { [today] in today }, servers: list,
                                      app: { [script] in AppRelease(version: "0.2.0", installScript: { script }) }))
    }

    private func onServer(_ argv: [String], input: [String: String]? = nil, stdin: Data = Data()) -> CommandResult {
        runCommand(argv, Dependencies(role: serverRole, store: { [server] _ in server },
                                      input: { _ in CannedSecretInput(values: input) }, remote: remote, stdin: { stdin }))
    }

    private var commands: [String] { remote.runs.map(\.command) }

    func testAddInstallsSetsTheRoleSelftestsSyncsAndListsTheHost() {
        _ = onLaptop(["put", "deploy", "--level", "server"], input: ["": "srv-tok"])
        _ = onLaptop(["put", "bank"], input: ["": "personal-tok"])

        let r = onLaptop(["server", "add", "macstudio-jp"])
        XCTAssertEqual(r.exitCode, 0, r.stderr)
        XCTAssertEqual(r.stdout, """
            installed MyTokens 0.2.0
            role server
            selftest passed
            added deploy/default
            added macstudio-jp to the server list

            """)
        XCTAssertEqual(commands, [remoteVersionCommand, remoteInstallCommand, remoteVersionCommand,
                                  remoteSetRoleCommand, remoteSelftestCommand, remoteExportCommand, remotePutCommand])
        XCTAssertTrue(remote.runs.allSatisfy { $0.host == "macstudio-jp" })
        XCTAssertEqual(serverRole.role, .server)
        XCTAssertEqual(onServer(["get", "deploy"]).stdout, "srv-tok")
        XCTAssertNil(try server.get(service: "bank", account: "default"))
        XCTAssertEqual(list.hosts, ["macstudio-jp"])
        XCTAssertEqual(onLaptop(["server", "list"]).stdout, "macstudio-jp\n")
    }

    func testAddUpgradesAnOlderMyTokensAndLeavesACurrentOneAlone() {
        installedThere = "0.1.9"
        XCTAssertTrue(onLaptop(["server", "add", "mini"]).stdout.hasPrefix("upgraded MyTokens 0.1.9 to 0.2.0\n"))

        remote = RecordingRemote(respond: remote.respond)
        let again = onLaptop(["server", "add", "mini"])
        XCTAssertEqual(again.exitCode, 0, again.stderr)
        XCTAssertTrue(again.stdout.hasPrefix("MyTokens 0.2.0 is installed\n"))
        XCTAssertFalse(commands.contains(remoteInstallCommand))
    }

    func testAddOnAListedHostRepairsAndChangesNothingElse() {
        _ = onLaptop(["put", "deploy", "--level", "server"], input: ["": "srv-tok"])
        _ = onLaptop(["server", "add", "mini"])
        _ = try! server.delete(service: "deploy", account: "default")    // the Server lost it
        serverRole.role = .personal                                       // and its role

        let r = onLaptop(["server", "add", "mini"])
        XCTAssertEqual(r.exitCode, 0, r.stderr)
        XCTAssertEqual(r.stdout, "MyTokens 0.2.0 is installed\nrole server\nselftest passed\nadded deploy/default\nmini is on the server list\n")
        XCTAssertEqual(serverRole.role, .server)
        XCTAssertEqual(list.hosts, ["mini"])
        XCTAssertEqual(list.writes, 1)
    }

    func testAFailingInstallLeavesTheHostOffTheListAndNamesTheStep() {
        installFails = true
        let r = onLaptop(["server", "add", "mini"])
        XCTAssertEqual(r.exitCode, 1)
        XCTAssertTrue(r.stderr.hasPrefix("server add mini failed to install MyTokens"), r.stderr)
        XCTAssertTrue(r.stderr.contains("curl: (22) 404"))
        XCTAssertEqual(list.hosts, [])
        XCTAssertFalse(commands.contains(remoteSetRoleCommand))
    }

    func testAnInstallThatStaysOlderFails() {
        releaseInstalls = "0.1.9"
        let r = onLaptop(["server", "add", "mini"])
        XCTAssertEqual(r.exitCode, 1)
        XCTAssertTrue(r.stderr.contains("failed to install MyTokens"), r.stderr)
        XCTAssertTrue(r.stderr.contains("runs 0.1.9 after installing, not 0.2.0"), r.stderr)
        XCTAssertEqual(list.hosts, [])
    }

    func testAFailingSelftestLeavesTheHostOffTheListAndSyncsNothing() {
        _ = onLaptop(["put", "deploy", "--level", "server"], input: ["": "srv-tok"])
        selftestFails = true
        let r = onLaptop(["server", "add", "mini"])
        XCTAssertEqual(r.exitCode, 1)
        XCTAssertTrue(r.stderr.hasPrefix("server add mini failed to pass selftest"), r.stderr)
        XCTAssertTrue(r.stderr.contains("SELFTEST FAIL"))
        XCTAssertEqual(list.hosts, [])
        XCTAssertFalse(commands.contains(remotePutCommand))
        XCTAssertTrue(server.items.isEmpty)
    }

    func testAFailingSyncLeavesTheHostOffTheListAndNoValueIsPrinted() {
        _ = onLaptop(["put", "deploy", "--level", "server"], input: ["": "srv-tok"])
        installedThere = "0.2.0"
        server.locked = true    // selftest and Sync fail on the Server's store
        let respond = remote.respond
        remote.respond = { command, stdin in
            command == remoteSelftestCommand ? CommandResult(stdout: "SELFTEST PASS\n", stderr: "", exitCode: 0) : respond(command, stdin)
        }
        let r = onLaptop(["server", "add", "mini"])
        XCTAssertEqual(r.exitCode, 1)
        XCTAssertTrue(r.stderr.contains("failed to sync"), r.stderr)
        XCTAssertFalse((r.stdout + r.stderr).contains("srv-tok"))
        XCTAssertEqual(list.hosts, [])
    }

    func testValuesTravelOnlyInThePushPipe() {
        _ = onLaptop(["put", "deploy", "--level", "server"], input: ["": "srv-tok"])
        let r = onLaptop(["server", "add", "mini"])
        XCTAssertFalse((r.stdout + r.stderr).contains("srv-tok"))
        for run in remote.runs {
            XCTAssertFalse(run.command.contains("srv-tok"))
            XCTAssertEqual(String(decoding: run.stdin, as: UTF8.self).contains("srv-tok"), run.command == remotePutCommand)
        }
    }

    func testRmEmptiesTheServerAdoptingFirstThenForgetsIt() {
        _ = onLaptop(["put", "deploy", "--level", "server"], input: ["": "srv-tok"])
        _ = onLaptop(["server", "add", "mini"])
        _ = onServer(["put", "hook", "--description", "entered there"], input: ["": "hook-tok"])

        let r = onLaptop(["server", "rm", "mini"])
        XCTAssertEqual(r.exitCode, 0, r.stderr)
        XCTAssertEqual(r.stdout, "adopted hook/default\nremoved deploy/default\nremoved hook/default\nremoved mini from the server list\n")
        XCTAssertTrue(server.items.isEmpty)
        XCTAssertEqual(try laptop.get(service: "hook", account: "default")?.loneValue, "hook-tok")
        XCTAssertEqual(list.hosts, [])
        XCTAssertEqual(onLaptop(["server", "list"]).stderr, "no servers on the server list\n")
    }

    func testRmStopsOnAConflictAndKeepsTheHost() {
        _ = onLaptop(["put", "deploy", "--level", "server"], input: ["": "srv-tok"])
        _ = onLaptop(["server", "add", "mini"])
        _ = onLaptop(["put", "hook"], input: ["": "mine"])
        _ = onServer(["put", "hook"], input: ["": "theirs"])

        let r = onLaptop(["server", "rm", "mini"])
        XCTAssertEqual(r.exitCode, 1)
        XCTAssertTrue(r.stdout.contains("conflict hook/default"), r.stdout)
        XCTAssertTrue(r.stderr.contains("mini stays on the server list"), r.stderr)
        XCTAssertEqual(list.hosts, ["mini"])
        XCTAssertEqual(try server.get(service: "deploy", account: "default")?.loneValue, "srv-tok")
        XCTAssertFalse(commands.suffix(1).contains(remotePutCommand))
    }

    func testRmOfAnUnlistedHostChangesNothing() {
        let r = onLaptop(["server", "rm", "nowhere"])
        XCTAssertEqual(r.exitCode, 1)
        XCTAssertEqual(r.stderr, "nowhere is not on the server list\n")
        XCTAssertTrue(remote.runs.isEmpty)
    }

    func testServerCommandsAreRefusedOnAServer() {
        list.hosts = ["mini"]
        for argv in [["server", "add", "mini"], ["server", "rm", "mini"], ["server", "list"]] {
            let r = onLaptop(argv, role: .server)
            XCTAssertEqual(r.exitCode, 64, argv.joined(separator: " "))
            XCTAssertTrue(r.stderr.contains("this Mac is a server"), r.stderr)
        }
        XCTAssertTrue(remote.runs.isEmpty)
        XCTAssertEqual(list.hosts, ["mini"])
    }

    func testServerNeedsAVerbAndOneHost() {
        for argv in [["server"], ["server", "add"], ["server", "add", "a", "b"], ["server", "list", "a"], ["server", "bogus", "a"]] {
            XCTAssertEqual(onLaptop(argv).exitCode, 64, argv.joined(separator: " "))
        }
        XCTAssertEqual(onLaptop(["server", "add", "--host"]).exitCode, 64)
    }

    func testNoSecretMayTakeTheServerListsService() {
        XCTAssertEqual(onLaptop(["put", serverListService], input: ["": "x"]).exitCode, 64)
        XCTAssertEqual(onLaptop(["rm", serverListService]).exitCode, 64)
    }

    func testVersionsCompareByNumber() {
        XCTAssertTrue(isOlder("0.1.9", than: "0.1.10"))
        XCTAssertTrue(isOlder("0.1", than: "0.1.1"))
        XCTAssertFalse(isOlder("0.2.0", than: "0.2.0"))
        XCTAssertFalse(isOlder("1.0.0", than: "0.9.9"))
    }

    // The real list item, against an in-memory keychain: one synchronizable item in the
    // access group, which the Secret store's `list` does not show.
    func testTheKeychainServerListIsOneSynchronizableItemListDoesNotShow() throws {
        let keychain = InMemoryKeychain()
        let servers = KeychainServerList(keychain: keychain)
        XCTAssertEqual(try servers.read(), [])
        try servers.write(["mini", "macstudio-jp"])
        try servers.write(["mini", "macstudio-jp", "mini"])
        XCTAssertEqual(try servers.read(), ["macstudio-jp", "mini"])
        XCTAssertEqual(try KeychainServerList(keychain: keychain).read(), ["macstudio-jp", "mini"])

        XCTAssertEqual(keychain.items.count, 1)
        let item = keychain.items[0]
        XCTAssertEqual(item[kSecAttrSynchronizable as String] as? Bool, true)
        XCTAssertEqual(item[kSecAttrAccessGroup as String] as? String, mytokensAccessGroup)
        XCTAssertTrue((item[kSecAttrAccessible as String] as AnyObject).isEqual(kSecAttrAccessibleAfterFirstUnlock))

        let store = KeychainSecretStore(location: .iCloud, keychain: keychain)
        try store.upsert(service: "deploy", account: "default", secret: SecretValue(single: "v"), kind: "static",
                         meta: nil, description: nil, level: .server, pushed: false)
        XCTAssertEqual(try store.list().map(\.service), ["deploy"])
        XCTAssertEqual(try KeychainSecretStore(location: .local, keychain: keychain).list().count, 0)
    }
}
