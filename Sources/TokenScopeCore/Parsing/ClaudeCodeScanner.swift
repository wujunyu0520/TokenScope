import Foundation

public struct ClaudeCodeScanner: Sendable {
    public let root: URL
    public let parser: ClaudeCodeParser

    public init(root: URL? = nil, parser: ClaudeCodeParser = ClaudeCodeParser()) {
        if let root { self.root = root } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            self.root = home.appendingPathComponent(".claude/projects", isDirectory: true)
        }
        self.parser = parser
    }

    public func scan() -> [ClaudeCodeParseResult] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return [] }

        var results: [ClaudeCodeParseResult] = []
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            do {
                let res = try parser.parse(fileURL: url)
                if res.session.messageCount > 0, res.session.totalUsage.totalTokens > 0 {
                    results.append(res)
                }
            } catch {
                continue
            }
        }
        return results
    }
}
