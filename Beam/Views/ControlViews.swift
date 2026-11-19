import SwiftUI

/// Sheet: one big number and a slider.
struct LiveView: View {
    @Environment(LampManager.self) private var lamp
    @Environment(\.dismiss) private var dismiss
    @State private var autonomy: Double = 0
    @State private var started = false

    var body: some View {
        VStack(spacing: 24) {
            if started {
                VStack(spacing: 4) {
                    Text(Duration.seconds(Int(autonomy) * 60).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)))
                        .font(.rounded(.largeTitle, weight: .bold))
                        .contentTransition(.numericText())
                        .monospacedDigit()
                    Text("of light")
                        .font(.rounded(.subheadline))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $autonomy,
                       in: Double(lamp.liveRange.lowerBound)...Double(lamp.liveRange.upperBound),
                       step: 5) {
                    Text("Run time")
                } minimumValueLabel: {
                    Image(systemName: "sun.max.fill")
                } maximumValueLabel: {
                    Image(systemName: "sun.min")
                } onEditingChanged: { editing in
                    if !editing { lamp.updateLive(autonomy: Int(autonomy)) }
                }
                Text("Slide left for more light and less time.")
                    .font(.rounded(.footnote))
                    .foregroundStyle(.secondary)
                Spacer()
                BigButton(title: "Done") { lamp.stopLive(); dismiss() }
            } else {
                Spacer()
                Image(systemName: "lightbulb.slash")
                    .font(.system(size: 44)).foregroundStyle(.secondary)
                Text("Turn the lamp on first.")
                    .font(.rounded(.headline))
                Text("Then open this screen again.")
                    .font(.rounded(.subheadline)).foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(24)
        .navigationTitle("Adjust light")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !started, lamp.startLive() else { return }
            started = true
            let r = lamp.liveRange
            autonomy = Double(min(max(lamp.liveCurrentAutonomy ?? r.lowerBound, r.lowerBound), r.upperBound))
        }
        .onDisappear { lamp.stopLive() }
    }
}

/// Sheet: three big choices.
struct RedModeView: View {
    @Environment(LampManager.self) private var lamp

    var body: some View {
        VStack(spacing: 20) {
            HStack(spacing: 12) {
                choice("Steady", "light.max", .constant, code: 0x01)
                choice("Blinking", "light.beacon.max", .blink, code: 0x03)
                choice("Off", "power", .off, code: 0x00)
            }
            Spacer()
        }
        .padding(24)
        .navigationTitle("Red light")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func choice(_ title: String, _ symbol: String, _ mode: RedMode, code: UInt8) -> some View {
        let selected = lamp.general?.redMode == code
        return Button { lamp.setRedMode(mode) } label: {
            VStack(spacing: 10) {
                Image(systemName: symbol).font(.title2.weight(.semibold))
                Text(title).font(.rounded(.subheadline, weight: .semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 100)
            .foregroundStyle(selected ? .white : .primary)
            .background(selected ? AnyShapeStyle(Color.red.gradient) : AnyShapeStyle(Theme.card),
                        in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// Sheet: type a message, send it.
struct SOSView: View {
    @Environment(LampManager.self) private var lamp
    @State private var text = "SOS"
    @State private var error: String?

    var body: some View {
        VStack(spacing: 16) {
            TextField("Message", text: $text)
                .font(.rounded(.title2, weight: .bold))
                .multilineTextAlignment(.center)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .padding(.vertical, 18)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))

            Text(hint)
                .font(.rounded(.footnote))
                .foregroundStyle(Morse.unsupported(in: text).isEmpty && error == nil ? Color.secondary : .orange)
                .multilineTextAlignment(.center)

            Spacer()

            if lamp.sosActive {
                BigButton(title: "Stop", color: .gray) { lamp.stopSOS() }
            } else {
                BigButton(title: "Send to lamp", color: .pink) {
                    error = lamp.sendSOS(text) ? nil : "Use letters and numbers only."
                }
            }
        }
        .padding(24)
        .navigationTitle("SOS message")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var hint: String {
        if let error { return error }
        let bad = Morse.unsupported(in: text)
        if !bad.isEmpty { return "Won't be sent: \(String(bad.sorted()))" }
        return lamp.sosActive ? "The lamp is repeating your message in Morse." : "The lamp repeats your message in Morse code."
    }
}
