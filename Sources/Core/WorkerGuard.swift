import Foundation

// Inside a factorium worker (FACTORIUM_WORKER set in its environment), mytokens never writes a
// 1Password vault or Syncs a host from this Mac's real store: production is never a test target
// (mytokens#15). A worker that needs a real `op` check runs it against the scratch vault, with an
// in-memory store and the scratch service account, never the keychain's Secrets.

/// The environment variable factorium sets in every worker session.
let workerEnvironmentVariable = "FACTORIUM_WORKER"

/// The only vault a real-op check writes, and the Secret holding its service account token
/// (read+write on that vault alone).
let scratchVault = "mytokens-scratch"
let scratchTokenService = "1password-scratch-service-account"

/// Whether this process runs inside a factorium worker.
func inFactoriumWorker(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
    environment[workerEnvironmentVariable] != nil
}

/// What a worker is told instead; `what` names the command and what it would have reached.
func refusedInWorker(_ what: String) -> CommandResult {
    CommandResult(stdout: "", stderr: """
        \(what): refused inside a factorium worker (\(workerEnvironmentVariable) is set): it would reach \
        production vaults or hosts with this Mac's real secrets, and production is never a test target.
        Check against the scratch vault instead: make op-real-check (tools/op-real-check.sh) writes only \
        the vault \(scratchVault), from an in-memory store, with the token in the Secret \(scratchTokenService).

        """, exitCode: 1)
}

/// The refusal for `argv` in a worker, or nil when the command may run. Checked before any
/// token is read or anything written. `serverLevel` says whether a `put`/`rm` touches a
/// `server`-level Secret (whose change starts Background Sync on a personal Mac).
func workerRefusal(_ cmd: String, _ positionals: [String], role: HostRole, serverLevel: () -> Bool) -> CommandResult? {
    let verb = positionals.first ?? ""
    switch cmd {
    case "onepassword" where ["add", "rm", "keep"].contains(verb):
        return refusedInWorker("mytokens onepassword \(verb)")
    case "server" where ["add", "rm", "sync"].contains(verb):
        return refusedInWorker("mytokens server \(verb)")
    case "sync":
        return refusedInWorker("mytokens sync")
    case "put", "rm":
        guard role == .personal, serverLevel() else { return nil }
        return refusedInWorker("mytokens \(cmd) of a server-level secret (it starts Background Sync)")
    default:
        return nil
    }
}
