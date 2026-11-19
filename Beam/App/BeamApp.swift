import SwiftUI

@main
struct BeamApp: App {
    @State private var lamp = LampManager()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(lamp)
                .tint(Color("Accent"))
                .fontDesign(.rounded)
        }
    }
}

struct RootView: View {
    @Environment(LampManager.self) private var lamp

    var body: some View {
        NavigationStack {
            Group {
                if lamp.state == .ready {
                    LampView()
                } else {
                    ConnectView()
                }
            }
        }
    }
}
