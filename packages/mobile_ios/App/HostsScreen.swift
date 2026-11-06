import SwiftUI

private struct Confirmation: Identifiable {
    let id: String
    let name: String
    let forget: Bool
}

/// Host catalog, switching, pairing entry and sign-out. `onUse` returns to Home
/// after selecting a paired host.
struct HostsScreen: View {
    let model: HostsModel
    var onUse: () -> Void = {}
    @State private var adding = false
    @State private var confirmation: Confirmation?

    var body: some View {
        NavigationStack {
            List {
                if let error = model.error {
                    Text(error).foregroundStyle(.red).accessibilityIdentifier("hostsError")
                }
                if model.loading {
                    if model.busy { ProgressView() }
                    else { Button("Retry loading hosts") { model.load() } }
                } else {
                    if model.rows.isEmpty { Text("No saved hosts. Add a host to pair with verde.") }
                    ForEach(model.rows, id: \.saved.id) { row in
                        Section { HostCard(model: model, row: row, onUse: onUse) { confirmation = $0 } }
                    }
                    Section {
                        Button { adding = true } label: { Label("Add host", systemImage: "plus") }
                            .buttonStyle(TonalButtonStyle())
                            .listRowSeparator(.hidden)
                            .accessibilityIdentifier("addHost")
                    }
                }
            }
            .modifier(ReadableListWidth())
            .navigationTitle("Hosts").modifier(VerdeNavigation())
            .listStyle(.plain).scrollContentBackground(.hidden).background(VerdeTheme.background)
            .modifier(BubbleReserve())
        }
        .modifier(AddHostAlert(model: model, isPresented: $adding))
        .alert(confirmation.map { $0.forget ? "Remove \($0.name) from this phone?" : "Sign out of \($0.name)?" } ?? "",
               isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }),
               presenting: confirmation) { item in
            Button(item.forget ? "Remove anyway" : "Sign out", role: .destructive) {
                model.signOut(item.id, forget: item.forget)
            }
            Button("Cancel", role: .cancel) {}
        } message: { item in
            Text(item.forget
                 ? "This removes the local credential and host trust. This device may remain listed on the desktop until you revoke it there."
                 : "verde will revoke this phone's access to this host and remove its local credential and trust. Other hosts stay paired.")
        }
    }
}

/// Names a new host slot, then `HostsModel.add` opens its pairing sheet.
struct AddHostAlert: ViewModifier {
    let model: HostsModel
    @Binding var isPresented: Bool
    @State private var label = ""

    func body(content: Content) -> some View {
        content
        .alert("Add host", isPresented: $isPresented) {
            TextField("Host name", text: $label)
            Button("Continue") {
                model.add(label: label)
                label = ""
            }
            Button("Cancel", role: .cancel) { label = "" }
        }
        .onChange(of: label) { _, value in if value.count > 128 { label = String(value.prefix(128)) } }
    }
}

/// Top-bar host switcher: every saved host (checkmark on the active one), then "Add new host".
struct HostMenu: View {
    let model: HostsModel
    let add: () -> Void

    var body: some View {
        let rows = model.rows
        let current = model.active.flatMap { model.row($0) }
        Menu {
            Section {
                ForEach(rows, id: \.saved.id) { row in
                    let status = hostStatus(row)
                    Button { model.choose(row.saved.id) } label: {
                        if row.saved.id == model.active {
                            Label { Text(row.saved.label); Text(status) } icon: { Image(systemName: "checkmark") }
                        } else {
                            Text(row.saved.label); Text(status)
                        }
                    }
                    .disabled(row.fatal || row.busy || row.view?.auth_state == "signing_out")
                    .accessibilityIdentifier("host-menu-\(row.saved.id)")
                }
            }
            Section {
                Button(action: add) { Label("Add new host", systemImage: "plus") }
                    .disabled(rows.count >= HostsModel.maxHosts)
                    .accessibilityIdentifier("host-menu-add")
            }
        } label: {
            HStack(spacing: 6) {
                if let current { Circle().fill(hostDotColor(current)).frame(width: 7, height: 7) }
                Text(current?.saved.label ?? "Hosts").font(VerdeTheme.ui(13, bold: true)).lineLimit(1)
                    .frame(maxWidth: 140)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(VerdeTheme.muted)
            }
            .padding(.horizontal, 8).frame(height: 32)
            .modifier(ToolbarChrome())
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .disabled(model.loading)
        .accessibilityLabel("Host: " + (current.map { "\($0.saved.label), \(hostStatus($0))" } ?? "none"))
        .accessibilityHint("Switch host or add a new one")
        .accessibilityIdentifier("host-menu")
    }
}

private struct HostCard: View {
    let model: HostsModel
    let row: HostRow
    let onUse: () -> Void
    let confirm: (Confirmation) -> Void
    @State private var renaming = false
    @State private var nickname = ""

