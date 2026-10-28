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

/// The floating call bar over the companion conversation (desktop and Grok style): the companion,
/// dots that rise with whoever is talking, then settings, captions, mute and a red end. Tapping the
/// companion or the dots opens the full view.
struct LivePill: View {
    let live: LiveVoice
    let character: CompanionCharacter
    let name: String
    @Binding var captionsShown: Bool
    let expand: () -> Void
    let openSettings: () -> Void

    private var speaking: Bool { live.phase == .live && live.outputLevel > 0.04 }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Button(action: expand) {
                    HStack(spacing: 10) {
                        CompanionAvatar(character: character, width: 26)
                            .frame(width: 40, height: 40)
                            .background(VerdeTheme.accent.opacity(0.19), in: Circle())
                            .overlay(Circle().stroke(speaking ? VerdeTheme.accent : VerdeTheme.border))
                        LiveDots(live: live, speaking: speaking)
                            .frame(maxWidth: .infinity, minHeight: 40, maxHeight: 40)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(liveStatus(live, speaking: speaking, name: name))
                .accessibilityHint("Opens the full Live view.")
                LivePillButton(systemImage: "gearshape", label: "Voice settings", tone: .plain, action: openSettings)
                LivePillButton(systemImage: "captions.bubble", label: captionsShown ? "Hide captions" : "Show captions",
                               tone: captionsShown ? .selected : .plain) { captionsShown.toggle() }
                LivePillButton(systemImage: live.muted ? "mic.slash.fill" : "mic.fill", label: live.muted ? "Unmute" : "Mute",
                               tone: live.muted ? .warning : .plain) { live.setMuted(!live.muted) }
                    .disabled(live.phase != .live)
                LivePillButton(systemImage: "xmark", label: "End live conversation", tone: .danger) { live.end() }
            }
            .padding(6)
            .background(VerdeTheme.alternate, in: Capsule())
            .overlay(Capsule().stroke(VerdeTheme.border))
            .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
            if captionsShown {
                LiveCaptionsCard(live: live, name: name)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: expand)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint("Opens the full Live view.")
            }
        }
        .frame(maxWidth: 420)
        .padding(.horizontal, 12)
    }
}

/// "Listening", "Moss is speaking", "Muted"… for the pill's spoken label.
func liveStatus(_ live: LiveVoice, speaking: Bool, name: String) -> String {
    switch live.phase {
    case .connecting: return "Connecting…"
    case .live: return live.muted ? "Muted" : (speaking ? "\(name) is speaking" : "Listening")
    case .failed: return "Live voice stopped"
    case .idle: return "Live voice"
    }
}

