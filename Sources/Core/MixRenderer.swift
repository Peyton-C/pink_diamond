import AVFoundation
import AudioToolbox
import Foundation

/// Offline renderer for AutoMix transitions: a chain per song mirroring the plan's DSPGraph
/// (time-stretch → Gain1 → AURemixFX → AUFilter → HP1 → LP1 → {Gain3 | Gain2 → Delay → Reverb → HP2 → LP2 → Gain4} → mixer),
/// automation applied every 512 samples at each song's current song time. Handles any number of songs in sequence,
/// so it renders single-transition previews and whole-playlist mixes.
final class MixRenderer {
    struct Item {
        let audio: URL                 // playable file (stem mixdowns already extracted)
        let beats: [Double]
        let entering: TransitionSide?  // this song's side of the transition into it
        let leaving: TransitionSide?   // this song's side of the transition out of it
    }

    private static let registerSonic: Void = {
        if let h = dlopen("/System/Library/PrivateFrameworks/SonicAudioUnits.framework/SonicAudioUnits", RTLD_NOW),
           let sym = dlsym(h, "registerSonicAudioUnits") {
            unsafeBitCast(sym, to: (@convention(c) () -> Void).self)()
        }
    }()

    static var remixFXAvailable: Bool {
        _ = registerSonic
        return effect("remx") != nil
    }

    fileprivate static func effect(_ subtype: String) -> AVAudioUnitEffect? {
        _ = registerSonic
        let fcc = { (s: String) in s.utf8.reduce(0) { ($0 << 8) | OSType($1) } }
        let d = AudioComponentDescription(componentType: fcc("aufx"), componentSubType: fcc(subtype),
                                          componentManufacturer: fcc("appl"), componentFlags: 0, componentFlagsMask: 0)
        guard AudioComponentFindNext(nil, [d]) != nil else { return nil }
        return AVAudioUnitEffect(audioComponentDescription: d)
    }

    static let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!

    /// Where playback is, reported with every block.
    struct Position {
        let index: Int          // the song the listener hears (index into the items)
        let songTime: Double
        let deck: Int           // the outgoing song of the transition coming up or under way
        let deckOut: Double     // that song's song time
        let deckIn: Double?     // the incoming song's song time, once it has started
    }

    /// Renders `items` in sequence to a file. See `render(_:startTime:tail:progress:write:)`.
    static func render(_ items: [Item], startTime: Double, tail: Double?, to output: URL,
                       progress: ((Double) -> Void)? = nil) throws -> Double {
        let file = try AVAudioFile(forWriting: output, settings: format.settings)
        defer { file.close() }
        return try render(items, startTime: startTime, tail: tail, progress: progress) { buffer, _ in
            try file.write(from: buffer)
            return true
        }
    }

    /// Renders `items` in sequence, handing each block to `write` until it returns false. The first song starts at
    /// `startTime`; rendering stops `tail` seconds after the last song's entering transition ends (or at the last
    /// song's end if `tail` is nil). A song without a `leaving` side hands over to the next when it ends, with no
    /// transition. Returns the seconds rendered.
    static func render(_ items: [Item], startTime: Double, tail: Double?, progress: ((Double) -> Void)? = nil,
                       write: (AVAudioPCMBuffer, Position) throws -> Bool) throws -> Double {
        _ = registerSonic
        let block: AVAudioFrameCount = 512
        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: block)
        let master = AVAudioMixerNode()
        engine.attach(master)
        // Songs take turns on three slots, each the plan's DSP graph, built before the engine starts. Three are
        // enough: at most two songs overlap, and a slot's previous song has long finished when the next one loads.
        // Building a graph per song instead held nine audio units per song for the whole render, and adding one to
        // the running engine delays it unpredictably (4,096 frames when first to play, 536 when incoming, which
        // throws the beat match off by 12 ms).
        let slots = (0..<min(3, items.count)).map { Slot(engine: engine, destination: master, bus: AVAudioNodeBus($0)) }
        let chains = try items.enumerated().map { i, item in try Chain(item: item, slot: slots[i % slots.count]) }
        if let limiter = effect("lmtr") {
            engine.attach(limiter)
            engine.connect(master, to: limiter, format: format)
            engine.connect(limiter, to: engine.mainMixerNode, format: format)
        } else {
            engine.connect(master, to: engine.mainMixerNode, format: format)
        }
        try chains[0].load()
        try engine.start()
        defer { engine.stop() }

