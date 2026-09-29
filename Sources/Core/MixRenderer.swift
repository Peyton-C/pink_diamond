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

    /// Renders `items` in sequence. The first song starts at `startTime`; rendering stops `tail` seconds after the
    /// last song's entering transition ends (or at the last song's end if `tail` is nil).
    static func render(_ items: [Item], startTime: Double, tail: Double?, to output: URL,
                       progress: ((Double) -> Void)? = nil) throws -> Double {
        _ = registerSonic
        let block: AVAudioFrameCount = 512
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: block)
        let master = AVAudioMixerNode()
        engine.attach(master)
        let chains = try items.map { try Chain(item: $0, format: format) }
        for (i, c) in chains.enumerated() { c.attach(to: engine, destination: master, bus: AVAudioNodeBus(i), format: format) }
        if let limiter = effect("lmtr") {
            engine.attach(limiter)
            engine.connect(master, to: limiter, format: format)
            engine.connect(limiter, to: engine.mainMixerNode, format: format)
        } else {
            engine.connect(master, to: engine.mainMixerNode, format: format)
        }
        try engine.start()
        defer { engine.stop() }

        let file = try AVAudioFile(forWriting: output, settings: format.settings)
        defer { file.close() }
        let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: block)!
        chains[0].position = max(0, startTime) * sampleRate
        chains[0].active = true
        let last = chains.count - 1
        let total = max(1, (chains.last?.duration ?? 1) + chains.dropLast().map(\.duration).reduce(0, +) - startTime)
        var t = 0.0, stopAt: Double?
        while true {
            for i in 0..<last where chains[i].active && !chains[i + 1].active {
                if let leaving = chains[i].item.leaving, chains[i].songTime >= leaving.start {
                    chains[i + 1].position = (chains[i + 1].item.entering?.start ?? 0) * sampleRate
                    chains[i + 1].active = true
                }
            }
            for c in chains where c.active && !c.finished {
                if let leaving = c.item.leaving, c.songTime >= leaving.end { c.finished = true }
                if c.songTime >= c.duration { c.finished = true }
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
            try file.write(from: buffer)
            t += Double(block) / sampleRate
            progress?(min(1, t / total))
        }
        return t
    }
}

private final class Chain {
    let item: MixRenderer.Item
    let audio: AVAudioPCMBuffer
    var position: Double = 0
    var active = false
    var finished = false
    private var bypassed = true
    private var tempo = 120.0

    let source: AVAudioSourceNode
    let stretch = AVAudioUnitTimePitch()
    let gains: [String: AVAudioMixerNode] = ["Gain1": .init(), "Gain2": .init(), "Gain3": .init(), "Gain4": .init()]
    let mixer = AVAudioMixerNode()
    let output = AVAudioMixerNode()
    var units = [String: AVAudioUnitEffect]()

    var songTime: Double { position / sampleRate }
    var duration: Double { Double(audio.frameLength) / sampleRate }

