import Foundation

enum ProfileStore {
    /// The six NAO+ factory profiles (numbers taken from the original app's profile files).
    static func loadFactoryProfiles(bundle: Bundle = .main) throws -> [LampProfile] {
        let candidates = [bundle, Bundle(for: BundleToken.self)]
        guard let url = candidates.lazy.compactMap({ $0.url(forResource: "factory_profiles_nao", withExtension: "json") }).first
        else { throw CocoaError(.fileNoSuchFile) }
        return try JSONDecoder().decode([LampProfile].self, from: Data(contentsOf: url))
    }

    static let behaviorNames: [Int: String] = [
        1: "Balanced",
        2: "Narrower",
        3: "Wider",
        4: "Very wide",
        5: "Wide only",
        6: "Close range",
    ]
}

private final class BundleToken {}
