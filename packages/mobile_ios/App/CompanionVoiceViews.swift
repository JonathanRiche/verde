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

/// The composer's mic (tap to start, tap to send; hold also works). While a reply is read aloud
/// it becomes a stop-speaking button.
struct CompanionMicButton: View {
    let voice: CompanionVoice
    let name: String
    let send: (String) -> Void
    @State private var press: (start: Date, startedByPress: Bool)?

    var body: some View {
        if voice.speaking && !voice.listening {
            Button { voice.stopSpeaking() } label: {
                Image(systemName: "speaker.slash.fill").font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(VerdeTheme.accent).frame(width: 44, height: 44)
            }
            .accessibilityLabel("Stop reading aloud")
        } else {
            mic
        }
    }

    private var mic: some View {
        let active = voice.listening
        return ZStack {
            Circle().fill(active ? VerdeTheme.accent : Color.clear).frame(width: 32, height: 32)
            Image(systemName: active ? "arrow.up" : "mic.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(active ? VerdeTheme.background : VerdeTheme.text)
        }
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
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