private struct LivePillButton: View {
    enum Tone { case plain, selected, warning, danger }
    let systemImage: String
    let label: String
    let tone: Tone
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        let colors: (fill: Color, ring: Color, tint: Color) = {
            switch tone {
            case .plain: return (VerdeTheme.panel, VerdeTheme.border, VerdeTheme.muted)
            case .selected: return (VerdeTheme.accent.opacity(0.19), VerdeTheme.accent, VerdeTheme.accent)
            case .warning: return (VerdeTheme.danger.opacity(0.18), VerdeTheme.danger, VerdeTheme.danger)
            case .danger: return (VerdeTheme.danger, VerdeTheme.danger, Color.white)
            }
        }()
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(colors.tint.opacity(enabled ? 1 : 0.4))
                .frame(width: 40, height: 40)
                .background(colors.fill, in: Circle())
                .overlay(Circle().stroke(colors.ring))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// A row of dots that rise into a wave with the loudness of whoever is talking; one travelling dot
/// while connecting. With Reduce Motion the wave holds still and only follows the level.
private struct LiveDots: View {
    let live: LiveVoice
    let speaking: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let still = reduceMotion || AppearanceSettings.shared.reducedMotion
        let level = min(max(speaking ? live.outputLevel : (live.muted ? 0 : live.inputLevel), 0), 1)
        let connecting = live.phase == .connecting
        let tint: Color = speaking ? VerdeTheme.accent : (live.phase == .live && !live.muted ? VerdeTheme.muted : VerdeTheme.subtle)
        let accent = VerdeTheme.accent
        let subtle = VerdeTheme.subtle
        TimelineView(.animation(paused: still)) { timeline in
            let phase = still ? 0 : timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4 * 2 * Double.pi
            Canvas { context, size in
                let dot: CGFloat = 4
                let step: CGFloat = 8
                let count = max(Int((size.width + step - dot) / step), 1)
                let span = CGFloat(count) * step - (step - dot)
                let x0 = (size.width - span) / 2
                let mid = size.height / 2
                let travelling = min(Int(phase / (2 * Double.pi) * Double(count)), count - 1)
                for index in 0..<count {
                    let t = count == 1 ? 0.5 : Double(index) / Double(count - 1)
                    let envelope = 1 - abs(t - 0.5) * 1.4
                    let ripple = 0.65 + 0.35 * sin(Double(index) * 1.9 + phase)
                    let height = connecting ? dot : dot + CGFloat(level * envelope * ripple) * size.height * 0.6
                    let color = connecting ? (index == travelling ? accent : subtle) : tint
                    let rect = CGRect(x: x0 + CGFloat(index) * step, y: mid - height / 2, width: dot, height: height)
                    context.fill(Path(roundedRect: rect, cornerRadius: dot / 2), with: .color(color))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// Under the pill: what you and the companion are saying right now.
private struct LiveCaptionsCard: View {
    let live: LiveVoice
    let name: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if live.userCaption.isEmpty && live.assistantCaption.isEmpty {
                Text(live.phase == .live ? (live.muted ? "Muted. Unmute to talk." : "Listening. Speak naturally.") : liveStatus(live, speaking: false, name: name))
                    .font(VerdeTheme.ui(12)).foregroundStyle(VerdeTheme.subtle)
            }
            if !live.userCaption.isEmpty {
                Text("You: \(live.userCaption)").font(VerdeTheme.ui(12)).foregroundStyle(VerdeTheme.muted).lineLimit(2)
            }
            if !live.assistantCaption.isEmpty {
                Text("\(name): \(live.assistantCaption)").font(VerdeTheme.ui(12)).foregroundStyle(VerdeTheme.text).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(VerdeTheme.alternate, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(VerdeTheme.border))
        .accessibilityElement(children: .combine)
    }
}

/// The full Live view, opened from the pill: the orb, what you and the companion are saying in
/// big type, provider and voice, Mute and End. The chevron goes back to the pill.
struct LiveVoiceFullView: View {
    let live: LiveVoice
    let name: String
    let collapse: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Button(action: collapse) {
                    Image(systemName: "chevron.down").font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(VerdeTheme.muted).frame(width: 44, height: 44)
                }
                .accessibilityLabel("Show the conversation")
                Spacer()
            }
            LiveOrb(input: live.inputLevel, output: live.outputLevel, size: 120)
            VStack(spacing: 4) {
                Text(liveStatus(live, speaking: live.phase == .live && live.outputLevel > 0.04, name: name)).font(VerdeTheme.ui(15, bold: true))
                if !live.label.isEmpty { Text(live.label).font(VerdeTheme.ui(12)).foregroundStyle(VerdeTheme.muted) }
                if let notice = live.notice { Text(notice).font(VerdeTheme.ui(12)).foregroundStyle(VerdeTheme.warning).lineLimit(2) }
            }
            .accessibilityElement(children: .combine)
            ScrollView {
                VStack(spacing: 12) {
                    if !live.userCaption.isEmpty {
                        Text(live.userCaption).font(VerdeTheme.ui(17)).foregroundStyle(VerdeTheme.muted)
                            .frame(maxWidth: .infinity, alignment: .trailing).multilineTextAlignment(.trailing)
                    }
                    if !live.assistantCaption.isEmpty {
                        Text(live.assistantCaption).font(VerdeTheme.ui(22)).foregroundStyle(VerdeTheme.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .textSelection(.enabled)
                .padding(.horizontal, 4)
            }
            .defaultScrollAnchor(.bottom)
            HStack(spacing: 12) {
                Button { live.setMuted(!live.muted) } label: {
                    Label(live.muted ? "Unmute" : "Mute", systemImage: live.muted ? "mic.slash.fill" : "mic.fill")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .disabled(live.phase != .live)
                .accessibilityHint(live.muted ? "Lets your companion hear you again." : "Stops sending your voice.")
                Button(role: .destructive) { live.end() } label: {
                    Label("End", systemImage: "xmark").frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityHint("Ends the live conversation.")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VerdeTheme.background)
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