        let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: block)!
        // Songs are decoded a couple of seconds after the one before them starts (or five seconds before their
        // transition, whichever is first) and released when they finish, so a long playlist holds at most about three
        // songs in memory, and playback (or a seek) waits on one decode only.
        chains[0].position = max(0, startTime) * sampleRate
        chains[0].active = true
        var activatedAt = [Double](repeating: 0, count: chains.count)
        let last = chains.count - 1
        let total = max(1, (chains.last?.duration ?? 1) + chains.dropLast().map(\.duration).reduce(0, +) - startTime)
        var t = 0.0, stopAt: Double?, current = 0, deck = 0
        while true {
            for i in 0..<last where chains[i].active && !chains[i + 1].active {
                if t >= activatedAt[i] + 2 || chains[i].item.leaving.map({ chains[i].songTime >= $0.start - 5 }) == true {
                    try chains[i + 1].load()
                }
                let handoff = chains[i].item.leaving.map { chains[i].songTime >= $0.start } ?? chains[i].finished
                if handoff {
                    var start = chains[i + 1].item.entering?.start ?? 0
                    // Starting (or seeking) into the middle of a transition: bring the incoming song in at the same
                    // point of it, not at its beginning.
                    if let leaving = chains[i].item.leaving, let entering = chains[i + 1].item.entering,
                       chains[i].songTime > leaving.start + 0.05 {
                        start = entering.songTime(atTransitionTime: leaving.transitionTime(at: chains[i].songTime))
                    }
                    try chains[i + 1].load()
                    chains[i + 1].position = start * sampleRate
                    chains[i + 1].active = true
                    activatedAt[i + 1] = t
                }
            }
            for c in chains where c.active && !c.finished {
                if let leaving = c.item.leaving, c.songTime >= leaving.end { c.finished = true }
                if c.songTime >= c.duration { c.finished = true }
                if c.finished { c.unload() }
            }
            // The listener's song changes halfway through the transition into the next one.
            if current < last, chains[current + 1].active,
               chains[current + 1].songTime >= chains[current + 1].item.entering.map({ ($0.start + $0.end) / 2 }) ?? 0 {
                current += 1
            }
            if deck < last, chains[deck + 1].active,
               chains[deck + 1].songTime >= chains[deck + 1].item.entering?.end ?? 0 {
                deck += 1
            }
            if stopAt == nil, chains[last].active {
                if let tail, let entering = chains[last].item.entering, chains[last].songTime >= entering.end {
                    stopAt = t + tail
                } else if chains[last].finished {
                    stopAt = t + 1
                }
            }
            if let stopAt, t >= stopAt { break }
            if t > total + 120 { break } // safety
            chains.forEach { $0.apply() }
            guard try engine.renderOffline(block, to: buffer) == .success else { break }
            let incoming = deck < last && chains[deck + 1].active ? chains[deck + 1].songTime : nil
            let position = Position(index: current, songTime: chains[current].songTime,
                                    deck: deck, deckOut: chains[deck].songTime, deckIn: incoming)
            guard try write(buffer, position) else { break }
            t += Double(block) / sampleRate
            progress?(min(1, t / total))
        }
        return t
    }
}

/// One set of nodes mirroring the plan's DSP graph, lent to one song at a time.
private final class Slot {
    weak var chain: Chain?
    var source: AVAudioSourceNode!
    let stretch = AVAudioUnitTimePitch()
    let gains: [String: AVAudioMixerNode] = ["Gain1": .init(), "Gain2": .init(), "Gain3": .init(), "Gain4": .init()]
    let mixer = AVAudioMixerNode()
    let output = AVAudioMixerNode()
    var units = [String: AVAudioUnitEffect]()
    // Effect units start active (with factory defaults, e.g. AUHipass at 6.9 kHz), so this must start false: the first
    // apply() outside a transition then really bypasses them. It tracks the units' real state across songs.
    var bypassed = false
    private var used = false

