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
