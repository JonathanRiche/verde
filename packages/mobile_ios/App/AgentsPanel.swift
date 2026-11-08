import SwiftUI

struct AgentsWaitingBar: View {
    let agents: ChatOrchestration
    let open: () -> Void
    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(agents.title).font(VerdeTheme.ui(13, bold: true))
                    Text(agents.summary).font(VerdeTheme.ui(12)).foregroundStyle(VerdeTheme.muted)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Text(agents.needs_you ? "Review agents" : "View agents").font(VerdeTheme.ui(12))
            }
            .foregroundStyle(agents.needs_you ? VerdeTheme.warning : VerdeTheme.accent)
            .padding(12).frame(minHeight: 44)
            .background(VerdeTheme.panel, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).padding(.horizontal, 8).padding(.vertical, 4)
        .accessibilityLabel("\(agents.title). \(agents.summary). \(agents.needs_you ? "Review agents" : "View agents")")
    }
}

struct AgentsPanel: View {
    let agents: ChatOrchestration?
    let close: () -> Void
    let open: (ChatLinkedAgent) -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Agents").font(.headline)
                Spacer()
                Button("Close agents", action: close).frame(minWidth: 44, minHeight: 44)
                    .keyboardShortcut(.cancelAction)
            }.padding(.horizontal, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if agents?.error != nil {
                        Text("Couldn't refresh agents. Reconnect to try again.").textSelection(.enabled)
                    }
                    if agents?.links.isEmpty != false {
                        Text(agents?.loading == true ? "Loading agents…" : "No linked agents yet. Delegated chats will appear here.")
                            .textSelection(.enabled).padding(12)
                    }
                    ForEach(agents?.links ?? [], id: \.link_id) { agent in
                        Button { open(agent) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(agent.title).font(VerdeTheme.ui(14, bold: true)).foregroundStyle(VerdeTheme.text)
                                Text(agent.status_label).font(VerdeTheme.ui(12))
                                    .foregroundStyle(agent.needs_you ? VerdeTheme.warning : agent.status == "failed" ? VerdeTheme.danger : ["idle", "aborted", "interrupted"].contains(agent.status) ? VerdeTheme.muted : VerdeTheme.accent)
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(VerdeTheme.alternate, in: Capsule())
                                Text([agent.provider, agent.model].filter { !$0.isEmpty }.joined(separator: " · "))
                                Text(agent.workspace_id)
                                if agent.updated_at_ms > 0 {
                                    Text(agoLabel(agent.updated_at_ms, Int64(Date().timeIntervalSince1970 * 1000)))
                                }
                            }.font(VerdeTheme.ui(12)).foregroundStyle(VerdeTheme.muted)
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).padding(12)
                        }.buttonStyle(.plain)
                            .accessibilityLabel("\(agent.title), \(agent.status_label), \(agent.provider)")
                            .accessibilityHint("Opens child chat. Back returns to the parent.")
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.background(VerdeTheme.panel)
    }
}
