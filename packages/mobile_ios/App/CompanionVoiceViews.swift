import AVFoundation
import SwiftUI
import UIKit

/// Five bars following the microphone level; static with Reduce Motion (it only follows input).
struct LevelMeter: View {
    let level: Double
    var color: Color = VerdeTheme.accent
    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<5, id: \.self) { index in
                let weight = [0.55, 0.8, 1, 0.8, 0.55][index]
                Capsule().fill(color)
                    .frame(width: 3, height: 4 + 16 * CGFloat(min(1, max(0, level * weight))))
            }
        }
        .frame(height: 20)
        .animation(.linear(duration: 0.08), value: level)
        .accessibilityHidden(true)
    }
}

/// The sheet's voice row above the composer: live transcript and meter while listening, a stop
/// control while a reply is read aloud, and the mic (tap to start, tap to send; hold also works).
struct CompanionVoiceBar: View {
    let voice: CompanionVoice
    let name: String
    let send: (String) -> Void
    @State private var press: (start: Date, startedByPress: Bool)?

    var body: some View {
        HStack(spacing: 10) {
            if voice.listening {
                LevelMeter(level: voice.level)
                Text(voice.partial.isEmpty ? "Listening…" : voice.partial)
                    .font(VerdeTheme.ui(14)).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(voice.partial.isEmpty ? "Listening" : voice.partial)
                Button { voice.cancel() } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                    .accessibilityLabel("Cancel voice message")
            } else if voice.speaking {
                Image(systemName: "speaker.wave.2.fill").foregroundStyle(VerdeTheme.accent).accessibilityHidden(true)
                Text("\(name) is speaking").font(VerdeTheme.ui(13)).foregroundStyle(VerdeTheme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Stop") { voice.stopSpeaking() }.font(VerdeTheme.ui(13, bold: true))
                    .frame(minHeight: 44)
                    .accessibilityHint("Stops reading the reply aloud.")
            } else {
                Text(voice.notice ?? "Hold or tap the mic to talk to \(name).")
                    .font(VerdeTheme.ui(12)).foregroundStyle(voice.notice == nil ? VerdeTheme.subtle : VerdeTheme.warning)
                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            }
            mic
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
    }

    private var mic: some View {
        let active = voice.listening
        return ZStack {
            Circle().fill(active ? VerdeTheme.accent : VerdeTheme.panel)
            Circle().stroke(active ? VerdeTheme.accent : VerdeTheme.border)
            Image(systemName: active ? "arrow.up" : "mic.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(active ? VerdeTheme.background : VerdeTheme.text)
        }
        .frame(width: 44, height: 44)
        .contentShape(Circle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard press == nil else { return }
                let starting = !voice.listening
                press = (Date(), starting)
                if starting {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    Task { await voice.start() }
                }
            }
            .onEnded { _ in
                guard let current = press else { return }
                press = nil
                if micRelease(startedByPress: current.startedByPress, elapsed: Date().timeIntervalSince(current.start)) == .send { finish() }
            })
        .accessibilityElement()
        .accessibilityLabel(active ? "Send voice message" : "Talk to \(name)")
        .accessibilityHint(active ? "Stops listening and sends what you said." : "Starts listening. Activate again to send.")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            if voice.listening { finish() } else { Task { await voice.start() } }
        }
        .accessibilityIdentifier("companion-mic")
    }

    private func finish() {
        Task {
            if let text = await voice.finish() { send(text) }
        }
    }
}

/// Voice preferences, stored on this device only.
struct CompanionVoiceSettings: View {
    @AppStorage(CompanionVoiceStore.readAloudKey) private var readAloud = ""
    @AppStorage(CompanionVoiceStore.rateKey) private var rate = 1.0
    @AppStorage(CompanionVoiceStore.voiceKey) private var voiceID = ""
    @AppStorage(CompanionVoiceStore.serverRecognitionKey) private var serverRecognition = false

    var body: some View {
        let policy = effectiveReadAloud(stored: readAloud, voiceOverRunning: UIAccessibility.isVoiceOverRunning)
        let voices = companionVoices()
        Section {
            Picker("Read replies aloud", selection: Binding(get: { policy }, set: { readAloud = $0.rawValue })) {
                ForEach(ReadAloud.allCases) { Text($0.label).tag($0) }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Speaking rate").font(VerdeTheme.ui(13))
                Slider(value: $rate, in: 0.6...1.4, step: 0.1) {
                    Text("Speaking rate")
                } minimumValueLabel: { Image(systemName: "tortoise") } maximumValueLabel: { Image(systemName: "hare") }
                    .accessibilityValue(String(format: "%.1f times", rate))
            }
            Picker("Voice", selection: $voiceID) {
                Text("Best available").tag("")
                ForEach(voices, id: \.identifier) { voice in
                    Text(voiceLabel(voice)).tag(voice.identifier)
                }
            }
            Toggle("Allow server recognition", isOn: $serverRecognition)
        } header: { Text("Voice") } footer: {
            Text("Speech is recognized on this iPhone. Server recognition sends audio to Apple only when on-device recognition isn't available for your language. Get better voices in iOS Settings › Accessibility › Spoken Content › Voices.")
        }
    }

    private func voiceLabel(_ voice: AVSpeechSynthesisVoice) -> String {
        switch voice.quality {
        case .premium: return voice.name + " (Premium)"
        case .enhanced: return voice.name + " (Enhanced)"
        default: return voice.name
        }
    }
}
