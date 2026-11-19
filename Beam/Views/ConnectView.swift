import SwiftUI

/// Shown until the lamp is ready: one illustration, one sentence, the lamps found.
struct ConnectView: View {
    @Environment(LampManager.self) private var lamp

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                Spacer(minLength: 40)

                Image(systemName: headerSymbol)
                    .font(.system(size: 64, weight: .semibold))
                    .foregroundStyle(.tint)
                    .symbolEffect(.pulse, isActive: isBusy)
                    .frame(width: 128, height: 128)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 36, style: .continuous))

                VStack(spacing: 8) {
                    Text(title)
                        .font(.rounded(.title2, weight: .bold))
                        .multilineTextAlignment(.center)
                    Text(message)
                        .font(.rounded(.body))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 24)

                if !lamp.discovered.isEmpty, lamp.state != .waitingForButton {
                    CardList(title: nil) {
                        ForEach(lamp.discovered) { d in
                            Button { lamp.connect(d) } label: {
                                ItemRow(symbol: "flashlight.on.fill", color: Color("Accent"),
                                        title: d.name, subtitle: d.isNao ? "NAO+" : nil, chevron: true)
                            }
                            .buttonStyle(.plain)
                            .disabled(lamp.state == .connecting)
                        }
                    }
                }

                if lamp.state == .idle || isFailed {
                    BigButton(title: "Search for lamp") { lamp.startScan() }
                }
            }
            .padding(Theme.spacing)
        }
        .background(Theme.background)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { LogView() } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .onAppear { if lamp.state == .idle { lamp.startScan() } }
    }

    private var isBusy: Bool {
        [.scanning, .connecting, .waitingForButton].contains(lamp.state)
    }
    private var isFailed: Bool {
        if case .failed = lamp.state { return true }
        return false
    }

    private var headerSymbol: String {
        switch lamp.state {
        case .bluetoothOff: "antenna.radiowaves.left.and.right.slash"
        case .waitingForButton: "hand.tap.fill"
        case .failed: "exclamationmark.triangle.fill"
        default: "flashlight.on.fill"
        }
    }

    private var title: String {
        switch lamp.state {
        case .bluetoothOff: "Bluetooth is off"
        case .scanning: lamp.discovered.isEmpty ? "Looking for your NAO+" : "Choose your lamp"
        case .connecting: "Connecting…"
        case .waitingForButton: "Press the button"
        case .failed: "Couldn't connect"
        default: "Connect your NAO+"
        }
    }

    private var message: String {
        switch lamp.state {
        case .bluetoothOff: "Turn on Bluetooth and allow this app to use it."
        case .scanning: "Turn the lamp on and keep it close to your iPhone."
        case .connecting: "Just a moment."
        case .waitingForButton: "Briefly press the button on the lamp. If your iPhone asks to pair, accept."
        case .failed(let msg): msg
        default: "Turn the lamp on and keep it close to your iPhone."
        }
    }
}

/// Bluetooth log, kept for troubleshooting.
struct LogView: View {
    @Environment(LampManager.self) private var lamp

    var body: some View {
        List(lamp.log.reversed(), id: \.self) { line in
            Text(line).font(.system(.caption, design: .monospaced))
        }
        .navigationTitle("Log")
        .toolbar { ShareLink(item: lamp.log.joined(separator: "\n")) }
    }
}
