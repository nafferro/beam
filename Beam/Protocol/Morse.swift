import Foundation

/// Encodes an emergency text the way the lamp expects it:
/// every symbol is 2 bits — dot 00, dash 01, gap between letters 10, gap between words 11.
/// The message ends with 11, padded with 00 up to a whole byte.
/// Frame payload = [number of symbols] + packed bits.
enum Morse {
    static let table: [Character: String] = [
        "A": ".-", "B": "-...", "C": "-.-.", "D": "-..", "E": ".", "F": "..-.",
        "G": "--.", "H": "....", "I": "..", "J": ".---", "K": "-.-", "L": ".-..",
        "M": "--", "N": "-.", "O": "---", "P": ".--.", "Q": "--.-", "R": ".-.",
        "S": "...", "T": "-", "U": "..-", "V": "...-", "W": ".--", "X": "-..-",
        "Y": "-.--", "Z": "--..",
        "0": "-----", "1": ".----", "2": "..---", "3": "...--", "4": "....-",
        "5": ".....", "6": "-....", "7": "--...", "8": "---..", "9": "----.",
    ]

    enum Symbol: UInt8 { case dot = 0b00, dash = 0b01, letterGap = 0b10, wordGap = 0b11 }

    static let maxSymbols = 255

    /// Symbols for a text, or nil if it has no encodable characters.
    static func symbols(for text: String) -> [Symbol]? {
        let words = text.uppercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map { $0.filter { table[$0] != nil } }
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }

        var out: [Symbol] = []
        for (wi, word) in words.enumerated() {
            for (ci, ch) in word.enumerated() {
                out += table[ch]!.map { $0 == "." ? .dot : .dash }
                if ci < word.count - 1 { out.append(.letterGap) }
            }
            if wi < words.count - 1 { out.append(.wordGap) }
        }
        return out
    }

    static func payload(for text: String) -> [UInt8]? {
        guard var syms = symbols(for: text) else { return nil }
        // Terminator only when padding is needed, exactly like the original firmware client.
        if syms.count % 4 != 0 { syms.append(.wordGap) }
        guard syms.count <= maxSymbols else { return nil }
        let count = UInt8(syms.count)
        var bytes: [UInt8] = []
        var i = 0
        while i < syms.count {
            var b: UInt8 = 0
            for k in 0..<4 {
                let s = i + k < syms.count ? syms[i + k].rawValue : 0
                b |= s << UInt8(6 - 2 * k)
            }
            bytes.append(b)
            i += 4
        }
        return [count] + bytes
    }

    /// Characters the user typed that the lamp cannot send.
    static func unsupported(in text: String) -> Set<Character> {
        Set(text.uppercased().filter { !$0.isWhitespace && table[$0] == nil })
    }
}
