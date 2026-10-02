import Foundation

/// A different plan for the same two songs: Apple's planner run as if the songs had other genres, or with a lower
/// complexity ceiling. Genres pick the style palette (Pop, Dance and Hip-Hop styles only happen when both songs share a
/// family), and the ceiling is the only Criteria field that changes the result: placement tweaks either do nothing or
/// push the planner back to dead-air removal (planner/criteria_sweep.py, Temperature → Poker Face).
struct PlanVariant: Codable, Hashable {
    enum Complexity: String, Codable, CaseIterable {
        case crossFadeWithEffects, crossFade, fallback
        var label: String {
            switch self { case .crossFadeWithEffects: "no time-stretch"; case .crossFade: "no effects"; case .fallback: "short crossfade" }
        }
    }
    var fromGenre: Genre
    var toGenre: Genre
    var complexity: Complexity?

    var key: String { "\(fromGenre.rawValue)>\(toGenre.rawValue)|\(complexity?.rawValue ?? "")" }

    /// Merged into Apple's default `Criteria` JSON.
    var criteriaPatch: [String: Any]? {
        complexity.map { ["maximumTransitionComplexity": [$0.rawValue: [String: Any]()]] }
    }
}

/// A stretch of a song played more than once before it carries on.
struct SongLoop: Codable, Equatable {
    var start: Double            // song seconds; in a TransitionEdit, from the start of that song's side
    var length: Double
    var repeats: Int             // times it plays again after the first
    var extra: Double { length * Double(repeats) }
}

/// What the user changed about a planned transition. Stored instead of an edited plan, so it's small, survives a
/// cache wipe (the planner is deterministic) and reapplies after a replan.
struct TransitionEdit: Codable, Equatable {
    /// An automation point, in song seconds from the start of its side of the transition, so it follows that side when
    /// it's moved.
    struct Point: Codable, Equatable {
        var offset: Double
        var value: Double
        var curve: String
    }

    var variant: PlanVariant?
    var outgoingShift = 0.0      // song seconds the outgoing song's side moved (later in the song is positive)
    var incomingShift = 0.0
    var outgoing: [String: [Point]] = [:]   // automations replaced or added, by graph parameter code
    var incoming: [String: [Point]] = [:]
    /// The transition's length relative to the plan's. Both sides stretch by the same factor, tempo curve included, so
    /// they still cover the same number of beats and take the same time to play: each side's length on the playback
    /// clock is its song-time span × ln(r1/r0)/(r1 − r0), which scales with the span when the rates stay put.
    var lengthScale = 1.0

    // Beyond what Apple's AutoMix does. The app's editor sets none of these; the MCP server does, unless it is run
    // without extensions.
    /// The incoming side's length relative to the plan's, when it isn't the outgoing side's. A transition whose tempo
    /// match is drawn afresh needs it: the two sides then cover the same time on the playback clock, not the same
    /// multiple of what Apple planned.
    var incomingLengthScale: Double?
    /// Song seconds the outgoing song plays on after its side would have ended, so an echo can ring out or a fade can
    /// finish under the new song. Its automation carries on through the tail.
    var outgoingTail = 0.0
    var outgoingLoop: SongLoop?
    var incomingLoop: SongLoop?
    /// Automation lanes with these names set the level of a stem file's stems instead of a graph parameter.
    static let stemLanes = AudioSource.stemNames.map { "stem_" + $0 }

    init(variant: PlanVariant? = nil) { self.variant = variant }

    // Written by hand so edits saved before a field existed still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        variant = try c.decodeIfPresent(PlanVariant.self, forKey: .variant)
        outgoingShift = try c.decodeIfPresent(Double.self, forKey: .outgoingShift) ?? 0
        incomingShift = try c.decodeIfPresent(Double.self, forKey: .incomingShift) ?? 0
        outgoing = try c.decodeIfPresent([String: [Point]].self, forKey: .outgoing) ?? [:]
        incoming = try c.decodeIfPresent([String: [Point]].self, forKey: .incoming) ?? [:]
        lengthScale = try c.decodeIfPresent(Double.self, forKey: .lengthScale) ?? 1
        incomingLengthScale = try c.decodeIfPresent(Double.self, forKey: .incomingLengthScale)
        outgoingTail = try c.decodeIfPresent(Double.self, forKey: .outgoingTail) ?? 0
        outgoingLoop = try c.decodeIfPresent(SongLoop.self, forKey: .outgoingLoop)
        incomingLoop = try c.decodeIfPresent(SongLoop.self, forKey: .incomingLoop)
    }

    /// Whether the edit uses anything Apple's AutoMix has no counterpart for.
    var isExtended: Bool {
        outgoingTail != 0 || outgoingLoop != nil || incomingLoop != nil
            || Self.stemLanes.contains { outgoing[$0] != nil || incoming[$0] != nil }
    }

    var isEmpty: Bool { self == TransitionEdit() }
    /// Whether anything but the variant changed.
    var hasChanges: Bool { self != TransitionEdit(variant: variant) }

    func shift(_ outgoingSide: Bool) -> Double { outgoingSide ? outgoingShift : incomingShift }
    func lanes(_ outgoingSide: Bool) -> [String: [Point]] { outgoingSide ? outgoing : incoming }

    mutating func setShift(_ outgoingSide: Bool, _ value: Double) {
        if outgoingSide { outgoingShift = value } else { incomingShift = value }
    }

    mutating func setLane(_ outgoingSide: Bool, _ id: String, _ points: [Point]?) {
        if outgoingSide { outgoing[id] = points } else { incoming[id] = points }
    }

    /// Sets the length, stretching the user's own automation points with the rest of the transition.
    mutating func setLengthScale(_ scale: Double) {
        let k = scale / lengthScale
        let stretch = { (lanes: [String: [Point]]) in lanes.mapValues { $0.map { Point(offset: $0.offset * k, value: $0.value, curve: $0.curve) } } }
        outgoing = stretch(outgoing)
        incoming = stretch(incoming)
        if let own = incomingLengthScale { incomingLengthScale = own * k }
        lengthScale = scale
    }
}

