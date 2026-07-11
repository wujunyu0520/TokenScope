import Foundation
import CryptoKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum CodexAccountFingerprint {
    private static let domain = "tokenscope/codex/account-id/v1\0"

    public static func make(_ accountID: String?) -> String? {
        guard let accountID else { return nil }
        let normalized = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        let digest = SHA256.hash(data: Data((domain + normalized).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

public struct CodexOAuthCredentials: Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let idToken: String?
    public let accountId: String?
    public let lastRefresh: Date?

    public init(
        accessToken: String,
        refreshToken: String,
        idToken: String?,
        accountId: String?,
        lastRefresh: Date?
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.idToken = idToken
        self.accountId = accountId
        self.lastRefresh = lastRefresh
    }

    public var needsRefresh: Bool {
        guard let lastRefresh else { return true }
        let eightDays: TimeInterval = 8 * 24 * 60 * 60
        return Date().timeIntervalSince(lastRefresh) > eightDays
    }
}

public enum CodexOAuthCredentialsError: LocalizedError, Sendable {
    case notFound
    case decodeFailed(String)
    case missingTokens

    public var errorDescription: String? {
        switch self {
        case .notFound:
            return CoreL10n.string("Codex auth.json not found. Please sign in first.")
        case let .decodeFailed(message):
            return CoreL10n.string("Failed to decode Codex credentials: %@", message)
        case .missingTokens:
            return CoreL10n.string("Codex auth.json exists but contains no usable tokens.")
        }
    }
}

public enum CodexHomeScope {
    public static func ambientHomeURL(
        env: [String: String],
        fileManager: FileManager = .default
    ) -> URL {
        if let raw = env["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            return URL(fileURLWithPath: raw, isDirectory: true)
        }
        return fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }

    public static func scopedEnvironment(base: [String: String], codexHome: String?) -> [String: String] {
        guard let codexHome, !codexHome.isEmpty else { return base }
        var env = base
        env["CODEX_HOME"] = codexHome
        return env
    }
}

public enum CodexOAuthCredentialsStore {
    private static func authFilePath(
        env: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL {
        CodexHomeScope.ambientHomeURL(env: env, fileManager: fileManager)
            .appendingPathComponent("auth.json")
    }

    public static func load(env: [String: String] = ProcessInfo.processInfo.environment) throws -> CodexOAuthCredentials {
        let url = authFilePath(env: env)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CodexOAuthCredentialsError.notFound
        }
        let data = try Data(contentsOf: url)
        return try parse(data: data)
    }

    public static func parse(data: Data) throws -> CodexOAuthCredentials {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexOAuthCredentialsError.decodeFailed(CoreL10n.string("Invalid JSON"))
        }

        if let tokens = json["tokens"] as? [String: Any],
           let accessToken = stringValue(in: tokens, snakeCaseKey: "access_token", camelCaseKey: "accessToken"),
           let refreshToken = stringValue(in: tokens, snakeCaseKey: "refresh_token", camelCaseKey: "refreshToken"),
           !accessToken.isEmpty {
            return CodexOAuthCredentials(
                accessToken: accessToken,
                refreshToken: refreshToken,
                idToken: stringValue(in: tokens, snakeCaseKey: "id_token", camelCaseKey: "idToken"),
                accountId: stringValue(in: tokens, snakeCaseKey: "account_id", camelCaseKey: "accountId"),
                lastRefresh: parseLastRefresh(from: json["last_refresh"])
            )
        }

        if let apiKey = json["OPENAI_API_KEY"] as? String,
           !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return CodexOAuthCredentials(
                accessToken: apiKey,
                refreshToken: "",
                idToken: nil,
                accountId: nil,
                lastRefresh: nil
            )
        }

        throw CodexOAuthCredentialsError.missingTokens
    }

    public static func save(
        _ credentials: CodexOAuthCredentials,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        let url = authFilePath(env: env)
        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json = existing
        }

        var tokens: [String: Any] = [
            "access_token": credentials.accessToken,
            "refresh_token": credentials.refreshToken,
        ]
        if let idToken = credentials.idToken {
            tokens["id_token"] = idToken
        }
        if let accountId = credentials.accountId {
            tokens["account_id"] = accountId
        }
        json["tokens"] = tokens
        json["last_refresh"] = ISO8601DateFormatter().string(from: Date())

        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private static func parseLastRefresh(from raw: Any?) -> Date? {
        guard let value = raw as? String, !value.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func stringValue(in dictionary: [String: Any], snakeCaseKey: String, camelCaseKey: String) -> String? {
        if let value = dictionary[snakeCaseKey] as? String, !value.isEmpty { return value }
        if let value = dictionary[camelCaseKey] as? String, !value.isEmpty { return value }
        return nil
    }
}

public enum CodexTokenRefresher {
    private static let refreshEndpoint = URL(string: "https://auth.openai.com/oauth/token")!
    private static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"

    public enum RefreshError: LocalizedError, Sendable {
        case expired
        case revoked
        case reused
        case networkError(Error)
        case invalidResponse(String)

        public var errorDescription: String? {
            switch self {
            case .expired:
                return CoreL10n.string("Refresh token expired. Please sign in again.")
            case .revoked:
                return CoreL10n.string("Refresh token was revoked. Please sign in again.")
            case .reused:
                return CoreL10n.string("Refresh token was already used. Please sign in again.")
            case let .networkError(error):
                return CoreL10n.string("Network error during token refresh: %@", error.localizedDescription)
            case let .invalidResponse(message):
                return CoreL10n.string("Invalid refresh response: %@", message)
            }
        }
    }

    public static func refresh(_ credentials: CodexOAuthCredentials) async throws -> CodexOAuthCredentials {
        guard !credentials.refreshToken.isEmpty else {
            return credentials
        }

        var request = URLRequest(url: refreshEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_id": clientID,
            "grant_type": "refresh_token",
            "refresh_token": credentials.refreshToken,
            "scope": "openid profile email",
        ])

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw RefreshError.invalidResponse(CoreL10n.string("No HTTP response"))
            }
            if http.statusCode == 401 {
                if let errorCode = extractErrorCode(from: data) {
                    switch errorCode.lowercased() {
                    case "refresh_token_expired": throw RefreshError.expired
                    case "refresh_token_reused": throw RefreshError.reused
                    case "refresh_token_invalidated": throw RefreshError.revoked
                    default: throw RefreshError.expired
                    }
                }
                throw RefreshError.expired
            }
            guard http.statusCode == 200 else {
                throw RefreshError.invalidResponse(CoreL10n.string("Status %d", http.statusCode))
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw RefreshError.invalidResponse(CoreL10n.string("Invalid JSON"))
            }

            return CodexOAuthCredentials(
                accessToken: json["access_token"] as? String ?? credentials.accessToken,
                refreshToken: json["refresh_token"] as? String ?? credentials.refreshToken,
                idToken: json["id_token"] as? String ?? credentials.idToken,
                accountId: credentials.accountId,
                lastRefresh: Date()
            )
        } catch let error as RefreshError {
            throw error
        } catch {
            throw RefreshError.networkError(error)
        }
    }

    private static func extractErrorCode(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let error = json["error"] as? [String: Any], let code = error["code"] as? String { return code }
        if let error = json["error"] as? String { return error }
        return json["code"] as? String
    }
}

