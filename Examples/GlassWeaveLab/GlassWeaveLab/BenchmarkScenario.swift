import Foundation

/// GW-09's fixed benchmark workload in the laboratory, selected at launch.
///
/// `-lab.benchmark <mode>` picks one of the five modes of the validation
/// protocol (docs/validation.md, "Fixed first-milestone workload"). Every
/// mode uses the same moving source: the procedural background, a pure
/// function of the deterministic clock, so frame *n* is identical in every
/// mode and run. In a benchmark the frame-ID strip starts off (it can be
/// switched on), the surface's renderer records `RenderMetrics`, Reset also
/// restarts the measurement window, and the diagnostics refresh once a
/// second from a timer instead of from frames.
///
/// The only random element is the lifecycle stress schedule (mode 5), drawn
/// from `-lab.benchmark.seed <number>` (default ``defaultSeed``), so a stress
/// run repeats exactly.
struct BenchmarkScenario: Equatable {
    /// The workload's version. Change it whenever the workload changes, and
    /// report it with every measurement. The package's offscreen
    /// characterization (`CharacterizationTests.Workload.version`) mirrors it.
    static let version = 1
    static let defaultSeed: UInt64 = 0x6757_0009

    enum Mode: String, CaseIterable {
        /// 1. The owned moving background, no custom panel: baseline cost.
        case baseline
        /// 2. The same background plus the native reference glass.
        case native
        /// 3. The same background, the native reference, and one custom panel.
        case custom
        /// 4. Mode 3 with the source frozen and the panel settled: the idle
        ///    scheduling check.
        case idle
        /// 5. Mode 3 under repeated hide/show and resize, driven from the
        ///    seeded schedule, with settled allocations measured before and
        ///    after.
        case lifecycle

        /// The mode's number in the validation protocol.
        var number: Int {
            switch self {
            case .baseline: 1
            case .native: 2
            case .custom: 3
            case .idle: 4
            case .lifecycle: 5
            }
        }

        var showsNativeReference: Bool { self != .baseline }
        var showsCustomPanel: Bool { self != .baseline && self != .native }
        /// The source is frozen at content time zero.
        var freezesSource: Bool { self == .idle }
    }

    let mode: Mode
    let seed: UInt64

    /// The scenario named by the launch arguments, or `nil` for the regular
    /// laboratory.
    static func fromLaunchArguments(_ defaults: UserDefaults = .standard) -> BenchmarkScenario? {
        guard let name = defaults.string(forKey: "lab.benchmark"), let mode = Mode(rawValue: name) else {
            return nil
        }
        let seed = defaults.string(forKey: "lab.benchmark.seed").flatMap { UInt64($0) } ?? defaultSeed
        return BenchmarkScenario(mode: mode, seed: seed)
    }

    /// The diagnostics line naming the workload.
    var summary: String {
        "Benchmark: mode \(mode.number) (\(mode.rawValue)) · scenario v\(Self.version) · seed 0x\(String(seed, radix: 16))"
    }
}

/// Mode 5's stress: ``cycles`` cycles, each hiding and showing the stage and
/// then resizing the surface to an inset drawn from the seed.
struct LifecycleStressSchedule {
    static let cycles = 100
    /// Points cut from the surface's trailing and bottom edges.
    static let insets: [CGFloat] = [0, 24, 48, 96]

    private var generator: SplitMix64

    init(seed: UInt64) {
        generator = SplitMix64(seed: seed)
    }

    mutating func nextInset() -> CGFloat {
        Self.insets[Int(generator.next() % UInt64(Self.insets.count))]
    }
}

/// A small seeded generator, so the stress schedule repeats from run to run.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE5_E4B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
