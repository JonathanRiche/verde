import Foundation
import SwiftUI

/// Pure parsing of the daemon's additive, UI-only system/git row format.
struct GitCommitNotice: Equatable {
    let count: Int
    let revisions: String
    let pushed: Bool
    let subject: String?
    let branch: String?
    let remotes: [URL]
    var title: String { "\(pushed ? "Committed & pushed" : "Committed") \(count) \(count == 1 ? "file" : "files")" }

    func showsPush(canCommit: Bool, ahead: UInt32) -> Bool { !pushed && canCommit && ahead > 0 }

    static func parse(_ body: String) -> GitCommitNotice? {
        let lines = body.components(separatedBy: .newlines)
        guard let first = lines.first,
              let regex = try? NSRegularExpression(pattern: #"^Committed ([0-9]+) files?: (.+)$"#),
              let match = regex.firstMatch(in: first, range: NSRange(first.startIndex..., in: first)),
              let countRange = Range(match.range(at: 1), in: first), let count = Int(first[countRange]),
              let revisionsRange = Range(match.range(at: 2), in: first) else { return nil }
        var revisions = String(first[revisionsRange])
        let pushed = revisions.hasSuffix(" · pushed")
        if pushed { revisions.removeLast(" · pushed".count) }
        guard revisions.range(of: #"^[0-9a-fA-F]{7,40}(?: |,|$)"#, options: .regularExpression) != nil else { return nil }
        func value(_ index: Int) -> String? {
            guard lines.indices.contains(index) else { return nil }
            let text = lines[index].trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : text
        }
        let subject = value(1)
        let branchLine = value(2)
        let branch = branchLine.flatMap { $0.hasPrefix("branch ") ? String($0.dropFirst(7)).trimmingCharacters(in: .whitespaces) : nil }
        let remotes = lines.dropFirst(3).compactMap { line -> URL? in
            guard line.hasPrefix("remote "),
                  let url = URL(string: String(line.dropFirst(7))),
                  url.scheme?.lowercased() == "https", url.host?.isEmpty == false,
                  url.user == nil, url.password == nil else { return nil }
            return url
        }
        return GitCommitNotice(count: count, revisions: revisions, pushed: pushed, subject: subject, branch: branch?.isEmpty == false ? branch : nil, remotes: remotes.reduce(into: [URL]()) { if !$0.contains($1) { $0.append($1) } })
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
                    Text(notice.revisions).font(VerdeTheme.mono(11)).foregroundStyle(VerdeTheme.muted).lineLimit(2)
                    if let subject = notice.subject { Text(subject).font(VerdeTheme.ui(12)).foregroundStyle(VerdeTheme.muted).lineLimit(1) }
                    if let branch = notice.branch {
                        Label(branch, systemImage: "arrow.triangle.branch").font(VerdeTheme.mono(10)).lineLimit(1)
                            .padding(.horizontal, 6).padding(.vertical, 3).background(VerdeTheme.border.opacity(0.4), in: Capsule())
                    }
                    ForEach(notice.remotes, id: \.self) { url in
                        Link("View on \(url.host ?? "remote")", destination: url).font(VerdeTheme.ui(12))
                    }
                    if let git, notice.showsPush(canCommit: git.canCommit, ahead: git.ahead) {
                        Button { Task { await git.push() } } label: {
                            HStack {
                                if git.isPushing { ProgressView() }
                                Text("Push")
                            }
                        }.disabled(git.busy).accessibilityIdentifier("git-receipt-push")
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