public struct CodexUsageResponse: Decodable, Sendable {
    public let planType: PlanType?
    public let rateLimit: RateLimitDetails?
    public let credits: CreditDetails?

    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case rateLimit = "rate_limit"
        case credits
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.planType = try? container.decodeIfPresent(PlanType.self, forKey: .planType)
        self.rateLimit = try? container.decodeIfPresent(RateLimitDetails.self, forKey: .rateLimit)
        self.credits = try? container.decodeIfPresent(CreditDetails.self, forKey: .credits)
    }

    public enum PlanType: Sendable, Decodable, Equatable {
        case guest, free, go, plus, pro, freeWorkspace, team, business, education, quorum, k12, enterprise, edu
        case unknown(String)

        public var rawValue: String {
            switch self {
            case .guest: return "guest"
            case .free: return "free"
            case .go: return "go"
            case .plus: return "plus"
            case .pro: return "pro"
            case .freeWorkspace: return "free_workspace"
            case .team: return "team"
            case .business: return "business"
            case .education: return "education"
            case .quorum: return "quorum"
            case .k12: return "k12"
            case .enterprise: return "enterprise"
            case .edu: return "edu"
            case let .unknown(value): return value
            }
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            switch value {
            case "guest": self = .guest
            case "free": self = .free
            case "go": self = .go
            case "plus": self = .plus
            case "pro": self = .pro
            case "free_workspace": self = .freeWorkspace
            case "team": self = .team
            case "business": self = .business
            case "education": self = .education
            case "quorum": self = .quorum
            case "k12": self = .k12
            case "enterprise": self = .enterprise
            case "edu": self = .edu
            default: self = .unknown(value)
            }
        }
    }

    public struct RateLimitDetails: Decodable, Sendable {
        public let primaryWindow: WindowSnapshot?
        public let secondaryWindow: WindowSnapshot?

        enum CodingKeys: String, CodingKey {
            case primaryWindow = "primary_window"
            case secondaryWindow = "secondary_window"
        }
    }

    public struct WindowSnapshot: Decodable, Sendable {
        public let usedPercent: Int
        public let resetAt: Int
        public let limitWindowSeconds: Int

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case resetAt = "reset_at"
            case limitWindowSeconds = "limit_window_seconds"
        }
    }

    public struct CreditDetails: Decodable, Sendable {
        public let hasCredits: Bool
        public let unlimited: Bool
        public let balance: Double?

        enum CodingKeys: String, CodingKey {
            case hasCredits = "has_credits"
            case unlimited
            case balance
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.hasCredits = (try? container.decode(Bool.self, forKey: .hasCredits)) ?? false
            self.unlimited = (try? container.decode(Bool.self, forKey: .unlimited)) ?? false
            if let value = try? container.decode(Double.self, forKey: .balance) {
                self.balance = value
            } else if let string = try? container.decode(String.self, forKey: .balance), let value = Double(string) {
                self.balance = value
            } else {
                self.balance = nil
            }
        }
    }
}

