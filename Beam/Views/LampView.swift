import SwiftUI

/// Home: two tiles, the profiles, three extras. Everything else is in the ⋯ menu.
struct LampView: View {
    @Environment(LampManager.self) private var lamp
    @State private var profiles: [LampProfile] = (try? ProfileStore.loadFactoryProfiles()) ?? []
    @State private var confirmProfile: LampProfile?
    @State private var sheet: Sheet?

    enum Sheet: String, Identifiable { case live, red, sos; var id: String { rawValue } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 12) {
                    StatTile(title: "Battery", value: batteryText,
                             symbol: batterySymbol, color: .green)
                    StatTile(title: "Now", value: modeText,
                             symbol: "light.beacon.max.fill", color: Color("Accent"))
                }

                CardList(title: "Profiles") {
                    ForEach(profiles) { p in
                        Button { confirmProfile = p } label: {
                            ItemRow(symbol: p.symbol, color: p.color, title: p.displayName,
                                    checked: lamp.profileName == p.lampName)
                        }
                        .buttonStyle(.plain)
                    }
                }

                CardList(title: "More") {
                    Button { sheet = .live } label: {
                        ItemRow(symbol: "slider.horizontal.3", color: .orange, title: "Adjust light", chevron: true)
                    }.buttonStyle(.plain)
                    Button { sheet = .red } label: {
                        ItemRow(symbol: "light.max", color: .red, title: "Red light", chevron: true)
                    }.buttonStyle(.plain)
                    Button { sheet = .sos } label: {
                        ItemRow(symbol: "sos", color: .pink, title: "SOS message", chevron: true)
                    }.buttonStyle(.plain)
                }
            }
            .padding(Theme.spacing)
        }
        .background(Theme.background)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { lamp.refreshAll() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    NavigationLink { LampInfoView() } label: { Label("About the lamp", systemImage: "info.circle") }
                    NavigationLink { LogView() } label: { Label("Bluetooth log", systemImage: "list.bullet.rectangle") }
                    Divider()
                    Button { lamp.disconnect() } label: { Label("Disconnect", systemImage: "xmark.circle") }
                    Button(role: .destructive) { lamp.forgetLamp() } label: { Label("Forget lamp", systemImage: "trash") }
                } label: {
                    if lamp.pendingCommands > 0 { ProgressView() } else { Image(systemName: "ellipsis.circle") }
                }
            }
        }
        .refreshable { lamp.refreshStatus() }
        .sheet(item: $sheet) { s in
            NavigationStack {
                switch s {
                case .live: LiveView()
                case .red: RedModeView()
                case .sos: SOSView()
                }
            }
            .presentationDetents([.medium, .large])
            .presentationCornerRadius(28)
        }
        .confirmationDialog("Use the \(confirmProfile?.displayName ?? "") profile?",
                            isPresented: Binding(get: { confirmProfile != nil }, set: { if !$0 { confirmProfile = nil } }),
                            titleVisibility: .visible) {
            Button("Use this profile") {
                if let p = confirmProfile { lamp.apply(profile: p) }
                confirmProfile = nil
            }
        } message: {
            Text("This replaces the settings currently on the lamp.")
        }
    }

    private var batteryText: String {
        guard let l = lamp.battery?.level else { return "—" }
        return l.formatted(.percent.precision(.fractionLength(0)))
    }

    private var batterySymbol: String {
        guard let l = lamp.battery?.level else { return "battery.0percent" }
        switch l {
        case ..<0.15: return "battery.0percent"
        case ..<0.4: return "battery.25percent"
        case ..<0.65: return "battery.50percent"
        case ..<0.9: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    private var modeText: String {
        guard let m = lamp.general?.mode else { return "—" }
        switch m {
        case .off: return "Off"
        case .reactive(let n): return "Reactive \(n)"
        case .constant(let n): return "Steady \(n)"
        case .red: return "Red"
        case .unknown: return "—"
        }
    }
}

/// Technical details, out of the way.
struct LampInfoView: View {
    @Environment(LampManager.self) private var lamp

    var body: some View {
        List {
            Section("Profile on the lamp") {
                LabeledContent("Name", value: lamp.profileName ?? "—")
                ForEach(0..<3, id: \.self) { i in
                    if let v = lamp.dynamicVariants[i] {
                        LabeledContent("Reactive \(i + 1)", value: hours(v.autonomy))
                    }
                }
                ForEach(0..<3, id: \.self) { i in
                    if let v = lamp.staticVariants[i] {
                        LabeledContent("Steady \(i + 1)", value: hours(v.autonomy))
                    }
                }
            }
            Section("Lamp") {
                if let s = lamp.software { LabeledContent("Firmware", value: s.firmware) }
                if let s = lamp.batterySoftware { LabeledContent("Battery firmware", value: s.firmware) }
                if let b = lamp.battery { LabeledContent("Charge cycles", value: "\(b.totalCharges)") }
                if let d = lamp.device { LabeledContent("Serial number", value: d.serialNumber) }
            }
        }
        .navigationTitle("About the lamp")
    }

    private func hours(_ minutes: Int) -> String {
        Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .narrow))
    }
}