extension TransitionSide {
    /// This side moved by `shift` song seconds and stretched by `scale` from its start, with `lanes` replacing or adding
    /// automations. The tempo curve moves and stretches with it, so a whole-bar move keeps the downbeats together.
    ///
    /// With `loop`, that stretch of the song repeats, and the side's end and the plan's own points after it move later
    /// by the repeats. `lanes` are not moved: their offsets already count the repeats, so a lane can be drawn across
    /// them. With `tail`, the side runs on that much longer, and the plan's bypass stays off until the new end so
    /// effects drawn into the tail are heard.
    func applying(shift: Double, scale: Double = 1, lanes: [String: [TransitionEdit.Point]], loop: SongLoop? = nil,
                  tail: Double = 0) -> TransitionSide {
        let start = self.start + shift
        let loop = loop.flatMap { $0.length > 0 && $0.repeats > 0 ? SongLoop(start: start + $0.start, length: $0.length, repeats: $0.repeats) : nil }
        let pushFrom = loop.map { $0.start + $0.length } ?? .infinity, extra = loop?.extra ?? 0
        let time = { (t: Double) -> Double in
            let x = start + (t - self.start) * scale
            return x >= pushFrom - 1e-6 ? x + extra : x
        }
        // A loop that runs up to the side's end, or past it, still plays out in full.
        let end = max(time(self.end), loop.map { $0.start + $0.length + extra } ?? -.infinity)
        var autos = automations.mapValues { a in
            Automation(id: a.id, points: a.points.map { p in
                let held = a.id == "bypa" && tail > 0 && time(p.time) >= end - 1e-6
                return .init(time: time(p.time) + (held ? tail : 0), value: p.value, curve: p.curve)
            }, range: a.range)
        }
        for (id, points) in lanes {
            autos[id] = Automation(id: id, points: points.map { .init(time: start + $0.offset, value: $0.value, curve: $0.curve) },
                                   range: automations[id]?.range ?? EffectCatalog.ranges[id])
        }
        return TransitionSide(start: start, end: end + tail, automations: autos, wiring: wiring, loop: loop)
    }

    /// The same side `seconds` later, for a song whose earlier loop has pushed the rest of it back.
    func retimed(by seconds: Double) -> TransitionSide {
        guard seconds != 0 else { return self }
        let autos = automations.mapValues { a in
            Automation(id: a.id, points: a.points.map { .init(time: $0.time + seconds, value: $0.value, curve: $0.curve) }, range: a.range)
        }
        return TransitionSide(start: start + seconds, end: end + seconds, automations: autos, wiring: wiring,
                              loop: loop.map { SongLoop(start: $0.start + seconds, length: $0.length, repeats: $0.repeats) })
    }

    /// An automation's points as edit points, relative to this side's start.
    func editPoints(_ id: String) -> [TransitionEdit.Point] {
        (automations[id]?.points ?? []).map { .init(offset: $0.time - start, value: $0.value, curve: $0.curve) }
    }

    /// What a parameter does when nothing automates it.
    func neutralValue(_ id: String) -> Double {
        id == "out_gain" || id == "ts_rate" ? 1 : wiring[id]?.defaultValue ?? 0
    }
}