public enum CodexOAuthFetchError: LocalizedError, Sendable {
    case unauthorized
    case invalidResponse
    case serverError(Int, String?)
    case networkError(Error)

    public var errorDescription: String? {
        switch self {
        case .unauthorized:
            return CoreL10n.string("Codex OAuth token expired or invalid. Please sign in again.")
        case .invalidResponse:
            return CoreL10n.string("Invalid response from Codex usage API.")
        case let .serverError(code, message):
            if let message, !message.isEmpty {
                return CoreL10n.string("Codex API error %d: %@", code, message)
            }
            return CoreL10n.string("Codex API error %d.", code)
        case let .networkError(error):
            return CoreL10n.string("Network error: %@", error.localizedDescription)
        }
    }
}

public enum CodexOAuthUsageFetcher {
    private static let defaultChatGPTBaseURL = "https://chatgpt.com/backend-api/"
    private static let chatGPTUsagePath = "/wham/usage"
    private static let codexUsagePath = "/api/codex/usage"

    public static func fetchUsage(
        accessToken: String,
        accountId: String?,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) async throws -> CodexUsageResponse {
        var request = URLRequest(url: resolveUsageURL(env: env))
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("TokenScope", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let accountId, !accountId.isEmpty {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw CodexOAuthFetchError.invalidResponse
            }
            switch http.statusCode {
            case 200...299:
                guard let decoded = try? JSONDecoder().decode(CodexUsageResponse.self, from: data) else {
                    throw CodexOAuthFetchError.invalidResponse
                }
                return decoded
            case 401, 403:
                throw CodexOAuthFetchError.unauthorized
            default:
                throw CodexOAuthFetchError.serverError(http.statusCode, String(data: data, encoding: .utf8))
            }
        } catch let error as CodexOAuthFetchError {
            throw error
        } catch {
            throw CodexOAuthFetchError.networkError(error)
        }
    }

