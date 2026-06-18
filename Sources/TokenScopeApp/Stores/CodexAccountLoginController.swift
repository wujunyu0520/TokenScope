import Foundation
import TokenScopeCore

@MainActor
final class CodexAccountLoginController {
    struct LoginResult {
        let account: CodexManagedAccount
        let output: String
    }

    enum LoginError: LocalizedError {
        case missingBinary
        case launchFailed(String)
        case timedOut
        case failed(status: Int32, output: String)
        case unreadableIdentity
        case missingEmail

        var errorDescription: String? {
            switch self {
            case .missingBinary:
                return L10n.string("`codex` command not found. Make sure Codex CLI is installed (npm install -g @openai/codex).")
            case let .launchFailed(message):
                return L10n.string("Failed to start `codex login`: %@", message)
            case .timedOut:
                return L10n.string("`codex login` timed out.")
            case let .failed(status, output):
                return output.isEmpty ? L10n.string("`codex login` exited with status %d.", status) : output
            case .unreadableIdentity:
                return L10n.string("Signed in, but could not read Codex account identity.")
            case .missingEmail:
                return L10n.string("Signed in, but the account email is missing.")
            }
        }
    }

    private let fileManager: FileManager
    private let accountStore: FileCodexManagedAccountStore

    init(
        fileManager: FileManager = .default,
        accountStore: FileCodexManagedAccountStore = FileCodexManagedAccountStore()
    ) {
        self.fileManager = fileManager
        self.accountStore = accountStore
    }

    func authenticateManagedAccount() async throws -> LoginResult {
        var homeURL = Self.makeManagedHomeRoot(fileManager: fileManager)
        homeURL = homeURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: homeURL, withIntermediateDirectories: true)

        do {
            let effectivePATH = await Self.captureLoginShellPATH()
            let scopedEnv = CodexHomeScope.scopedEnvironment(
                base: ProcessInfo.processInfo.environment,
                codexHome: homeURL.path
            )
            var env = scopedEnv
            env["PATH"] = effectivePATH

            guard let executable = Self.resolveCodexBinary(env: env) else {
                throw LoginError.missingBinary
            }

            let result = try await Self.runCodexLogin(executable: executable, env: env)
            let credentials = try CodexOAuthCredentialsStore.load(env: scopedEnv)
            let identity = CodexOAuthIdentity.from(credentials: credentials, response: nil)
            guard let email = identity.email, !email.isEmpty else {
                throw LoginError.missingEmail
            }

            let now = Date()
            let existing = (try? accountStore.loadAccounts()) ?? CodexManagedAccountSet(version: FileCodexManagedAccountStore.currentVersion, accounts: [])
            let matched = existing.account(email: email, providerAccountID: identity.providerAccountID)
            let account = CodexManagedAccount(
                id: matched?.id ?? UUID(),
                email: email,
                providerAccountID: identity.providerAccountID,
                managedHomePath: homeURL.path,
                createdAt: matched?.createdAt ?? now,
                updatedAt: now,
                lastAuthenticatedAt: now
            )
            let remaining = existing.accounts.filter { $0.id != matched?.id }
            try accountStore.storeAccounts(CodexManagedAccountSet(version: FileCodexManagedAccountStore.currentVersion, accounts: remaining + [account]))
            return LoginResult(account: account, output: result)
        } catch {
            try? fileManager.removeItem(at: homeURL)
            throw error
        }
    }

    // MARK: - Login Shell PATH Capture

    private static func captureLoginShellPATH() async -> String {
        await withTaskGroup(of: String?.self) { group -> String in
            group.addTask {
                let path = await Self.captureShellPATH()
                if path != nil { return path }
                return Self.buildFallbackPATH()
            }
            group.addTask {
                let nanos = UInt64(3_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result ?? Self.buildFallbackPATH()
        }
    }

    private static func captureShellPATH() async -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let isCI = ["1", "true"].contains((ProcessInfo.processInfo.environment["CI"] ?? "").lowercased())

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = isCI
            ? ["-c", "printf '%s' \"$PATH\""]
            : ["-l", "-i", "-c", "printf '%s' \"$PATH\""]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            return nil
        }

        _ = await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask {
                process.waitUntilExit()
                return true
            }
            group.addTask {
                let nanos = UInt64(2_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }

        guard process.terminationStatus == 0 else { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard var path = String(data: data, encoding: .utf8) else { return nil }
        path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    nonisolated private static func buildFallbackPATH() -> String {
        var parts: [String] = []
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        if let existing = ProcessInfo.processInfo.environment["PATH"], !existing.isEmpty {
            parts.append(existing)
        }

        let extraPaths = [
            "\(home)/.local/bin",
            "\(home)/.npm-global/bin",
            "/usr/local/bin",
            "\(home)/.nvm/versions/node",
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
        ]
        for p in extraPaths where !parts.contains(p) {
            parts.append(p)
        }

        parts.append(contentsOf: ["/usr/bin", "/bin", "/usr/sbin", "/sbin"])

        var seen = Set<String>()
        let deduped = parts.compactMap { part -> String? in
            guard !part.isEmpty else { return nil }
            if seen.insert(part).inserted { return part }
            return nil
        }
        return deduped.joined(separator: ":")
    }

    // MARK: - Binary Resolution

    private static func resolveCodexBinary(env: [String: String]) -> String? {
        if let override = env["CODEX_CLI_PATH"], !override.isEmpty {
            if FileManager.default.isExecutableFile(atPath: override) { return override }
        }

        let path = env["PATH"] ?? ""
        for directory in path.split(separator: ":") {
            let dir = String(directory)
            guard !dir.isEmpty else { continue }
            let candidate = URL(fileURLWithPath: dir, isDirectory: true).appendingPathComponent("codex")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate.path
            }
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let knownPaths = [
            "\(home)/.local/bin/codex",
            "/usr/local/bin/codex",
            "/opt/homebrew/bin/codex",
        ]
        for p in knownPaths {
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }

        return nil
    }

    // MARK: - Process Execution

    private static func makeManagedHomeRoot(fileManager: FileManager) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
        return base
            .appendingPathComponent("TokenScope", isDirectory: true)
            .appendingPathComponent("codex-managed-homes", isDirectory: true)
    }

    private static func runCodexLogin(executable: String, env: [String: String]) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable, "login"]
        process.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            throw LoginError.launchFailed(error.localizedDescription)
        }

        let timedOut = await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask {
                process.waitUntilExit()
                return false
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 120_000_000_000)
                return true
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }

        if timedOut {
            if process.isRunning { process.terminate() }
            throw LoginError.timedOut
        }

        let outputData = stdout.fileHandleForReading.readDataToEndOfFile() + stderr.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard process.terminationStatus == 0 else {
            throw LoginError.failed(status: process.terminationStatus, output: output)
        }
        return output
    }
}