extension TransitionPlan {
    func applying(_ edit: TransitionEdit) -> TransitionPlan {
        var plan = self
        plan.outgoing = outgoing.applying(shift: edit.outgoingShift, scale: edit.lengthScale, lanes: edit.outgoing,
                                          loop: edit.outgoingLoop, tail: edit.outgoingTail)
        plan.incoming = incoming.applying(shift: edit.incomingShift, scale: edit.incomingLengthScale ?? edit.lengthScale,
                                          lanes: edit.incoming, loop: edit.incomingLoop)
        plan.duration = duration * edit.lengthScale
        // With its own length or a loop, the incoming side no longer lasts a multiple of the plan's time: the
        // transition is over when that side is.
        if edit.incomingLengthScale != nil || edit.incomingLoop != nil {
            plan.duration = plan.incoming.transitionTime(at: plan.incoming.end)
        }
        plan.pivot = duration > 0 ? pivot * plan.duration / duration : pivot
        return plan
    }
}

/// Effects that can be added to one side of a transition, as the automations that make them up. Most of the graph's
/// effects need more than one parameter set to be heard (RemixFX's effects each have an on switch, the echo needs its
/// send, return and time), so they're added as a set and only the parameter that moves gets a lane.
struct EffectPreset: Identifiable {
    let id: String               // the lane that moves
    let name: String
    let requires: [String]       // graph parameter codes the plan's graph must wire

    /// The automations for a side `length` song seconds long, sweeping in (outgoing) or out (incoming).
    func lanes(length: Double, outgoing: Bool, bpm: Double, side: TransitionSide) -> [String: [TransitionEdit.Point]] {
        func ramp(_ a: Double, _ b: Double, _ curve: String = "linear") -> [TransitionEdit.Point] {
            let (from, to) = outgoing ? (a, b) : (b, a)
            return [.init(offset: 0, value: from, curve: curve), .init(offset: length, value: to, curve: curve)]
        }
        func hold(_ v: Double) -> [TransitionEdit.Point] { [.init(offset: 0, value: v, curve: "linear"), .init(offset: length, value: v, curve: "linear")] }
        var lanes: [String: [TransitionEdit.Point]] = ["bypa": hold(0)]   // effects are bypassed wherever bypa is on
        switch id {
        case "HP1f": lanes["HP1f"] = ramp(10, 1200, "easedIn")
        case "LP1f": lanes["LP1f"] = ramp(22000, 250, "easedOut")
        case "RXvs": lanes.merge(["RXve": hold(1), "RXvt": hold(8), "RXvd": hold(1), "RXvw": hold(0.8), "RXvs": ramp(0, 1)]) { $1 }
        case "RXpm": lanes.merge(["RXpe": hold(1), "RXpr": hold(3), "RXpm": ramp(0, 1)]) { $1 }
        case "RXgd": lanes.merge(["RXge": hold(1), "RXgr": hold(9), "RXgw": hold(0.5), "RXgd": ramp(0, 1)]) { $1 }
        case "RXfm": lanes.merge(["RXfe": hold(1), "RXfr": hold(4), "RXfd": hold(0.3), "RXfc": hold(0.5), "RXff": hold(0.5),
                                  "RXfm": ramp(0, 0.6)]) { $1 }
        case "Ga4g": lanes.merge(["Ga2g": hold(1), "DLdt": hold(min(2, 60 / bpm)), "DLfb": hold(50), "DLdw": hold(100),
                                  "DLlf": hold(3000), "Ga4g": ramp(0, 1)]) { $1 }
        default: break
        }
        // RemixFX's rhythmic effects follow its own tempo parameter, which plans without RemixFX leave at 120 BPM.
        if id.hasPrefix("RX"), side.automations["RXxt"] == nil {
            lanes["RXxt"] = hold((bpm * side.rate(at: side.start)).rounded())
        }
        return lanes
    }

    static let all: [EffectPreset] = [
        .init(id: "HP1f", name: "High-pass sweep", requires: ["HP1f"]),
        .init(id: "LP1f", name: "Low-pass sweep", requires: ["LP1f"]),
        .init(id: "RXvs", name: "Reverb", requires: ["RXve", "RXvs"]),
        .init(id: "Ga4g", name: "Echo", requires: ["Ga2g", "Ga4g", "DLdt"]),
        .init(id: "RXpm", name: "Repeater", requires: ["RXpe", "RXpm"]),
        .init(id: "RXgd", name: "Gater", requires: ["RXge", "RXgd"]),
        .init(id: "RXfm", name: "Flanger", requires: ["RXfe", "RXfm"]),
    ]

    /// Parameter codes each preset sets, so removing its lane removes the rest of it too.
    static func group(of id: String) -> [String] {
        switch id {
        case "RXvs": ["RXve", "RXvt", "RXvd", "RXvw", "RXvs"]
        case "RXpm": ["RXpe", "RXpr", "RXpm"]
        case "RXgd": ["RXge", "RXgr", "RXgw", "RXgd"]
        case "RXfm": ["RXfe", "RXfr", "RXfd", "RXfc", "RXff", "RXfm"]
        case "Ga4g": ["Ga2g", "DLdt", "DLfb", "DLdw", "DLlf", "Ga4g"]
        default: [id]
        }
    }
}
