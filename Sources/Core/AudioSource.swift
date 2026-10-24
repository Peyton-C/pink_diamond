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
    /// Where the MCP server saves sets, and the app looks for them to import.
    static var sets: URL { support.appendingPathComponent("sets") }
    /// What an agent has written down about each song through the MCP server's tag_songs.
    static var tags: URL { support.appendingPathComponent("tags.json") }
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
    /// Deletes what cache folder `name` holds that was last changed more than `age` seconds ago.
    static func clear(_ name: String, olderThan age: TimeInterval) {
        let files = FileManager.default
        let dir = cache.appendingPathComponent(name)
        for url in (try? files.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            let changed = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if Date().timeIntervalSince(changed) > age { try? files.removeItem(at: url) }
        }
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

    /// The file as an asset of its first audio track alone, which in a stem file is the mixdown. `AVAudioFile` reads
    /// only that track, but MusicUnderstanding plays every track of an asset at once: given a stem file whole it
    /// heard the mixdown and the four stems on top, the song twice over, and measured Shake It Off at -12.8 LUFS
    /// with a peak of 1.78 against -18.8 and 0.89 for the mixdown alone. Built in memory, nothing is written.
    static func mixdown(of url: URL) async throws -> AVAsset {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard tracks.count > 1, let first = tracks.min(by: { $0.trackID < $1.trackID }) else { return asset }
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw PlannerError("could not read the mixdown of \(url.lastPathComponent)")
        }
        // From zero on the file's clock, as the cache's extracted mixdowns were, so beats land where they did.
        try track.insertTimeRange(CMTimeRange(start: .zero, duration: try await asset.load(.duration)), of: first, at: .zero)
        return composition
    }

    static let stemNames = ["drums", "bass", "other", "vocals"]

    /// The names a stem file gives its four stems, in `stemNames` order, when they aren't the stock Drums, Bass,
    /// Other and Vocals: a graft can put a sax where Other usually is (Run Away with Me (RF IN SX) has Drums,
    /// Bass & Synths, Sax, Vocals), and an agent that reads `other` pulls the hook out as background. Nil otherwise.
    ///
    /// Native Instruments keeps them as JSON at moov/udta/stem. Read the way Track 10's stemfile.c reads them: walk
    /// the top-level boxes to moov, which sits after the audio, and read only moov, so a file costs a few hundred KB
    /// of reads whatever its size.
    static func customStemNames(for url: URL) -> [String]? {
        guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        func u64(_ bytes: [UInt8]) -> UInt64 { bytes.reduce(0) { $0 << 8 | UInt64($1) } }
        /// A box's size and header length from its first 16 bytes, or nil when they don't make sense.
        func header(_ b: [UInt8], left: UInt64) -> (size: UInt64, header: UInt64)? {
            guard b.count >= 8 else { return nil }
            var size = u64(Array(b[0..<4])), head: UInt64 = 8
            if size == 1 { guard b.count >= 16 else { return nil }; size = u64(Array(b[8..<16])); head = 16 }
            if size == 0 { size = left }
            return size >= head && size <= left ? (size, head) : nil
        }
        // To moov on disk. 64 MB is far beyond any moov: it is sample tables and tags.
        let end = (try? file.seekToEnd()) ?? 0
        var offset: UInt64 = 0, moov: [UInt8]?
        while offset + 8 <= end {
            try? file.seek(toOffset: offset)
            guard let b = try? file.read(upToCount: 16), let (size, head) = header(Array(b), left: end - offset) else { return nil }
            if Array(b[4..<8]) == Array("moov".utf8) {
                guard size - head <= 64 << 20 else { return nil }
                try? file.seek(toOffset: offset + head)
                moov = (try? file.read(upToCount: Int(size - head))).map(Array.init)
                break
            }
            offset += size
        }
        // Then udta/stem inside it, in memory.
        func child(_ type: String, in data: ArraySlice<UInt8>) -> ArraySlice<UInt8>? {
            var pos = data.startIndex
            while pos + 8 <= data.endIndex {
                guard let (size, head) = header(Array(data[pos..<min(pos + 16, data.endIndex)]), left: UInt64(data.endIndex - pos)) else { return nil }
                if Array(data[(pos + 4)..<(pos + 8)]) == Array(type.utf8) { return data[(pos + Int(head))..<(pos + Int(size))] }
                pos += Int(size)
            }
            return nil
        }
        guard let moov, let udta = child("udta", in: moov[...]), let stem = child("stem", in: udta),
              let json = try? JSONSerialization.jsonObject(with: Data(stem)) as? [String: Any],
              let stems = json["stems"] as? [[String: Any]], stems.count == 4 else { return nil }
        let names = stems.map { $0["name"] as? String ?? "" }
        guard zip(names, stemNames).contains(where: { $0.lowercased() != $1 }) else { return nil }
        return names
    }

    /// A stem file's four stems (drums, bass, other, vocals: tracks 1 to 4, in Native Instruments' order), read
    /// straight from the file when a mix plays them. A stem file plays as its mixdown without any of this:
    /// `AVAudioFile` reads a file's first track, which in a stem file is the mixdown.
    ///
    /// Both used to be extracted into the cache by passthrough export, which came to 28 GB for the library, half of
    /// it copies of files since retagged or moved. Read in place they are the same audio: the mixdown is sample for
    /// sample what the extracted one was, and a stem decoded here is within 1e-7 of it and starts on the same sample,
    /// so stems stay on the beat grid the mixdown's analysis found (12 songs across Official, FN, RF, RF AT and RB).
    /// The extracted copies were only ever 1088 frames short at the end.
    struct Stems {
        let asset: AVURLAsset
        let tracks: [AVAssetTrack]
        let duration: Double

        /// All four, decoded to 44.1 kHz stereo float.
        func decode() throws -> [AVAudioPCMBuffer] { try tracks.indices.map(decode) }

        /// Stem `index` (in `stemNames` order), decoded to 44.1 kHz stereo float.
        func decode(_ index: Int) throws -> AVAudioPCMBuffer {
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: tracks[index], outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: true, AVLinearPCMIsBigEndianKey: false,
                AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2,
            ])
            reader.add(output)
            try reader.start()
            let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
            var buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(duration * sampleRate) + 8192)!
            while let sample = output.copyNextSampleBuffer() {
                let n = CMSampleBufferGetNumSamples(sample), at = Int(buffer.frameLength)
                if at + n > Int(buffer.frameCapacity) {   // the duration undercounted: grow rather than drop the end
                    let bigger = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount((at + n) * 2))!
                    for c in 0..<2 { bigger.floatChannelData![c].update(from: buffer.floatChannelData![c], count: at) }
                    bigger.frameLength = buffer.frameLength
                    buffer = bigger
                }
                let list = AudioBufferList.allocate(maximumBuffers: 2)
                defer { free(list.unsafeMutablePointer) }
                for c in 0..<2 {
                    list[c] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(n * 4), mData: buffer.floatChannelData![c] + at)
                }
                let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(n), into: list.unsafeMutablePointer)
                guard status == noErr else { throw PlannerError("could not decode \(asset.url.lastPathComponent) (\(status))") }
                buffer.frameLength = AVAudioFrameCount(at + n)
            }
            if reader.status == .failed { throw reader.error ?? PlannerError("could not decode \(asset.url.lastPathComponent)") }
            return buffer
        }
    }

    /// The stems of the stem file at `url`, ready to decode.
    static func stems(of url: URL) async throws -> Stems {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio).sorted { $0.trackID < $1.trackID }
        guard tracks.count >= 5 else { throw PlannerError("\(url.lastPathComponent) has no stems") }
        return Stems(asset: asset, tracks: Array(tracks[1...4]), duration: try await asset.load(.duration).seconds)
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
