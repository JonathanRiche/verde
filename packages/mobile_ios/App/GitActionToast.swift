import SwiftUI

struct GitActionToast: Equatable, Identifiable {
    enum Phase { case running, success, warning, failure }
    let id = UUID()
    let phase: Phase
    let title: String
    let detail: String
    var rejectedRoots: [String] = []
}

private struct GitModelKey: EnvironmentKey {
    static let defaultValue: GitChangesModel? = nil
}
extension EnvironmentValues {
    var gitChangesModel: GitChangesModel? {
        get { self[GitModelKey.self] }
        set { self[GitModelKey.self] = newValue }
    }
}

struct GitActionToastCard: View {
    let model: GitChangesModel
    var body: some View {
        if let toast = model.toast {
            HStack(alignment: .top, spacing: 10) {
                if toast.phase == .running { ProgressView().tint(VerdeTheme.accent) }
                else {
                    Image(systemName: toast.phase == .success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(toast.phase == .success ? VerdeTheme.accent : toast.phase == .warning ? VerdeTheme.warning : VerdeTheme.danger)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(toast.title).font(VerdeTheme.ui(13, bold: true))
                    if !toast.detail.isEmpty {
                        Text(toast.detail).font(VerdeTheme.ui(12)).foregroundStyle(VerdeTheme.muted).lineLimit(3)
                    }
                    ForEach(toast.rejectedRoots, id: \.self) { root in
                        Button("Pull & push") { Task { await model.pullPush(root) } }.disabled(model.busy)
                    }
                    if model.view?.can_retry == true {
                        Button("Check original operation") { Task { await model.retry() } }.disabled(model.busy)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                if toast.phase != .running {
                    Button { model.dismissToast() } label: { Image(systemName: "xmark").padding(5) }
                        .accessibilityLabel("Dismiss git result")
                }
            }
            .padding(12).foregroundStyle(VerdeTheme.text).tint(VerdeTheme.accent)
            .background(VerdeTheme.panel, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(VerdeTheme.border))
            .padding(.horizontal, 12).padding(.bottom, 8)
            .accessibilityIdentifier("git-result-toast")
            .task(id: toast.id) {
                guard toast.phase == .success else { return }
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                model.expireToast(toast.id)
            }
        }
    }
}
