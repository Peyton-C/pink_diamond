import Foundation

// Runs macOS 27's AutoMix TransitionPlanner (private _SonicKit_MusicKit) in-process.
// The Sonic types are resilient/opaque: values are only decoded, encoded, copied and destroyed through their runtime
// metadata (exported `…Ma` accessors), using Apple's own Codable conformances. The two entry points use Swift's
// calling convention, bridged by Trampoline.s.

@_silgen_name("sonic_call_init")
private func sonic_call_init(_ fn: UnsafeMutableRawPointer, _ result: UnsafeMutableRawPointer,
                             _ config0: UInt64, _ config1: UInt64, _ error: UnsafeMutablePointer<UnsafeRawPointer?>)

@_silgen_name("sonic_call_transition")
private func sonic_call_transition(_ fn: UnsafeMutableRawPointer, _ result: UnsafeMutableRawPointer,
                                   _ from: UnsafeMutableRawPointer, _ to: UnsafeMutableRawPointer,
                                   _ criteria: UnsafeMutableRawPointer, _ planner: UnsafeMutableRawPointer,
                                   _ error: UnsafeMutablePointer<UnsafeRawPointer?>)

struct PlannerError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

final class SonicPlanner {
    static let shared = SonicPlanner()

    private let module = "$s015_SonicKit_MusicB9_Packages"
    private let handle: UnsafeMutableRawPointer?
    private let queue = DispatchQueue(label: "sonic.planner")
    private var plannerBox: Box?

    private init() {
        handle = dlopen("/System/Library/PrivateFrameworks/_SonicKit_MusicKit.framework/_SonicKit_MusicKit", RTLD_NOW)
    }

    var isAvailable: Bool { handle != nil }

    private func symbol(_ mangled: String) throws -> UnsafeMutableRawPointer {
        guard let handle, let p = dlsym(handle, mangled) else { throw PlannerError("missing symbol \(mangled)") }
        return p
    }

    private func type(_ suffix: String) throws -> Any.Type {
        typealias Accessor = @convention(c) (Int) -> UnsafeRawPointer
        let accessor = unsafeBitCast(try symbol(module + suffix + "Ma"), to: Accessor.self)
        return unsafeBitCast(accessor(0), to: Any.Type.self)
    }

    /// Plans a transition between two Song JSON objects (Apple's TransitionPlanner.Song schema).
    /// Returns the Transition as JSON data. Serialized: the planner is only ever used from one thread.
    func plan(from: Data, to: Data) throws -> Data {
        try queue.sync {
            let songType = try type("17TransitionPlannerV4SongV")
            let a = Box(try decodeOpaque(songType, from: from))
            let b = Box(try decodeOpaque(songType, from: to))
            let criteria = Box(try copyGlobal("17TransitionPlannerV8CriteriaV7defaultAEvau", type: try type("17TransitionPlannerV8CriteriaV")))
            let planner = try plannerInstance()
            let transitionType = try type("10TransitionV"), failureType = try type("17TransitionPlannerV13FailureReasonO")

            func openFirst<T>(_: T.Type) throws -> Data {
                func openSecond<E>(_: E.Type) throws -> Data {
                    guard let maker = ResultMaker<T, E>.self as? any ResultMaking.Type else { throw PlannerError("FailureReason not an Error") }
                    let result = Box(maker.resultType)
                    var error: UnsafeRawPointer?
                    sonic_call_transition(
                        try symbol(module + "17TransitionPlannerV10transition4from2to8criterias6ResultOyAA0E0VAC13FailureReasonOGAC4SongV_ApC8CriteriaVtKF"),
                        result.pointer, a.pointer, b.pointer, criteria.pointer, planner.pointer, &error)
                    if let error { throw unsafeBitCast(error, to: Error.self) }
                    result.markInitialized()
                    return try maker.unwrap(result.load())
                }
                return try _openExistential(failureType, do: openSecond)
            }
            return try _openExistential(transitionType, do: openFirst)
        }
    }