    init(engine: AVAudioEngine, destination: AVAudioMixerNode, bus: AVAudioNodeBus) {
        let format = MixRenderer.format
        // Offline rendering pulls this synchronously on the rendering thread, which also loads and unloads songs, so
        // no locking. Unowned: the slot owns the node.
        source = AVAudioSourceNode(format: format) { [unowned self] isSilence, _, frameCount, abl in
            let buffers = UnsafeMutableAudioBufferListPointer(abl)
            var produced = 0
            if let chain, chain.active, !chain.finished, let audio = chain.audio {
                // An edited transition can bring a song in before its start: silence until song time 0.
                let start = Int(chain.position.rounded(.down))
                let lead = min(Int(frameCount), max(0, -start))
                let copied = max(0, min(Int(frameCount) - lead, Int(audio.frameLength) - max(start, 0)))
                produced = lead + copied
                for (c, buf) in buffers.enumerated() {
                    let dst = buf.mData!.assumingMemoryBound(to: Float.self)
                    let src = audio.floatChannelData![min(c, Int(audio.format.channelCount) - 1)]
                    for i in 0..<lead { dst[i] = 0 }
                    for i in 0..<copied { dst[lead + i] = src[max(start, 0) + i] }
                    for i in produced..<Int(frameCount) { dst[i] = 0 }
                }
                chain.position += Double(produced)
            }
            if produced == 0 {
                for buf in buffers { memset(buf.mData, 0, Int(buf.mDataByteSize)) }
                isSilence.pointee = true
            }
            return noErr
        }
        for (box, sub) in [("AURemixFX", "remx"), ("AUFilter", "filt"), ("AUHipass1", "hpas"), ("AULowpass1", "lpas"),
                           ("AUDelay", "dely"), ("AUReverb", "rvb2"), ("AUHipass2", "hpas"), ("AULowpass2", "lpas")] {
            if let u = MixRenderer.effect(sub) { units[box] = u }
        }
        let nodes: [AVAudioNode] = [source, stretch, mixer, output] + Array(gains.values) + Array(units.values)
        nodes.forEach(engine.attach)
        func link(_ list: [AVAudioNode]) { for (a, b) in zip(list, list.dropFirst()) { engine.connect(a, to: b, format: format) } }
        let u = { (k: String) -> [AVAudioNode] in self.units[k].map { [$0] } ?? [] }
        let dry: [AVAudioNode] = [source, stretch, gains["Gain1"]!] + u("AURemixFX") + u("AUFilter") + u("AUHipass1") + u("AULowpass1")
        link(dry)
        engine.connect(dry.last!, to: [AVAudioConnectionPoint(node: gains["Gain3"]!, bus: 0),
                                       AVAudioConnectionPoint(node: gains["Gain2"]!, bus: 0)], fromBus: 0, format: format)
        link([gains["Gain2"]!] + u("AUDelay") + u("AUReverb") + u("AUHipass2") + u("AULowpass2") + [gains["Gain4"]!])
        engine.connect(gains["Gain3"]!, to: mixer, fromBus: 0, toBus: 0, format: format)
        engine.connect(gains["Gain4"]!, to: mixer, fromBus: 0, toBus: 1, format: format)
        engine.connect(mixer, to: output, format: format)
        engine.connect(output, to: destination, fromBus: 0, toBus: bus, format: format)

        // RemixFX's tempo-synced effects get a musical clock from the current song's beat grid.
        units["AURemixFX"]?.auAudioUnit.musicalContextBlock = { [unowned self] tempoOut, numOut, denOut, beatOut, offsetOut, downbeatOut in
            guard let chain else { return false }
            tempoOut?.pointee = chain.tempo
            numOut?.pointee = 4
            denOut?.pointee = 4
            let beat = chain.beatPosition(chain.songTime)
            beatOut?.pointee = beat
            offsetOut?.pointee = 0
            downbeatOut?.pointee = (beat / 4).rounded(.down) * 4
            return true
        }
    }

