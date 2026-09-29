import SwiftUI

enum Theme {
    static let accent = Color(red: 1.0, green: 0.42, blue: 0.72)        // pink diamond
    static let outgoing = Color(red: 1.0, green: 0.55, blue: 0.35)
    static let incoming = Color(red: 0.35, green: 0.8, blue: 1.0)
    static let panel = Color(white: 0.09)
    static let lane = Color(white: 0.13)
    static let grid = Color.white.opacity(0.08)

    static func styleColor(_ algorithm: String) -> Color {
        switch true {
        case algorithm.contains("HipHop"): Color(red: 0.95, green: 0.75, blue: 0.2)
        case algorithm.contains("Dance"): Color(red: 0.55, green: 0.45, blue: 1.0)
        case algorithm.contains("Pop"): accent
        case algorithm.contains("Filtered"): Color(red: 0.35, green: 0.85, blue: 0.65)
        case algorithm.contains("deadAir"), algorithm.contains("fallback"): Color.gray
        default: Color(red: 0.6, green: 0.7, blue: 0.8)
        }
    }

    static func time(_ t: Double) -> String {
        let s = max(0, t)
        return String(format: "%d:%04.1f", Int(s) / 60, s.truncatingRemainder(dividingBy: 60))
    }
}

enum KeyNotation: String, CaseIterable, Identifiable {
    case lancelot, musical
    static let storageKey = "keyNotation"
    var id: String { rawValue }
    var label: String { self == .lancelot ? "Lancelot" : "Musical" }
}

/// A key as the analysis spells it ("Ab minor", "C# major"), in Lancelot notation and Mixxx's key colours.
struct MusicalKey {
    let tonic: String
    let minor: Bool
    let lancelot: Int?    // 1...12, nil if the tonic isn't recognised

    // Lancelot numbers step round the circle of fifths: C major is 8B, its relative A minor 8A.
    private static let major = ["B": 1, "F#": 2, "C#": 3, "Ab": 4, "Eb": 5, "Bb": 6, "F": 7, "C": 8, "G": 9, "D": 10, "A": 11, "E": 12]
    private static let minorKeys = ["Ab": 1, "Eb": 2, "Bb": 3, "F": 4, "C": 5, "G": 6, "D": 7, "A": 8, "E": 9, "B": 10, "F#": 11, "C#": 12]

    // Mixxx's default "Mixxx Key Colors" palette, indexed by Open Key number (C major and A minor are 1, i.e. 8B/8A),
    // from src/util/color/predefinedcolorpalettes.cpp. A key and its relative minor share a colour.
    private static let palette: [UInt32] = [0xFC4949, 0xFE642D, 0xF98C27, 0xFED600, 0x99FE00, 0x42FE3E,
                                            0x0AD58F, 0x0AE7E7, 0x04C9FE, 0x3D8AFD, 0xAC64FE, 0xFD3FEA]

    init(_ name: String) {
        let parts = name.split(separator: " ")
        tonic = parts.first.map(String.init) ?? name
        minor = parts.count > 1 && parts[1] == "minor"
        lancelot = (minor ? Self.minorKeys : Self.major)[tonic]
    }

    func text(_ notation: KeyNotation) -> String {
        switch notation {
        case .lancelot: lancelot.map { "\($0)\(minor ? "A" : "B")" } ?? tonic
        case .musical: tonic + (minor ? "m" : "")
        }
    }

    var color: Color {
        guard let lancelot else { return .gray }
        let rgb = Self.palette[(lancelot - 8 + 12) % 12]
        return Color(red: Double(rgb >> 16 & 0xFF) / 255, green: Double(rgb >> 8 & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255)
    }
}

/// A key in a square of its Mixxx colour, like the key chips in DJ software.
struct KeyBadge: View {
    let key: String
    var notation: KeyNotation?
    @AppStorage(KeyNotation.storageKey) private var stored = KeyNotation.lancelot

    var body: some View {
        let k = MusicalKey(key)
        Text(k.text(notation ?? stored))
            .font(.system(size: 11, weight: .bold)).monospacedDigit()
            .foregroundStyle(.black.opacity(0.85))
            .frame(minWidth: 30)
            .padding(.horizontal, 4).padding(.vertical, 2)
            .background(k.color, in: RoundedRectangle(cornerRadius: 4))
            .fixedSize()
    }
}

struct StyleChip: View {
    let plan: TransitionPlan
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "diamond.fill").font(.system(size: 8))
            Text(plan.styleName)
            if let id = plan.styleID { Text("\(id)").opacity(0.6) }
        }
        .font(.system(size: 11, weight: .semibold))
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Theme.styleColor(plan.algorithm).opacity(0.22), in: Capsule())
        .foregroundStyle(Theme.styleColor(plan.algorithm))
    }
}