    private func plannerInstance() throws -> Box {
        if let plannerBox { return plannerBox }
        let configuration = Box(try copyGlobal("17TransitionPlannerV13ConfigurationV7defaultAEvau", type: try type("17TransitionPlannerV13ConfigurationV")))
        let box = Box(try type("17TransitionPlannerV"))
        // Configuration is a 9-byte POD passed by value in two registers.
        let c0 = configuration.pointer.load(as: UInt64.self)
        let c1 = UInt64(configuration.pointer.load(fromByteOffset: 8, as: UInt8.self))
        var error: UnsafeRawPointer?
        sonic_call_init(try symbol(module + "17TransitionPlannerV13configurationA2C13ConfigurationV_tKcfC"), box.pointer, c0, c1, &error)
        if let error { throw unsafeBitCast(error, to: Error.self) }
        box.markInitialized()
        plannerBox = box
        return box
    }

    private func copyGlobal(_ addressor: String, type: Any.Type) throws -> Any {
        typealias Addressor = @convention(c) () -> UnsafeRawPointer
        let address = unsafeBitCast(try symbol(module + addressor), to: Addressor.self)()
        func copy<T>(_: T.Type) -> Any { address.load(as: T.self) }
        return _openExistential(type, do: copy)
    }
}

// MARK: - Codable bridging

private struct DecoderGrabber: Decodable {
    let decoder: Decoder
    init(from decoder: Decoder) throws { self.decoder = decoder }
}

private struct AnyEncodable: Encodable {
    let value: Encodable
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}

private func decodeOpaque(_ type: Any.Type, from json: Data) throws -> Any {
    guard let t = type as? Decodable.Type else { throw PlannerError("\(type) is not Decodable") }
    return try t.init(from: JSONDecoder().decode(DecoderGrabber.self, from: json).decoder)
}

private func encodeOpaque(_ value: Any) throws -> Data {
    guard let v = value as? Encodable else { throw PlannerError("\(Swift.type(of: value)) is not Encodable") }
    return try JSONEncoder().encode(AnyEncodable(value: v))
}

private protocol ResultMaking {
    static var resultType: Any.Type { get }
    static func unwrap(_ value: Any) throws -> Data
}

private enum ResultMaker<T, E> {}

extension ResultMaker: ResultMaking where E: Error {
    static var resultType: Any.Type { Result<T, E>.self }
    static func unwrap(_ value: Any) throws -> Data {
        switch value as! Result<T, E> {
        case .success(let t): return try encodeOpaque(t)
        case .failure(let e): throw PlannerError("planner declined: \(e)")
        }
    }
}

/// Heap storage sized for an opaque Swift type, so values can be passed indirectly to Swift functions.
private final class Box {
    let type: Any.Type
    let pointer: UnsafeMutableRawPointer
    private var initialized = false

    init(_ type: Any.Type) {
        self.type = type
        func layout<T>(_: T.Type) -> (Int, Int) { (MemoryLayout<T>.size, MemoryLayout<T>.alignment) }
        let (size, align) = _openExistential(type, do: layout)
        pointer = .allocate(byteCount: max(size, 1), alignment: max(align, 16))
    }

    convenience init(_ value: Any) {
        self.init(Swift.type(of: value))
        func store<T>(_ v: T) { pointer.initializeMemory(as: T.self, repeating: v, count: 1) }
        _openExistential(value, do: store)
        initialized = true
    }

    func markInitialized() { initialized = true }

    func load() -> Any {
        func read<T>(_: T.Type) -> Any { pointer.load(as: T.self) }
        return _openExistential(type, do: read)
    }

    deinit {
        if initialized {
            func destroy<T>(_: T.Type) { pointer.assumingMemoryBound(to: T.self).deinitialize(count: 1) }
            _openExistential(type, do: destroy)
        }
        pointer.deallocate()
    }
}
