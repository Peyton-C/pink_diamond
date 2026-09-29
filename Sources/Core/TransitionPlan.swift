import Foundation

/// One automated parameter: points over song time with Apple's curve shapes.
struct Automation {
    struct Point { let time: Double; let value: Double; let curve: String }
    let id: String
    let points: [Point]
    let range: ClosedRange<Double>?

    func value(at s: Double) -> Double? {
        guard let first = points.first, let last = points.last else { return nil }
        if s <= first.time { return first.value }
        if s >= last.time { return last.value }
        var i = 0
        while i + 1 < points.count && points[i + 1].time <= s { i += 1 }
        let a = points[i], b = points[min(i + 1, points.count - 1)]
        guard b.time > a.time else { return b.value }
        let f = (s - a.time) / (b.time - a.time)
        let shaped: Double
        switch a.curve {
        case "easedIn": shaped = f * f
        case "easedOut": shaped = 1 - (1 - f) * (1 - f)
        case "easedInOut": shaped = f * f * (3 - 2 * f)
        default: shaped = f
        }
        return a.value + (b.value - a.value) * shaped
    }

    /// Whether the parameter actually changes (constant automations are just settings).
    var moves: Bool { Set(points.map(\.value)).count > 1 }
}

/// How each graph parameter code reaches an Audio Unit: box name, parameter index, default value.
struct GraphWire { let box: String; let index: UInt32; let defaultValue: Double }

/// One song's half of a transition.
struct TransitionSide {
    let start: Double                    // song time where the transition starts
    let end: Double                      // song time where it ends
    let automations: [String: Automation]
    let wiring: [String: GraphWire]

    func rate(at s: Double) -> Double { automations["ts_rate"]?.value(at: s) ?? 1 }

    /// Song time → seconds since the transition started (integrating the playback-rate curve).
    func transitionTime(at s: Double) -> Double {
        guard s > start else { return s - start }
        let step = 0.02
        var t = 0.0, x = start
        while x < min(s, end) {
            let dx = min(step, min(s, end) - x)
            t += dx / max(rate(at: x + dx / 2), 0.01)
            x += dx
        }
        return s > end ? t + (s - end) : t
    }
}

struct TransitionPlan {
    let algorithm: String
    let styleID: Int?
    let outgoing: TransitionSide
    let incoming: TransitionSide
    let duration: Double          // transition length on the playback clock
    let pivot: Double             // seconds into the transition where the handoff happens
    let json: Data

