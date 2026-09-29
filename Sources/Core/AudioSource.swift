import Accelerate
import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

let sampleRate = 44100.0

enum AppPaths {
    static let appName = "pink diamond"
    static var support: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(appName)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static var cache: URL {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent(appName)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static func cacheDir(_ name: String) -> URL {
        let url = cache.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// Stable cache key for a file: path + size + modification date.
func fileKey(_ url: URL) -> String {
    let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
    let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
    let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
    let digest = SHA256.hash(data: Data("\(url.path)|\(size)|\(mtime)".utf8))
    return digest.prefix(10).map { String(format: "%02x", $0) }.joined()
}

enum AudioSource {
    /// Native Instruments stem files: 5 stereo tracks, track 0 is the mixdown (the default track).
    static func isStem(_ url: URL) -> Bool { url.lastPathComponent.lowercased().hasSuffix(".stem.mp4") }

    /// A plain audio file for `url`: the file itself, or for a stem file its mixdown (track 0), extracted once by
    /// passthrough export (no re-encode) into the cache.
    static func playableURL(for url: URL) async throws -> URL {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard isStem(url) || tracks.count > 1 else { return url }
        let out = AppPaths.cacheDir("mixdowns").appendingPathComponent(fileKey(url) + ".m4a")
        if FileManager.default.fileExists(atPath: out.path) { return out }
        guard let mixdown = tracks.min(by: { $0.trackID < $1.trackID }) else { throw PlannerError("no audio track in \(url.lastPathComponent)") }
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw PlannerError("could not create composition track")
        }
        let duration = try await asset.load(.duration)
        try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: mixdown, at: .zero)
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw PlannerError("could not export mixdown")
        }
        let tmp = out.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".m4a")
        try await export.export(to: tmp, as: .m4a)
        try FileManager.default.moveItem(at: tmp, to: out)
        return out
    }

    /// The file's cover art as a JPEG thumbnail, read from its tags once and cached at `cache` (an empty file there
    /// means the song has none). Full-size art runs to megabytes decoded, too much to hold for every row.
    static func artwork(for url: URL, cachedAt cache: URL) async -> Data? {
        if let data = try? Data(contentsOf: cache) { return data.isEmpty ? nil : data }
        guard let items = try? await AVURLAsset(url: url).load(.commonMetadata) else { return nil } // retry next launch
        var thumb: Data?
        if let item = items.first(where: { $0.commonKey == .commonKeyArtwork }),
           let raw = try? await item.load(.dataValue),
           let source = CGImageSourceCreateWithData(raw as CFData, nil),
           let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
               kCGImageSourceCreateThumbnailFromImageAlways: true,
               kCGImageSourceCreateThumbnailWithTransform: true,
               kCGImageSourceThumbnailMaxPixelSize: 256,
           ] as CFDictionary) {
            let out = NSMutableData()
            if let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
                if CGImageDestinationFinalize(dest) { thumb = out as Data }
            }
        }
        try? (thumb ?? Data()).write(to: cache, options: .atomic)
        return thumb
    }

    /// Decodes a file to 44.1 kHz stereo float.
    static func loadPCM(_ url: URL) throws -> AVAudioPCMBuffer {
        let file = try AVAudioFile(forReading: url)
        let target = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let src = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: src)
        if file.processingFormat == target { return src }
        guard let converter = AVAudioConverter(from: file.processingFormat, to: target) else {
            throw PlannerError("unsupported audio format in \(url.lastPathComponent)")
        }
        let capacity = AVAudioFrameCount(Double(file.length) * sampleRate / file.processingFormat.sampleRate) + 4096
        let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity)!
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return src
        }
        if let error { throw error }
        return out
    }
}

/// DJ-style waveform: per ~23 ms window, the peak level and the energy share of low / mid / high bands.
struct Waveform: Codable {
    static let window = 1024
    var peak: [Float] = []
    var low: [Float] = []
    var mid: [Float] = []
    var high: [Float] = []
    var secondsPerPoint: Double { Double(Waveform.window) / sampleRate }

    static func compute(_ buffer: AVAudioPCMBuffer) -> Waveform {
        let n = Int(buffer.frameLength), w = window
        let channels = Int(buffer.format.channelCount)
        var mono = [Float](repeating: 0, count: n)
        for c in 0..<channels {
            vDSP_vadd(mono, 1, buffer.floatChannelData![c], 1, &mono, 1, vDSP_Length(n))
        }
        var scale = 1 / Float(channels)
        vDSP_vsmul(mono, 1, &scale, &mono, 1, vDSP_Length(n))

        let log2n = vDSP_Length(log2(Double(w)))
        guard let fft = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return Waveform() }
        defer { vDSP_destroy_fftsetup(fft) }
        var hann = [Float](repeating: 0, count: w)
        vDSP_hann_window(&hann, vDSP_Length(w), Int32(vDSP_HANN_NORM))
        let binHz = Float(sampleRate) / Float(w)
        let lowEnd = Int(250 / binHz), midEnd = Int(2500 / binHz)

        var result = Waveform()
        var frame = [Float](repeating: 0, count: w)
        var real = [Float](repeating: 0, count: w / 2), imag = [Float](repeating: 0, count: w / 2)
        var mags = [Float](repeating: 0, count: w / 2)
        var start = 0
        while start + w <= n {
            mono.withUnsafeBufferPointer { src in
                var peak: Float = 0
                vDSP_maxmgv(src.baseAddress! + start, 1, &peak, vDSP_Length(w))
                result.peak.append(peak)
                vDSP_vmul(src.baseAddress! + start, 1, hann, 1, &frame, 1, vDSP_Length(w))
            }
            real.withUnsafeMutableBufferPointer { r in
                imag.withUnsafeMutableBufferPointer { i in
                    var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                    frame.withUnsafeBytes { raw in
                        vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(w / 2))
                    }
                    vDSP_fft_zrip(fft, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(w / 2))
                }
            }
            var l: Float = 0, m: Float = 0, h: Float = 0
            vDSP_sve(mags, 1, &l, vDSP_Length(lowEnd))
            vDSP_sve(Array(mags[lowEnd..<midEnd]), 1, &m, vDSP_Length(midEnd - lowEnd))
            vDSP_sve(Array(mags[midEnd...]), 1, &h, vDSP_Length(w / 2 - midEnd))
            // Perceptual-ish weighting so highs aren't swamped by the bass.
            let lw = sqrt(l), mw = sqrt(m) * 1.4, hw = sqrt(h) * 2.2
            let total = max(lw + mw + hw, 1e-9)
            result.low.append(lw / total); result.mid.append(mw / total); result.high.append(hw / total)
            start += w
        }
        return result
    }
}
