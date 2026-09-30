import Foundation
import SwiftUI

/// Pure parsing of the daemon's additive, UI-only system/git row format.
struct GitCommitEntry: Equatable {
    let sha: String
    let repo: String?
    let pushed: Bool
    let local: Bool
    let url: URL?
    var revision: String { sha + (repo.map { " (" + $0 + ")" } ?? "") }
    var link: URL? { pushed && !local ? url : nil }
    func showsPush(canCommit: Bool, ahead: UInt32) -> Bool { !pushed && !local && canCommit && ahead > 0 }
    func candidates(_ repos: [GitRepoStatus]) -> [GitRepoStatus] {
        guard !local, !pushed else { return [] }
        return repos.filter { $0.has_remote && $0.ahead > 0 && (repo == nil || $0.name == repo) }
    }
}

struct GitCommitNotice: Equatable {
    let count: Int
    let entries: [GitCommitEntry]
    let subject: String?
    let branch: String?
    var revisions: String { entries.map(\.revision).joined(separator: ", ") }
    var pushed: Bool { !entries.isEmpty && entries.allSatisfy(\.pushed) }
    var remotes: [URL] { entries.compactMap(\.link) }
    var title: String { "\(pushed ? "Committed & pushed" : "Committed") \(count) \(count == 1 ? "file" : "files")" }
    func showsPush(canCommit: Bool, ahead: UInt32) -> Bool { entries.contains { $0.showsPush(canCommit: canCommit, ahead: ahead) } }

    static func parse(_ body: String) -> GitCommitNotice? {
        let lines = body.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard let first = lines.first,
              let regex = try? NSRegularExpression(pattern: #"^Committed ([0-9]+) files?: (.+)$"#),
              let match = regex.firstMatch(in: first, range: NSRange(first.startIndex..., in: first)),
              let countRange = Range(match.range(at: 1), in: first), let count = Int(first[countRange]),
              let revisionsRange = Range(match.range(at: 2), in: first),
              let entryRegex = try? NSRegularExpression(pattern: #"([0-9a-fA-F]{7,40})(?: \((.*?)\))?( · pushed)?(?:, |$)"#) else { return nil }
        let revisions = String(first[revisionsRange])
        let matches = entryRegex.matches(in: revisions, range: NSRange(revisions.startIndex..., in: revisions))
        var offset = 0
        var entries: [GitCommitEntry] = []
        for (index, entry) in matches.enumerated() {
            guard entry.range.location == offset, let shaRange = Range(entry.range(at: 1), in: revisions) else { return nil }
            offset = NSMaxRange(entry.range)
            let repo = Range(entry.range(at: 2), in: revisions).map { String(revisions[$0]) }
            let pushed = entry.range(at: 3).location != NSNotFound
            // Keep positional slots: a bare remote or absent line is unknown, not local.
            let metadata = lines.indices.contains(index + 3) ? lines[index + 3].trimmingCharacters(in: .whitespaces) : ""
            let local = metadata == "local"
            var url: URL?
            if metadata.hasPrefix("remote "),
               let candidate = URL(string: String(metadata.dropFirst(7))),
               candidate.scheme?.lowercased() == "https", candidate.host?.isEmpty == false,
               candidate.user == nil, candidate.password == nil { url = candidate }
            entries.append(GitCommitEntry(sha: String(revisions[shaRange]), repo: repo, pushed: pushed, local: local, url: url))
        }
        guard !entries.isEmpty, offset == revisions.utf16.count else { return nil }
        func value(_ index: Int) -> String? {
            guard lines.indices.contains(index) else { return nil }
            let text = lines[index].trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : text
        }
        let branch = value(2).flatMap { $0.hasPrefix("branch ") ? String($0.dropFirst(7)).trimmingCharacters(in: .whitespaces) : nil }
        return GitCommitNotice(count: count, entries: entries, subject: value(1), branch: branch?.isEmpty == false ? branch : nil)
    }
}

struct GitCommitNoticeCard: View {
    @Environment(\.gitChangesModel) private var git
    let bodyText: String
    var body: some View {
        Group {
            if let notice = GitCommitNotice.parse(bodyText) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(VerdeTheme.accent)
                        Text(notice.title).font(VerdeTheme.ui(12, bold: true))
                        Spacer(minLength: 0)
                        if notice.pushed {
                            Text("Pushed").font(VerdeTheme.ui(10)).foregroundStyle(VerdeTheme.accent)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(VerdeTheme.accent.opacity(0.12), in: Capsule())
                        }
                    }

                    if let subject = notice.subject { Text(subject).font(VerdeTheme.ui(12)).foregroundStyle(VerdeTheme.muted).lineLimit(1) }
                    if let branch = notice.branch {
                        Label(branch, systemImage: "arrow.triangle.branch").font(VerdeTheme.mono(10)).lineLimit(1)
                            .padding(.horizontal, 6).padding(.vertical, 3).background(VerdeTheme.border.opacity(0.4), in: Capsule())
                    }
                    ForEach(Array(notice.entries.enumerated()), id: \.offset) { _, entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.revision).font(VerdeTheme.mono(11)).foregroundStyle(VerdeTheme.muted).lineLimit(2)
                            if entry.local {
                                Text("Local only · no remote").font(VerdeTheme.ui(12)).foregroundStyle(VerdeTheme.muted)
                            } else if let url = entry.link {
                                Link(destination: url) {
                                    Label("View on \(url.host ?? "remote")", systemImage: "arrow.up.right")
                                }.font(VerdeTheme.ui(12))
                            }
                            if let git {
                                let candidates = entry.candidates(git.repos)
                                if entry.showsPush(canCommit: git.canCommit, ahead: candidates.isEmpty ? 0 : 1) {
                                    HStack {
                                        Button {
                                            Task { await git.push(root: candidates.count == 1 ? candidates.first?.root : nil) }
                                        } label: {
                                            HStack {
                                                if git.isPushing { ProgressView() }
                                                Text("Push")
                                            }
                                        }.disabled(git.busy).accessibilityIdentifier("git-receipt-push")
                                        Text("Not pushed").foregroundStyle(VerdeTheme.muted)
                                    }.font(VerdeTheme.ui(12))
                                }
                            }
                        }
                    }
                }.padding(10).background(VerdeTheme.panel.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityElement(children: .contain)
            } else {
                // Preserve unknown/older daemon notices without inventing success metadata.
                Text(bodyText.components(separatedBy: .newlines).first ?? "")
                    .font(VerdeTheme.ui(12)).foregroundStyle(VerdeTheme.muted).lineLimit(1)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 6)
    }
}
