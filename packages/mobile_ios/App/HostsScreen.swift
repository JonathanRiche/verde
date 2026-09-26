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
    @State private var label = ""
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
                    if model.rows.isEmpty { Text("No saved hosts. Add a host to pair with Verde.") }
                    ForEach(model.rows, id: \.saved.id) { row in
                        Section { HostCard(model: model, row: row, onUse: onUse) { confirmation = $0 } }
                    }
                    Section {
                        Button("Add host") { adding = true }.accessibilityIdentifier("addHost")
                    }
                }
            }
            .navigationTitle("Hosts")
        }
        .alert("Add host", isPresented: $adding) {
            TextField("Host name", text: $label)
            Button("Continue") {
                model.add(label: label)
                label = ""
            }
            Button("Cancel", role: .cancel) { label = "" }
        }
        .onChange(of: label) { _, value in if value.count > 128 { label = String(value.prefix(128)) } }
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
                 : "Verde will revoke this phone's access to this host and remove its local credential and trust. Other hosts stay paired.")
        }
    }
}

private struct HostCard: View {
    let model: HostsModel
    let row: HostRow
    let onUse: () -> Void
    let confirm: (Confirmation) -> Void

    var body: some View {
        let id = row.saved.id
        let pending = row.busy || row.operation?.state == "pending"
        let failure = row.operation?.error ?? row.view?.error
        let status = hostStatus(row)
        HStack(spacing: 8) {
            Circle().fill(hostDotColor(row)).frame(width: 12, height: 12).accessibilityLabel(status)
            Text(row.saved.label).font(.headline)
            Spacer()
            if model.active == id { Text("Selected").font(.caption).foregroundStyle(.secondary) }
        }
        Text(status).accessibilityIdentifier("hostStatus")
        if failure?.code == "sign_out_unconfirmed" {
            Text("Sign out could not be confirmed. Your local pairing is still saved.")
            Text("If you remove it anyway, this device may remain listed on the desktop. Revoke it there when you can.")
                .font(.footnote).foregroundStyle(.secondary)
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
        } else {
            if row.view?.auth_state == "paired" && row.view?.trust_proposal == nil {
                Button("Use \(row.saved.label)") { model.select(id); onUse() }.disabled(pending || row.fatal)
            } else if row.view?.auth_state != "signing_out" {
                Button("Pair / review host") { model.showPairing(id) }.disabled(pending || row.fatal)
            }
            if failure?.retryable == true { Button("Retry connection") { model.retry(id) }.disabled(pending) }
        }
        if pending {
            VStack(alignment: .leading) {
                ProgressView().progressViewStyle(.linear)
                Text("Finishing host action…").font(.footnote)
            }
        }
        if let view = row.view, !["loading", "signed_out", "signing_out"].contains(view.auth_state) {
            Button("Sign out of host", role: .destructive) { confirm(Confirmation(id: id, name: row.saved.label, forget: false)) }
                .disabled(pending || row.fatal).accessibilityIdentifier("signOutHost")
        }
    }
}
