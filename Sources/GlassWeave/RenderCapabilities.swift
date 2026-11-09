import Metal

/// A snapshot of what one specific `MTLDevice` reports it can do.
///
/// The package's deployment target says which *operating systems* can load
/// GlassWeave. It says nothing about which *GPU features* a particular device
/// supports. Query this survey for the device that will actually render, and
/// make backend decisions from it rather than from the OS version or a
/// device name.
public struct RenderCapabilities: Sendable, Equatable {
    /// The device's reported name, for diagnostics only. Never branch on it.
    public let deviceName: String
    /// Whether the device reports the Metal 3 feature family.
    public let supportsMetal3: Bool
    /// Whether the device reports the Metal 4 feature family.
    ///
    /// This only says the Metal 4 API family is available. GlassWeave renders
    /// through conventional Metal command submission by default (the
    /// shipped backend, see ``submissionBackend(preferringMetal4:)``). An
    /// experimental Metal 4 submission path exists at package level (GW-11);
    /// the decision record `docs/decisions/metal-backend.md` states whether a
    /// measurement ever justifies shipping it.
    public let supportsMetal4: Bool
    /// The highest `MTLGPUFamily.appleN` the device reports, or `nil` when it
    /// reports none (for example, a non-Apple GPU).
    public let highestAppleFamily: Int?

    /// The highest `appleN` family number the survey probes.
    static let appleFamilyProbeLimit = 16

    /// Surveys the given device. Creates no command queue, pipeline, or
    /// resource, so it is cheap and safe to call before rendering starts.
    public init(device: any MTLDevice) {
        self.init(deviceName: device.name) { device.supportsFamily($0) }
    }

    /// Builds a survey from a family probe. Internal so tests can describe a
    /// device without owning one.
    init(deviceName: String, supportsFamily: (MTLGPUFamily) -> Bool) {
        self.deviceName = deviceName
        self.supportsMetal3 = supportsFamily(.metal3)
        #if targetEnvironment(simulator)
        // The iOS Simulator SDK does not declare `MTLGPUFamily.metal4`, so a
        // simulator never offers the Metal 4 family to this package.
        self.supportsMetal4 = false
        #else
        self.supportsMetal4 = supportsFamily(.metal4)
        #endif
        // Probe by raw value so the survey compiles against SDKs that predate
        // newer `appleN` case names. `MTLGPUFamily.apple1` is raw value 1001.
        let appleBase = MTLGPUFamily.apple1.rawValue
        self.highestAppleFamily = (1...Self.appleFamilyProbeLimit).last { n in
            MTLGPUFamily(rawValue: appleBase + n - 1).map(supportsFamily) ?? false
        }
    }
}

/// The command-submission API a draw goes through (GW-11, experimental).
///
/// Both backends run the same shader library and the same pipeline states.
/// ``conventional`` is the shipped path and the only one any host uses by
/// default; ``metal4`` is a package-level experiment with no public API.
package enum SubmissionBackend: String, Sendable, Hashable {
    /// `MTLCommandQueue` and `MTLCommandBuffer`.
    case conventional
    /// `MTL4CommandQueue`, command allocators, argument tables, and a
    /// residency set. Never available on the iOS Simulator.
    case metal4
}

extension RenderCapabilities {
    /// The backend an experiment may use on this device: ``SubmissionBackend/metal4``
    /// only when the caller asks for it and the device reports the Metal 4
    /// family, otherwise ``SubmissionBackend/conventional``, the defined
    /// fallback. Passing `false` (the default everywhere in the package)
    /// always selects the conventional backend.
    package func submissionBackend(preferringMetal4: Bool) -> SubmissionBackend {
        preferringMetal4 && supportsMetal4 ? .metal4 : .conventional
    }
}
