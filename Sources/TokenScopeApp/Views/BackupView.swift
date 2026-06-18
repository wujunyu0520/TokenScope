import SwiftUI

struct BackupView: View {
    var body: some View {
        ContentUnavailableView(
            L10n.string("Backup (coming in P2)"),
            systemImage: "externaldrive.badge.timemachine",
            description: Text(L10n.string("Incremental backup of Claude Code and Codex sessions keyed by session id."))
        )
        .navigationTitle(L10n.string("Backup"))
    }
}