    /// Hands the slot to `chain`, clearing what the last song left in the effects (reverb and delay tails, the time
    /// stretcher's buffers). A fresh slot is left alone, so the first songs render exactly as they always have.
    func claim(_ chain: Chain) {
        if used {
            ([stretch] + Array(units.values)).forEach { $0.reset() }
            output.outputVolume = 1
        }
        used = true
        self.chain = chain
    }

    func release(_ chain: Chain) {
        guard self.chain === chain else { return }
        self.chain = nil
        output.outputVolume = 0   // nothing may leak through after a song's exit, reverb tails included
    }
}

private final class Chain {
    let item: MixRenderer.Item
    let duration: Double
    var position: Double = 0
    var active = false
    var finished = false
    var tempo = 120.0
    private(set) var audio: AVAudioPCMBuffer?
    private let slot: Slot

    var songTime: Double { position / sampleRate }

    init(item: MixRenderer.Item, slot: Slot) throws {
        self.item = item
        self.slot = slot
        let file = try AVAudioFile(forReading: item.audio)
        duration = Double(file.length) / file.processingFormat.sampleRate
    }

    func load() throws {
        guard audio == nil, !finished else { return }
        audio = try AudioSource.loadPCM(item.audio)
        slot.claim(self)
    }

    /// Releases the decoded audio and the slot.
    func unload() {
        audio = nil
        slot.release(self)
    }

    func beatPosition(_ t: Double) -> Double {
        let beats = item.beats
        guard beats.count > 1 else { return t * tempo / 60 }
        var lo = 0, hi = beats.count - 1
        while lo < hi { let mid = (lo + hi + 1) / 2; if beats[mid] <= t { lo = mid } else { hi = mid - 1 } }
        let next = lo + 1 < beats.count ? beats[lo + 1] : beats[lo] + (beats[lo] - beats[max(0, lo - 1)])
        return Double(lo) + max(0, min(1, (t - beats[lo]) / max(1e-6, next - beats[lo])))
    }

    /// The transition side active at song time `s`, if any.
    private func side(at s: Double) -> TransitionSide? {
        if let e = item.entering, s >= e.start - 0.001, s <= e.end { return e }
        if let l = item.leaving, s >= l.start, s <= l.end { return l }
        return nil
    }

    func apply() {
        // A finished song has given up its slot, which silenced it.
        guard slot.chain === self, !finished else { return }
        let g = slot
        let s = songTime
        guard let side = side(at: s) else {
            g.stretch.rate = 1
            if !g.bypassed { g.bypassed = true; g.units.values.forEach { $0.bypass = true } }
            // Belt and braces: park the filters wide open in case a unit ignores bypass.
            for (code, w) in (item.leaving ?? item.entering)?.wiring ?? [:] {
                guard let unit = g.units[w.box] else { continue }
                AudioUnitSetParameter(unit.audioUnit, w.index, kAudioUnitScope_Global, 0, AudioUnitParameterValue(w.defaultValue), 0)
                if code == "RXxt" { tempo = w.defaultValue }
            }
            for (box, gain) in g.gains { gain.outputVolume = box == "Gain4" ? 0 : 1 }
            g.output.outputVolume = 1
            return
        }
        g.stretch.rate = Float(side.rate(at: s))
        let bypass = (side.automations["bypa"]?.value(at: s) ?? 1) >= 0.5
        if bypass != g.bypassed { g.bypassed = bypass; g.units.values.forEach { $0.bypass = bypass } }
        func value(_ code: String) -> Double? { side.automations[code]?.value(at: s) ?? side.wiring[code]?.defaultValue }
        for (box, gain) in g.gains {
            let code = side.wiring.first { $0.value.box == box }?.key
            gain.outputVolume = Float(code.flatMap(value) ?? (box == "Gain4" ? 0 : 1))
        }
        g.output.outputVolume = Float(side.automations["out_gain"]?.value(at: s) ?? 1)
        for (code, w) in side.wiring {
            guard let unit = g.units[w.box], let v = value(code) else { continue }
            if code == "RXxt" { tempo = v }
            AudioUnitSetParameter(unit.audioUnit, w.index, kAudioUnitScope_Global, 0, AudioUnitParameterValue(v), 0)
        }
    }
}
