import SwiftUI

/// An orb that swells with whoever is talking; with Reduce Motion it only changes brightness.
struct LiveOrb: View {
    let input: Double
    let output: Double
    var size: CGFloat = 64
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let level = max(input, output)
        let still = reduceMotion || AppearanceSettings.shared.reducedMotion
        ZStack {
            Circle().fill(VerdeTheme.accent.opacity(0.18 + 0.3 * level))
                .scaleEffect(still ? 1 : 1 + 0.35 * level)
            Circle().fill(output > input ? VerdeTheme.accent : VerdeTheme.text.opacity(0.85))
                .frame(width: size * 0.55, height: size * 0.55)
                .scaleEffect(still ? 1 : 1 + 0.15 * level)
        }
        .frame(width: size, height: size)
        .animation(still ? nil : .easeOut(duration: 0.12), value: level)
        .accessibilityHidden(true)
    }
}

/// Live conversation controls in the Companion sheet: orb, captions, provider and voice, Mute, End.
struct LiveVoicePanel: View {
    let live: LiveVoice

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 14) {
                LiveOrb(input: live.inputLevel, output: live.outputLevel)
                VStack(alignment: .leading, spacing: 4) {
                    Text(live.phase == .connecting ? "Connecting…" : "Live").font(VerdeTheme.ui(15, bold: true))
                    if !live.label.isEmpty { Text(live.label).font(VerdeTheme.ui(12)).foregroundStyle(VerdeTheme.muted) }
                    if let notice = live.notice { Text(notice).font(VerdeTheme.ui(12)).foregroundStyle(VerdeTheme.warning).lineLimit(2) }
                }
                Spacer(minLength: 0)
            }
            if !live.userCaption.isEmpty || !live.assistantCaption.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    if !live.userCaption.isEmpty {
                        Text(live.userCaption).font(VerdeTheme.ui(13)).foregroundStyle(VerdeTheme.muted).lineLimit(2)
                    }
                    if !live.assistantCaption.isEmpty {
                        Text(live.assistantCaption).font(VerdeTheme.ui(14)).lineLimit(4)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
            HStack(spacing: 12) {
                Button { live.setMuted(!live.muted) } label: {
                    Label(live.muted ? "Unmute" : "Mute", systemImage: live.muted ? "mic.slash.fill" : "mic.fill")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .accessibilityHint(live.muted ? "Lets your companion hear you again." : "Stops sending your voice.")
                Button(role: .destructive) { live.end() } label: {
                    Label("End", systemImage: "xmark").frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityHint("Ends the live conversation.")
            }
        }
        .padding(12)
        .background(VerdeTheme.panel, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(VerdeTheme.accent.opacity(0.6)))
        .padding(.horizontal, 12).padding(.bottom, 8)
    }
}

/// Companion settings → Live voice: providers configured on the desktop and their keys.
struct LiveVoiceSettings: View {
    let browse: BrowseModel

    var body: some View {
        let client = LiveVoiceClient(browse: browse)
        let view = client.view
        Section {
            if let view, view.supported {
                if view.providers.isEmpty {
                    Text(view.loading ? "Loading providers…" : "No live voice providers on this host.").foregroundStyle(VerdeTheme.muted)
                }
                ForEach(view.providers) { provider in
                    NavigationLink {
                        LiveProviderEditor(browse: browse, provider: provider, isDefault: provider.id == view.default_provider)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(provider.label)
                                if provider.id == view.default_provider {
                                    Text("Default").font(VerdeTheme.ui(11, bold: true)).foregroundStyle(VerdeTheme.accent)
                                }
                            }
                            Text(provider.keyDescription).font(VerdeTheme.ui(12))
                                .foregroundStyle(provider.configured ? VerdeTheme.muted : VerdeTheme.warning)
                        }
                    }
                }
            } else if view?.supported == false {
                Text("Update verde on the computer to use live voice.").foregroundStyle(VerdeTheme.muted)
            } else {
                Text("Loading providers…").foregroundStyle(VerdeTheme.muted)
            }
        } header: { Text("Live voice") } footer: {
            Text("Talk with your companion in real time (double-tap the bubble or use Live in the companion sheet). Uses your own xAI, OpenAI or Google API key, kept on your desktop. ChatGPT, SuperGrok and Gemini app subscriptions don't include API access.")
        }
        .task(id: browse.hostID) { await client.refresh() }
    }
}

private struct LiveProviderEditor: View {
    let browse: BrowseModel
    let provider: LiveVoiceProvider
    let isDefault: Bool
    @State private var apiKey = ""
    @State private var voice = ""
    @State private var model = ""
    @State private var makeDefault = false
    @State private var saving = false
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                SecureField(provider.configured ? "Replace API key" : "API key", text: $apiKey)
                    .textContentType(.password)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("live-api-key")
            } header: { Text("API key") } footer: {
                Text("\(provider.keyDescription). A new key is sent to your desktop and stored only there; it never stays on this phone. Subscriptions like ChatGPT, SuperGrok or Gemini don't include API access — create a key in the provider's developer console.")
            }
            if !provider.voices.isEmpty {
                Section("Voice") {
                    Picker("Voice", selection: $voice) {
                        ForEach(provider.voices, id: \.self) { Text($0).tag($0) }
                    }
                }
            }
            Section {
                TextField("Model", text: $model).textInputAutocapitalization(.never).autocorrectionDisabled()
            } header: { Text("Advanced") } footer: { Text("Leave as is unless you need a specific realtime model.") }
            Section {
                Toggle("Use for live voice by default", isOn: $makeDefault)
            }
            if let message { Text(message).foregroundStyle(message == "Saved." ? VerdeTheme.accent : VerdeTheme.warning) }
            Button {
                Task {
                    saving = true
                    let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                    let error = await LiveVoiceClient(browse: browse).configure(
                        provider: provider.id, apiKey: key.isEmpty ? nil : key,
                        model: model == provider.model ? nil : model, voice: voice == provider.voice ? nil : voice,
                        makeDefault: makeDefault == isDefault ? nil : makeDefault)
                    apiKey = "" // Never kept on the phone.
                    saving = false
                    message = error ?? "Saved."
                }
            } label: { if saving { ProgressView() } else { Text("Save on desktop") } }
            .disabled(saving)
        }
        .scrollContentBackground(.hidden)
        .background(VerdeTheme.background)
        .navigationTitle(provider.label)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            voice = provider.voice.isEmpty ? provider.voices.first ?? "" : provider.voice
            model = provider.model
            makeDefault = isDefault
        }
        .onDisappear { apiKey = "" }
    }
}