    private static func resolveUsageURL(env: [String: String]) -> URL {
        let baseURL = (env["CHATGPT_BASE_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? defaultChatGPTBaseURL
        let normalizedBase = normalizeChatGPTBaseURL(baseURL)
        let path = normalizedBase.contains("/backend-api") ? chatGPTUsagePath : codexUsagePath
        return URL(string: normalizedBase + path) ?? URL(string: defaultChatGPTBaseURL + chatGPTUsagePath)!
    }

    private static func normalizeChatGPTBaseURL(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }
}

public enum CodexJWT {
    public static func payload(_ token: String) -> [String: Any]? {
        let segments = token.split(separator: ".")
        guard segments.count >= 2 else { return nil }
        return decodeBase64URLJSON(String(segments[1]))
    }

    private static func decodeBase64URLJSON(_ raw: String) -> [String: Any]? {
        var base64 = raw.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = 4 - (base64.count % 4)
        if padding < 4 {
            base64 += String(repeating: "=", count: padding)
        }
        guard let data = Data(base64Encoded: base64),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }
}

public struct CodexOAuthIdentity: Sendable {
    public let email: String?
    public let planName: String?
    public let providerAccountID: String?

    public init(email: String?, planName: String?, providerAccountID: String?) {
        self.email = email?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.planName = planName?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.providerAccountID = CodexManagedAccount.normalizeProviderAccountID(providerAccountID)
    }

    public static func from(credentials: CodexOAuthCredentials, response: CodexUsageResponse?) -> CodexOAuthIdentity {
        let payload = credentials.idToken.flatMap(CodexJWT.payload)
        let profile = payload?["https://api.openai.com/profile"] as? [String: Any]
        let auth = payload?["https://api.openai.com/auth"] as? [String: Any]
        let email = (payload?["email"] as? String) ?? (profile?["email"] as? String)
        let providerAccountID = credentials.accountId
            ?? (auth?["chatgpt_account_id"] as? String)
            ?? (payload?["chatgpt_account_id"] as? String)
        let plan = response?.planType?.rawValue
            ?? (auth?["chatgpt_plan_type"] as? String)
            ?? (payload?["chatgpt_plan_type"] as? String)
        return CodexOAuthIdentity(email: email, planName: plan, providerAccountID: providerAccountID)
    }
}

public struct CodexOAuthSnapshot: Sendable {
    public let updatedAt: Date
    public let identity: CodexOAuthIdentity
    public let windows: [UsageWindowSnapshot]
    public let creditsText: String?

    public init(updatedAt: Date, identity: CodexOAuthIdentity, windows: [UsageWindowSnapshot], creditsText: String?) {
        self.updatedAt = updatedAt
        self.identity = identity
        self.windows = windows
        self.creditsText = creditsText
    }
}

public enum CodexOAuthSnapshotBuilder {
    public static func build(response: CodexUsageResponse, credentials: CodexOAuthCredentials, updatedAt: Date = Date()) -> CodexOAuthSnapshot {
        let identity = CodexOAuthIdentity.from(credentials: credentials, response: response)
        let windows = [
            makeWindow(id: "session", title: CoreL10n.string("Session"), snapshot: response.rateLimit?.primaryWindow),
            makeWindow(id: "weekly", title: CoreL10n.string("Weekly"), snapshot: response.rateLimit?.secondaryWindow),
        ].compactMap { $0 }

        let creditsText: String?
        if let credits = response.credits, credits.hasCredits {
            if credits.unlimited {
                creditsText = CoreL10n.string("Credits: Unlimited")
            } else if let balance = credits.balance {
                creditsText = CoreL10n.string("Credits: %@", balance.formatted(.number.precision(.fractionLength(0...2))))
            } else {
                creditsText = CoreL10n.string("Credits available")
            }
        } else {
            creditsText = nil
        }

        return CodexOAuthSnapshot(updatedAt: updatedAt, identity: identity, windows: windows, creditsText: creditsText)
    }

    private static func makeWindow(id: String, title: String, snapshot: CodexUsageResponse.WindowSnapshot?) -> UsageWindowSnapshot? {
        guard let snapshot else { return nil }
        let resetDate = Date(timeIntervalSince1970: TimeInterval(snapshot.resetAt))
        let reserve = calculateReserve(
            usedPercent: Double(snapshot.usedPercent),
            windowSeconds: snapshot.limitWindowSeconds,
            resetAt: resetDate
        )
        return UsageWindowSnapshot(
            id: id,
            title: title,
            usedPercent: Double(snapshot.usedPercent),
            reservePercent: reserve,
            resetsAt: resetDate
        )
    }

    private static func calculateReserve(usedPercent: Double, windowSeconds: Int, resetAt: Date) -> Double? {
        guard windowSeconds > 0 else { return nil }
        let now = Date()
        let remaining = max(0, resetAt.timeIntervalSince(now))
        guard remaining > 0, remaining < TimeInterval(windowSeconds) else { return nil }
        let elapsed = TimeInterval(windowSeconds) - remaining
        let expected = (elapsed / TimeInterval(windowSeconds)) * 100.0
        return usedPercent - expected
    }
}