    /// Paired with nothing to review: a tap uses it.
    private var usable: Bool { row.view?.auth_state == "paired" && row.view?.trust_proposal == nil }

    private func open(_ id: String) {
        guard usable else { model.showPairing(id); return }
        if model.active == id || model.select(id) { onUse() }
    }

    var body: some View {
        let id = row.saved.id
        let pending = row.busy || row.operation?.state == "pending"
        let failure = row.operation?.error ?? row.view?.error
        let status = hostStatus(row)
        // S22: a list row: tap to use the host (or review its pairing); actions in the row menu.
        HStack(spacing: 4) {
            Button { open(id) } label: {
                HStack(spacing: 10) {
                    Circle().fill(hostDotColor(row)).frame(width: 12, height: 12).accessibilityHidden(true)
                    // The status is part of the row's text, never the dot's colour alone.
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.saved.label).font(VerdeTheme.ui(16, bold: true))
                        Text(model.active == id ? "\(status) · Selected" : status).font(VerdeTheme.ui(13)).foregroundStyle(VerdeTheme.muted)
                            .accessibilityIdentifier("hostStatus")
                    }
                    Spacer(minLength: 4)
                    Image(systemName: model.active == id ? "checkmark" : "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(model.active == id ? VerdeTheme.accent : VerdeTheme.subtle)
                        .accessibilityHidden(true)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(pending || row.fatal)
            .accessibilityElement(children: .combine)
            .accessibilityHint(usable ? (model.active == id ? "Opens Home" : "Uses this host") : "Reviews the pairing")
            .accessibilityIdentifier("host-row-\(id)")
            Menu {
                Button("Rename machine") { nickname = row.saved.label; renaming = true }
                if !usable && row.view?.auth_state != "signing_out" { Button("Pair / review host") { model.showPairing(id) } }
                if failure?.retryable == true { Button("Retry connection") { model.retry(id) } }
                if let view = row.view, !["loading", "signed_out", "signing_out"].contains(view.auth_state) {
                    Button("Sign out", role: .destructive) { confirm(Confirmation(id: id, name: row.saved.label, forget: false)) }
                }
            } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44).contentShape(Rectangle()).accessibilityLabel("Machine actions") }
            .buttonStyle(.borderless)
            .disabled(pending || row.fatal)
            .alert("Rename machine", isPresented: $renaming) {
                TextField("Name on this phone", text: $nickname)
                Button("Cancel", role: .cancel) {}
                Button("Save") { model.rename(id, label: nickname) }
                    .disabled(nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || nickname.count > 128)
            } message: { Text("This nickname is saved on this phone.") }
        }
        if failure?.code == "sign_out_unconfirmed" {
            Text("Sign out could not be confirmed. Your local pairing is still saved.")
            Text("If you remove it anyway, this device may remain listed on the desktop. Revoke it there when you can.")
                 .font(VerdeTheme.ui(13)).foregroundStyle(.secondary)
            Button("Retry sign out") { model.signOut(id) }.disabled(pending)
            Button("Remove from this phone anyway") { confirm(Confirmation(id: id, name: row.saved.label, forget: true)) }
                .disabled(pending).accessibilityIdentifier("forgetHost")
        } else if failure?.code == "sign_out_delete_failed" {
            Text("Local data could not be removed. Unlock your phone and retry.")
            Button("Retry removal") { model.retry(id) }.disabled(pending)
        } else if row.view?.auth_state == "signed_out" {
            Text("Local credential and host trust have been removed.")
            Button("Remove from hosts") { model.remove(id) }
            Button("Pair again") { model.showPairing(id) }
        } else if failure?.retryable == true {
            Button("Retry connection") { model.retry(id) }.disabled(pending).frame(minHeight: 44)
        }
        if pending {
            VStack(alignment: .leading) {
                ProgressView().progressViewStyle(.linear)
                Text("Finishing host action…") .font(VerdeTheme.ui(13))
            }
        }

    }
}