    var styleName: String {
        let words = algorithm.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// Short effect labels for UI badges.
    var effectSummary: [String] {
        var names: [String] = []
        let all = Array(outgoing.automations.values) + Array(incoming.automations.values)
        for a in all where a.moves {
            let name = EffectCatalog.family(of: a.id)
            if let name, !names.contains(name) { names.append(name) }
        }
        return names
    }

    init(json: Data) throws {
        self.json = json
        guard let plan = try JSONSerialization.jsonObject(with: json) as? [String: Any],
              let summary = plan["summary"] as? [String: Any],
              let schedule = plan["schedule"] as? [String: Any],
              let continuous = schedule["continuous"] as? [String: Any] else {
            throw PlannerError("not a continuous (macOS 27) transition plan")
        }
        let body = continuous["_0"] as? [String: Any] ?? continuous
        let strategy = summary["strategy"] as? [String: Any]
        algorithm = (strategy?["algorithm"] as? [String: Any])?.keys.first ?? "unknown"
        styleID = strategy?["styleID"] as? Int

        var wiring = [String: GraphWire]()
        if let text = ((plan["audioGraph"] as? [String: Any])?["dspGraph"] as? [String: Any])?["_0"] as? String {
            let lines = text.components(separatedBy: "\n")
            var defaults = [String: Double]()
            for l in lines where l.hasPrefix("param ") {
                let p = l.split(separator: " ")
                if p.count >= 3 { defaults[String(p[1])] = Double(p[2]) ?? 0 }
            }
            for l in lines where l.hasPrefix("wireGraphParam ") {
                let p = l.replacingOccurrences(of: "(", with: " ").replacingOccurrences(of: ")", with: " ")
                    .split(separator: " ").map(String.init)
                if p.count >= 4 { wiring[p[1]] = GraphWire(box: p[2], index: UInt32(p[3]) ?? 0, defaultValue: defaults[p[1]] ?? 0) }
            }
        }

        func side(_ name: String, _ key: String) -> TransitionSide {
            let s = body["\(name)SongSchedule"] as? [String: Any] ?? [:]
            var autos = [String: Automation]()
            for a in s["automations"] as? [[String: Any]] ?? [] {
                guard let param = a["parameter"] as? [String: Any], let id = param["id"] as? String else { continue }
                let pts = (a["points"] as? [[String: Any]] ?? []).map { p in
                    Automation.Point(time: p["songTime"] as? Double ?? 0, value: p["value"] as? Double ?? 0,
                                     curve: (p["curve"] as? [String: Any])?.keys.first ?? "linear")
                }
                let vr = param["valueRange"] as? [Double]
                autos[id] = Automation(id: id, points: pts, range: vr.flatMap { $0.count == 2 ? $0[0]...$0[1] : nil })
            }
            let r = summary[key] as? [Double] ?? [0, 0]
            return TransitionSide(start: r[0], end: r[1], automations: autos, wiring: wiring)
        }
        outgoing = side("outgoing", "outgoingSongTimeRange")
        incoming = side("incoming", "incomingSongTimeRange")
        let out = body["outgoingSongSchedule"] as? [String: Any]
        duration = ((out?["transitionTimeRange"] as? [Double])?.last) ?? outgoing.transitionTime(at: outgoing.end)
        pivot = out?["referenceTransitionTime"] as? Double ?? duration / 2
    }
}

/// Human names for graph parameter codes (from AURemixFX's own parameter list and the plan's DSP graph).
enum EffectCatalog {
    static func family(of id: String) -> String? {
        switch true {
        case id == "bypa": return nil
        case id == "ts_rate": return "tempo"
        case id.hasSuffix("_gain"): return "volume"
        case id.hasPrefix("RXp"): return "repeater"
        case id.hasPrefix("RXg"): return "gater"
        case id.hasPrefix("RXf"): return "flanger"
        case id.hasPrefix("RXs"): return "phaser"
        case id.hasPrefix("RXt"): return "tape stop"
        case id.hasPrefix("RXv"): return "reverb"
        case id.hasPrefix("RXd"), id.hasPrefix("DL"), id == "Ga4g", id == "Ga3g", id == "Ga2g": return "echo"
        case id.hasPrefix("RXa"), id.hasPrefix("RXb"), id.hasPrefix("HP"), id.hasPrefix("LP"), id.hasPrefix("Fc"): return "filters"
        case id.hasPrefix("RV"): return "reverb"
        default: return nil
        }
    }

    static let names: [String: String] = [
        "ts_rate": "tempo", "out_gain": "volume", "in_gain": "input volume",
        "RXxt": "RemixFX BPM", "RXae": "filter A", "RXaf": "filter A cutoff", "RXar": "filter A resonance", "RXat": "filter A type",
        "RXbe": "filter B", "RXbf": "filter B cutoff", "RXbr": "filter B resonance", "RXbt": "filter B type",
        "RXpe": "repeater", "RXpr": "repeater rate", "RXpm": "repeater mix",
        "RXve": "reverb", "RXvt": "reverb time", "RXvs": "reverb send", "RXvd": "reverb dry", "RXvw": "reverb wet",
        "RXde": "delay", "RXdr": "delay rate", "RXdf": "delay feedback", "RXdg": "delay level",
        "RXge": "gater", "RXgr": "gater rate", "RXgd": "gater depth", "RXgw": "gater width", "RXgg": "gater noise", "RXgf": "gater noise cutoff",
        "RXfe": "flanger", "RXfr": "flanger rate", "RXfm": "flanger mix", "RXff": "flanger feedback", "RXfd": "flanger depth", "RXfc": "flanger center",
        "RXse": "phaser", "RXsr": "phaser rate", "RXsf": "phaser feedback", "RXsm": "phaser mix",
        "RXte": "tape stop", "RXtr": "tape stop rate", "RXls": "LFO sync",
        "HP1f": "high-pass", "HP1r": "high-pass resonance", "LP1f": "low-pass", "LP1r": "low-pass resonance",
        "HP2f": "echo high-pass", "LP2f": "echo low-pass", "Fcf1": "EQ band",
        "DLdw": "echo mix", "DLdt": "echo time", "DLfb": "echo feedback", "DLlf": "echo tone",
        "RVdw": "echo reverb mix", "Ga1g": "input gain", "Ga2g": "echo send", "Ga3g": "dry level", "Ga4g": "echo return",
    ]

    static func name(_ id: String) -> String { names[id] ?? id }
}