    init(item: MixRenderer.Item, format: AVAudioFormat) throws {
        self.item = item
        audio = try AudioSource.loadPCM(item.audio)
        var this: Chain!
        source = AVAudioSourceNode(format: format) { isSilence, _, frameCount, abl in
            let buffers = UnsafeMutableAudioBufferListPointer(abl)
            let chain = this!
            let total = Int(chain.audio.frameLength)
            var produced = 0
            if chain.active && !chain.finished {
                let start = Int(chain.position)
                produced = max(0, min(Int(frameCount), total - start))
                for (c, buf) in buffers.enumerated() {
                    let dst = buf.mData!.assumingMemoryBound(to: Float.self)
                    let src = chain.audio.floatChannelData![min(c, Int(chain.audio.format.channelCount) - 1)]
                    for i in 0..<produced { dst[i] = src[start + i] }
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
        this = self
        for (box, sub) in [("AURemixFX", "remx"), ("AUFilter", "filt"), ("AUHipass1", "hpas"), ("AULowpass1", "lpas"),
                           ("AUDelay", "dely"), ("AUReverb", "rvb2"), ("AUHipass2", "hpas"), ("AULowpass2", "lpas")] {
            if let u = MixRenderer.effect(sub) { units[box] = u }
        }
    }

    func attach(to engine: AVAudioEngine, destination: AVAudioMixerNode, bus: AVAudioNodeBus, format: AVAudioFormat) {
        let nodes: [AVAudioNode] = [source, stretch, mixer, output] + Array(gains.values) + Array(units.values)
        nodes.forEach(engine.attach)
        func chain(_ list: [AVAudioNode]) { for (a, b) in zip(list, list.dropFirst()) { engine.connect(a, to: b, format: format) } }
        let u = { (k: String) -> [AVAudioNode] in self.units[k].map { [$0] } ?? [] }
        let dry: [AVAudioNode] = [source, stretch, gains["Gain1"]!] + u("AURemixFX") + u("AUFilter") + u("AUHipass1") + u("AULowpass1")
        chain(dry)
        engine.connect(dry.last!, to: [AVAudioConnectionPoint(node: gains["Gain3"]!, bus: 0),
                                       AVAudioConnectionPoint(node: gains["Gain2"]!, bus: 0)], fromBus: 0, format: format)
        chain([gains["Gain2"]!] + u("AUDelay") + u("AUReverb") + u("AUHipass2") + u("AULowpass2") + [gains["Gain4"]!])
        engine.connect(gains["Gain3"]!, to: mixer, fromBus: 0, toBus: 0, format: format)
        engine.connect(gains["Gain4"]!, to: mixer, fromBus: 0, toBus: 1, format: format)
        engine.connect(mixer, to: output, format: format)
        engine.connect(output, to: destination, fromBus: 0, toBus: bus, format: format)

        // RemixFX's tempo-synced effects get a musical clock from the song's beat grid.
        units["AURemixFX"]?.auAudioUnit.musicalContextBlock = { [unowned self] tempoOut, numOut, denOut, beatOut, offsetOut, downbeatOut in
            tempoOut?.pointee = self.tempo
            numOut?.pointee = 4
            denOut?.pointee = 4
            let beat = self.beatPosition(self.songTime)
            beatOut?.pointee = beat
            offsetOut?.pointee = 0
            downbeatOut?.pointee = (beat / 4).rounded(.down) * 4
            return true
        }
    }

    private func beatPosition(_ t: Double) -> Double {
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
        let s = songTime
        if finished {
            output.outputVolume = 0 // nothing may leak through after the song's exit
            return
        }
        guard let side = side(at: s) else {
            stretch.rate = 1
            if !bypassed { bypassed = true; units.values.forEach { $0.bypass = true } }
            for (box, g) in gains { g.outputVolume = box == "Gain4" ? 0 : 1 }
            output.outputVolume = 1
            return
        }
        stretch.rate = Float(side.rate(at: s))
        let bypass = (side.automations["bypa"]?.value(at: s) ?? 1) >= 0.5
        if bypass != bypassed { bypassed = bypass; units.values.forEach { $0.bypass = bypass } }
        func value(_ code: String) -> Double? { side.automations[code]?.value(at: s) ?? side.wiring[code]?.defaultValue }
        for (box, g) in gains {
            let code = side.wiring.first { $0.value.box == box }?.key
            g.outputVolume = Float(code.flatMap(value) ?? (box == "Gain4" ? 0 : 1))
        }
        output.outputVolume = Float(side.automations["out_gain"]?.value(at: s) ?? 1)
        for (code, w) in side.wiring {
            guard let unit = units[w.box], let v = value(code) else { continue }
            if code == "RXxt" { tempo = v }
            AudioUnitSetParameter(unit.audioUnit, w.index, kAudioUnitScope_Global, 0, AudioUnitParameterValue(v), 0)
        }
    }
}
