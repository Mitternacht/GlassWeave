import GlassWeave
import GlassWeaveUIKit
import Metal
import UIKit

/// One of the material bench's procedural backgrounds (GW-21): 8-bit
/// sRGB pages that a glass look is shown over, so it is judged against a
/// known backdrop. `-lab.bench <page>` opens the bench on one; the
/// light-fields demo uses the same pages as its backdrops
/// (`-lab.lightBackdrop <page>`). The shader is `BenchBackgrounds.metal`.
enum BenchPage: Int, CaseIterable {
    /// Bright dots on a 16-point lattice over near-black, for measuring
    /// displacement by centroid.
    case dotGrid
    /// 16-point dark and light cells.
    case checkerboard
    /// Bands of saturated hue running diagonally.
    case ribbons
    /// A graphite wall and floor with a soft spot.
    case charcoal
    /// Warm white with fine grain.
    case paper
    /// Soft shaded spheres on a dusk gradient (GW-22): strong colored edges
    /// and fine structure, so a lens's magnification and dispersion show.
    case orbs
    /// Three stacked backdrops for the light model (GW-23): a pale studio
    /// plate, the orbs, and black with glowing orange liquid.
    case chrome
    /// Warm paper with a graph grid and printed dots (GW-25), for the
    /// depth cues of light mode: shadows and colored caustics.
    case paperDesk
    /// A dusk page with two soft rainbow arcs, colored glows and small
    /// lights (GW-24b), for frost: the blur, the dispersion at the bevel and
    /// the color behind the glass all show.
    case prism
    /// A near-black stage with a faint pool of light from above and a very
    /// dim dot lattice (GW-28): the page the liquid vessels sit on, dark
    /// enough that the liquid is the only light, with just enough structure
    /// for the shell's refraction to show.
    case stage

    /// The name used on the command line and in accessibility identifiers.
    var identifier: String {
        switch self {
        case .dotGrid: "dots"
        case .checkerboard: "checkerboard"
        case .ribbons: "ribbons"
        case .charcoal: "charcoal"
        case .paper: "paper"
        case .orbs: "orbs"
        case .chrome: "chrome"
        case .paperDesk: "paperdesk"
        case .prism: "prism"
        case .stage: "stage"
        }
    }

    var title: String {
        switch self {
        case .dotGrid: String(localized: "Dots")
        case .checkerboard: String(localized: "Checkers")
        case .ribbons: String(localized: "Ribbons")
        case .charcoal: String(localized: "Charcoal")
        case .paper: String(localized: "Paper")
        case .orbs: String(localized: "Orbs")
        case .chrome: String(localized: "Chrome")
        case .paperDesk: String(localized: "Paper desk")
        case .prism: String(localized: "Prism")
        case .stage: String(localized: "Stage")
        }
    }

    /// Whether white text reads on the page.
    var isDark: Bool {
        self != .paper && self != .paperDesk
    }

    /// The page named by a launch argument value: an identifier or an index.
    static func named(_ value: String?) -> BenchPage? {
        guard let value else { return nil }
        return allCases.first { $0.identifier == value } ?? Int(value).flatMap(BenchPage.init(rawValue:))
    }

    /// From `-lab.bench <page>`, or `nil` when the argument is absent.
    static var fromBenchArgument: BenchPage? {
        named(UserDefaults.standard.string(forKey: "lab.bench"))
    }
}

/// Renders a bench page into pooled textures, on demand, in the command
/// buffer GlassWeave then samples it in (as the gallery's background does).
final class BenchBackground {
    enum Failure: Error, CustomStringConvertible {
        case shaderUnavailable(String)

        var description: String {
            switch self {
            case let .shaderUnavailable(reason): "The bench background shader is unavailable: \(reason)."
            }
        }
    }

    /// The presented frame plus the surface's two frames in flight.
    static let textureLimit = 3

    private let pipeline: any MTLRenderPipelineState
    private let pool: FrameTexturePool
    private let clock = ContinuousClock()
    private let start: ContinuousClock.Instant
    private var nextFrameID: UInt64 = 1

    init(device: any MTLDevice) throws {
        guard let library = device.makeDefaultLibrary(),
              let vertex = library.makeFunction(name: "bench_background_vertex"),
              let fragment = library.makeFunction(name: "bench_background_fragment")
        else {
            throw Failure.shaderUnavailable("missing bench_background functions")
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "GlassWeaveLab bench background"
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        do {
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw Failure.shaderUnavailable(String(describing: error))
        }
        pool = FrameTexturePool(
            device: device,
            descriptor: FrameTexturePool.Descriptor(
                pixelFormat: .bgra8Unorm,
                usage: [.renderTarget, .shaderRead, .pixelFormatView],
                sampledPixelFormat: BackgroundColorConvention.sRGBOpaque.requiredPixelFormat
            ),
            capacity: Self.textureLimit
        )
        start = clock.now
    }

    /// Encodes `page` at the given size into `commandBuffer` and returns its
    /// lease, or `nil` when no texture is free (nothing is encoded then).
    func encodeFrame(
        into commandBuffer: any MTLCommandBuffer, page: BenchPage, pixelSize: (width: Int, height: Int), scale: Double
    ) -> BackgroundFrameLease? {
        guard let pooled = pool.checkout(width: pixelSize.width, height: pixelSize.height) else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = pooled.storage
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            pool.returnUnused(pooled)
            return nil
        }
        let frameID = nextFrameID
        nextFrameID += 1
        var parameters = [SIMD4<Float>(
            Float(scale), Float(page.rawValue), Float(Double(pixelSize.width) / scale), Float(Double(pixelSize.height) / scale)
        )]
        encoder.label = "GlassWeaveLab bench background \(frameID)"
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&parameters, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        let frame = BackgroundFrame(
            texture: pooled.texture,
            frameID: frameID,
            timestamp: clock.now - start,
            colorConvention: .sRGBOpaque,
            readiness: .encoded(in: commandBuffer)
        )
        return pool.lease(frame, using: pooled) { _ in }
    }

    /// Gives free textures back to Metal while the bench is not visible.
    func trim() {
        pool.trim()
    }
}

/// The material bench, the light-fields demo (GW-21), and the lens page
/// (GW-22).
///
/// - **Lens** (`-lab.lens YES`, or the lab's "Thick lens" button): the thick
///   lens of `GlassLens` on a wide pill with an inlaid dome button, a dome
///   marble, a ring, and a fold pair, over a bench page
///   (`-lab.lensBackdrop <page>`, default the orbs, whose colored edges show
///   the dispersion; the dot grid shows the magnification and the bending).
///
/// - **Bench** (`-lab.bench <page>`): one bench page full screen with a few
///   plain glass panels over it, and a control to switch pages, so a look is
///   shown over a known backdrop.
/// - **Light fields** (`-lab.lightFields YES`, or the lab's "Light fields"
///   button): the inner light of `GlassLight` on four panels: a wide pill
///   with colored light pooled along its bottom edge (orange, pink, magenta,
///   violet, cyan, flowing slowly, the middle clear), an arc light, an orb,
///   and a four-corner field, over a chosen backdrop
///   (`-lab.lightBackdrop <page>`, default charcoal). `-lab.lightTime
///   <seconds>` shows one still moment.
///
/// All glass is one `GlassSurfaceView`; its background frame is produced only
/// when the page or the size changes. The light flows by the surface's own
/// effect clock (``GlassParameters/isAnimated`` includes the light), which
/// runs only while something moves: not under Reduce Motion (the surface's
/// policy stills the light), not when hidden. A still `-lab.lightTime`
/// pauses the clock (``GlassSurfaceView/isEffectClockPaused``) and sets each
/// light's ``GlassLight/timeOffset``.
final class MaterialBenchViewController: UIViewController {
    enum Mode {
        case bench
        case lightFields
        case lens
        case chrome
        case paper
        /// Native `UIGlassEffect` beside GlassWeave's glass on one backdrop
        /// (REFINE): `-lab.compare YES`, `-lab.compareBackdrop <page>`.
        case compare
        /// Frosted glass over the prism page (GW-24b): `-lab.frostBench YES`.
        case frost
    }

    /// One demo panel: where it goes (in a layout the controller computes),
    /// its parameters, and a caption.
    private struct Demo {
        var caption: String
        var parameters: GlassParameters
        var frame = CGRect.zero
        /// The frost page's label panel: its text rectangle gets the scrim.
        var hasLabel = false
    }

    private struct Rendering {
        let surface: GlassSurfaceView
        let background: BenchBackground
    }

    let mode: Mode
    private(set) var page: BenchPage
    private var rendering: Result<Rendering, any Error>?
    private var producedKey: String?
    private var demos: [Demo]
    private let titleLabel = UILabel()
    private let closeButton = UIButton(configuration: .glass())
    private let pageControl: UISegmentedControl
    private let pages: [BenchPage]
    private var captionLabels: [UILabel] = []
    /// The comparison's native glass views and its two column headers.
    private var nativeViews: [UIVisualEffectView] = []
    private var columnLabels: [UILabel] = []
    private let timeLabel = UILabel()
    private let diagnosticsLabel = UILabel()
    /// The frost page's label on the card, the switch that turns its scrim
    /// on and off, and the counters it reports (GW-24b).
    private let headlineLabel = UILabel()
    private let sublineLabel = UILabel()
    private let scrimSwitch = UISwitch()
    private let scrimCaption = UILabel()
    private var scrimRect = CGRect.zero
    private let frostMetrics = RenderMetrics()
    /// `-lab.frostNative YES` swaps the frost page's three panels for Apple's
    /// `UIGlassEffect` in the same frames, so a capture of each shows ours and
    /// the native glass over the same backdrop.
    private let frostNative = UserDefaults.standard.bool(forKey: "lab.frostNative")
    private var frostNativeViews: [UIVisualEffectView] = []
    /// The moment `-lab.lightTime` freezes the light at, or `nil` to flow.
    private let stillTime: Double?

    init(mode: Mode, page: BenchPage) {
        self.mode = mode
        self.page = page
        switch mode {
        case .bench: pages = BenchPage.allCases.filter { $0 != .chrome && $0 != .paperDesk && $0 != .prism && $0 != .stage }
        case .lightFields: pages = [.charcoal, .ribbons, .paper]
        case .lens: pages = [.orbs, .dotGrid, .checkerboard, .ribbons]
        case .chrome: pages = [.chrome]
        case .paper: pages = [.paperDesk]
        case .compare: pages = [.charcoal, .orbs, .paper]
        case .frost: pages = [.prism]
        }
        pageControl = UISegmentedControl(items: pages.map(\.title))
        stillTime = UserDefaults.standard.object(forKey: "lab.lightTime") == nil
            ? nil : UserDefaults.standard.double(forKey: "lab.lightTime")
        switch mode {
        case .bench: demos = Self.benchDemos
        case .lightFields: demos = Self.lightDemos(timeOffset: 0)
        case .lens: demos = Self.lensDemos.map(Self.enhanced)
        case .chrome: demos = Self.chromeDemos.map(Self.enhanced)
        case .paper: demos = Self.paperDemos
        case .compare: demos = Self.compareDemos(dark: page.isDark)
        case .frost: demos = Self.frostDemos.map(Self.enhanced)
        }
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// ENHANCE: the demo with the enhanced look (`RefinedLook.enhance`).
    private static func enhanced(_ demo: Demo) -> Demo {
        var demo = demo
        demo.parameters = RefinedLook.enhance(demo.parameters)
        return demo
    }

    // MARK: Demos

    private static let benchDemos: [Demo] = [
        Demo(caption: "Default", parameters: GlassParameters()),
        Demo(caption: "Strong rim", parameters: GlassParameters(cornerRadius: 36, bezelWidth: 30, refraction: 1, edgeHighlight: 0.8)),
        Demo(caption: "Circle", parameters: GlassParameters(cornerRadius: 999, bezelWidth: 22, refraction: 0.9)),
        Demo(caption: "Tinted", parameters: GlassParameters(
            cornerRadius: 30, bezelWidth: 18, refraction: 0.7,
            tint: GlassTint(red: 0.3, green: 0.4, blue: 0.9, strength: 0.25)
        )),
    ]

    // MARK: Lens demos (GW-22, refined)

    /// The quiet pooled light of the lens page and the chrome page: warm to cool
    /// along the bottom edge at modest strength, so the middle stays clear.
    private static func pooledLight() -> GlassLight {
        GlassLight(
            emitters: [GlassLight.Emitter(
                placement: .band(angle: 180, reach: 0.8),
                colors: [stop(1.0, 0.62, 0.30), stop(0.96, 0.46, 0.72), stop(0.62, 0.50, 0.96), stop(0.34, 0.80, 1.0)],
                intensity: 0.55
            )],
            piping: 0.35
        )
    }

    /// The lens page's panels: a thick pill, a dome marble, a round lens, and a
    /// fold pair. Magnification and bending live at the edge; the middle of
    /// the pill and the round lens stays quiet.
    private static let lensDemos: [Demo] = [
        Demo(caption: String(localized: "Thick lens pill with an inlaid dome button and quiet pooled light"), parameters: {
            var pill = RefinedLook.lens(bezel: 40, thickness: 34, dark: true)
            pill.light = pooledLight()
            pill.lens.dispersionTaps = .sixTap
            pill.lens.dispersion = 0.45
            pill.lens.inlays = [GlassLens.Inlay(radius: 40, height: 14, profile: .dome, rimLine: 0.25)]
            return pill
        }()),
        Demo(caption: String(localized: "Dome, three-tap"), parameters: {
            var dome = RefinedLook.panel(corner: 999, bezel: 60, dark: true)
            dome.lens = GlassLens(profile: .dome, thickness: 44, indexOfRefraction: 1.5, maximumOffset: 80, dispersion: 0.3, dispersionTaps: .threeTap)
            return dome
        }()),
        Demo(caption: String(localized: "Round lens, six-tap"), parameters: {
            var round = RefinedLook.lens(bezel: 28, thickness: 28, dark: true)
            round.lens.dispersion = 0.5
            round.lens.dispersionTaps = .sixTap
            return round
        }()),
        Demo(caption: String(localized: "Fold off: magnified, never mirrored"), parameters: {
            var lens = RefinedLook.lens(corner: 28, bezel: 32, thickness: 44, dark: true)
            lens.lens.indexOfRefraction = 1.7
            lens.lens.maximumOffset = 100
            lens.lens.allowsFold = false
            return lens
        }()),
        Demo(caption: String(localized: "Fold on: the edge mirrors"), parameters: {
            var lens = RefinedLook.lens(corner: 28, bezel: 32, thickness: 44, dark: true)
            lens.lens.indexOfRefraction = 1.7
            lens.lens.maximumOffset = 100
            lens.lens.allowsFold = true
            return lens
        }()),
    ]

    // MARK: Frost demos (GW-24b)

    /// The frost page's panels: a frosted capsule over a rainbow arc (a calm
    /// blur with grain, dispersion at the bevel only and a thin Fresnel rim), the
    /// thick lens pill with a lightly frosted body that follows the glass
    /// thickness (clear at the edge) and pooled light, and a card with a large
    /// white label whose contrast the scrim guarantees.
    private static let frostDemos: [Demo] = [
        Demo(caption: String(localized: "Frosted capsule: calm blur and grain, a clear bevel with dispersion, thin rim"), parameters: {
            var capsule = RefinedLook.panel(corner: 999, bezel: 30, dark: true)
            capsule.refraction = 1
            capsule.tint = GlassTint(red: 0.85, green: 0.88, blue: 1, strength: 0.05)
            capsule.lens = GlassLens(profile: .rim, dispersion: 1, dispersionTaps: .sixTap)
            capsule.lighting.fresnel = 0.9
            capsule.frost = GlassFrost(profile: .clearRim, sigma: 7, transition: 24, grain: 0.35, saturation: 1.15, brightness: 1.03)
            return capsule
        }()),
        Demo(caption: String(localized: "Lens pill: a lightly frosted body that follows the glass thickness, a clear edge, pooled light"), parameters: {
            var pill = RefinedLook.lens(bezel: 40, thickness: 34, dark: true)
            pill.light = pooledLight()
            pill.lens.dispersionTaps = .sixTap
            pill.lens.dispersion = 0.45
            pill.lens.inlays = [GlassLens.Inlay(radius: 40, height: 14, profile: .dome, rimLine: 0.25)]
            pill.tint = GlassTint(red: 0.8, green: 0.85, blue: 1, strength: 0.03)
            pill.frost = GlassFrost(profile: .uniform, sigma: 4.5, grain: 0.2, thickness: 1, saturation: 1.2, brightness: 1.05)
            return pill
        }()),
        Demo(caption: String(localized: "White label on frosted glass: the scrim keeps 4.5 to 1"), parameters: {
            var card = RefinedLook.panel(corner: 34, bezel: 20, dark: true)
            card.tint = GlassTint(red: 0.8, green: 0.85, blue: 1, strength: 0.04)
            card.frost = GlassFrost(profile: .uniform, sigma: 7, grain: 0.25, saturation: 1.1)
            return card
        }(), hasLabel: true),
    ]

    // MARK: Compare demos (REFINE)

    /// The shapes of the comparison, one pair per row: Apple's `UIGlassEffect`
    /// on the left, GlassWeave's glass on the right, the same frame.
    private enum CompareRow: Int, CaseIterable {
        case capsule, circle, card, clearCapsule
    }

    private static func compareDemos(dark: Bool) -> [Demo] {
        [
            Demo(caption: String(localized: "Capsule: Apple regular, GlassWeave refined"), parameters: RefinedLook.panel(corner: 999, bezel: 18, dark: dark)),
            Demo(caption: String(localized: "Circle"), parameters: RefinedLook.panel(corner: 999, bezel: 16, dark: dark)),
            Demo(caption: String(localized: "Rounded rectangle"), parameters: RefinedLook.panel(corner: 28, bezel: 18, dark: dark)),
            Demo(caption: String(localized: "Apple clear, GlassWeave thick lens"), parameters: {
                var lens = RefinedLook.lens(dark: dark)
                lens.lens.inlays = [GlassLens.Inlay(radius: 22, height: 8, profile: .dome, rimLine: 0.25)]
                return lens
            }()),
        ]
    }

    // MARK: Chrome demos (GW-23, refined)

    private static func color(_ red: Double, _ green: Double, _ blue: Double) -> GlassLighting.Color {
        GlassLighting.Color(red: red, green: green, blue: blue)
    }

    /// The chrome page's panels: a round button with a polished glass edge on a
    /// light plate, a thick lens pill over the orbs, and a smoky dome over
    /// glowing liquid. One light, from the upper left, for all of them.
    private static let chromeDemos: [Demo] = [
        Demo(caption: String(localized: "Round button: polished chrome ring with small glints"), parameters: RefinedLook.chromeRing(diameter: 84)),
        Demo(caption: String(localized: "Lens pill: thick edge, quiet pooled light, one soft highlight"), parameters: {
            var pill = RefinedLook.lens(bezel: 40, thickness: 34, dark: true)
            pill.light = pooledLight()
            pill.lens.dispersionTaps = .sixTap
            pill.lens.dispersion = 0.45
            pill.lens.inlays = [GlassLens.Inlay(radius: 40, height: 14, profile: .dome, rimLine: 0.25)]
            return pill
        }()),
        Demo(caption: String(localized: "Smoky dome: a calm gel behind clear glass"), parameters: {
            var dome = RefinedLook.panel(corner: 999, bezel: 75, dark: true)
            dome.tint = GlassTint(red: 0.03, green: 0.03, blue: 0.045, strength: 0.4)
            dome.lens = GlassLens(profile: .dome, thickness: 50, indexOfRefraction: 1.5, maximumOffset: 80, dispersion: 0.2, dispersionTaps: .threeTap)
            dome.lighting.bloom = 0.1
            dome.lighting.bloomWidth = 3
            return dome
        }()),
    ]

    // MARK: Paper demos (GW-25, refined)

    private static func ink(_ red: Double, _ green: Double, _ blue: Double) -> GlassGrounding.Color {
        GlassGrounding.Color(red: red, green: green, blue: blue)
    }

    /// The paper desk's panels: a round button and a lens pill about 8 points
    /// apart, and a glass marble below, each with a soft shadow and a faint
    /// warm caustic, lit from the upper left.
    private static let paperDemos: [Demo] = [
        Demo(caption: String(localized: "Round button"), parameters: {
            var button = RefinedLook.panel(corner: 999, bezel: 15, dark: false)
            button.refraction = 0.35
            button.lighting = RefinedLook.lighting(dark: false, finish: .prismatic(spread: 1, saturation: 0.3, phase: 0.02))
            button.lighting.reflection = 0.9
            button.lighting.fresnel = 0.8
            button.grounding = paperGrounding(offset: 8, blur: 18, opacity: 0.2, caustic: 0.1)
            return button
        }()),
        Demo(caption: String(localized: "Lens pill, 8 points from the button"), parameters: {
            var pill = RefinedLook.lens(bezel: 34, thickness: 26, dark: false)
            pill.lens.inlays = [GlassLens.Inlay(radius: 24, height: 10, profile: .dome, rimLine: 0.25)]
            pill.grounding = paperGrounding(offset: 8, blur: 18, opacity: 0.2, caustic: 0.12)
            return pill
        }()),
        Demo(caption: String(localized: "Glass marble: refracted grid, soft shadow, faint warm caustic"), parameters: {
            var marble = RefinedLook.panel(corner: 999, bezel: 70, dark: false)
            marble.tint = .none
            marble.lens = GlassLens(profile: .dome, thickness: 46, indexOfRefraction: 1.5, maximumOffset: 80, dispersion: 0.25, dispersionTaps: .threeTap)
            marble.lighting.fresnel = 0.8
            marble.lighting.specular = 0.7
            marble.grounding = paperGrounding(offset: 14, blur: 28, opacity: 0.22, caustic: 0.16)
            return marble
        }()),
    ]

    private static func paperGrounding(offset: Double, blur: Double, opacity: Double, caustic: Double) -> GlassGrounding {
        let shadow = ink(0.16, 0.17, 0.24)
        return GlassGrounding(
            drop: .init(offset: offset, blur: blur, spread: -3, opacity: opacity, color: shadow),
            contact: .init(width: 1, opacity: 0.06, color: shadow),
            caustic: caustic > 0
                ? .init(offset: offset * 0.8, radius: offset, intensity: caustic, color: ink(1, 0.93, 0.82), dispersion: 0.3, spectrum: 0.5)
                : .off,
            lightAzimuth: RefinedLook.azimuth
        )
    }

    private static func stop(_ red: Double, _ green: Double, _ blue: Double) -> GlassLight.Stop {
        GlassLight.Stop(red: red, green: green, blue: blue)
    }

    /// The four light demos. Light is a quiet pooled tint at the edge with a
    /// believable falloff; every light keeps the middle clear except the orb,
    /// which is the point of an orb.
    private static func lightDemos(timeOffset: Double) -> [Demo] {
        let orange = stop(1.0, 0.62, 0.30), pink = stop(0.96, 0.46, 0.72)
        let violet = stop(0.62, 0.50, 0.96), cyan = stop(0.34, 0.80, 1.0)
        let pill = GlassLight(
            emitters: [GlassLight.Emitter(
                placement: .band(angle: 180, reach: 0.9), colors: [orange, pink, violet, cyan],
                intensity: 0.6, flow: 2, drift: 0.25
            )],
            piping: 0.4, timeOffset: timeOffset
        )
        let arc = GlassLight(
            emitters: [GlassLight.Emitter(
                placement: .arc(angle: 225, span: 150, reach: 0.5), colors: [stop(1, 0.80, 0.42), pink, violet],
                intensity: 0.6, flow: 1, drift: 0.4
            )],
            piping: 0.5, pipingWidth: 6, timeOffset: timeOffset
        )
        let orb = GlassLight(
            emitters: [GlassLight.Emitter(
                placement: .point(x: 0, y: 0.12, radius: 0.7, stretch: 1), colors: [stop(1, 0.95, 0.84), orange, stop(0.85, 0.30, 0.55)],
                intensity: 0.7, flow: 1, drift: 0.45
            )],
            centerFade: 0.45, piping: 0.35, timeOffset: timeOffset
        )
        let field = GlassLight(
            emitters: [GlassLight.Emitter(
                placement: .field(warp: 0.5), colors: [orange, pink, cyan, violet],
                intensity: 0.42, flow: 1
            )],
            piping: 0.35, timeOffset: timeOffset
        )
        let base = { (corner: Double, bezel: Double, light: GlassLight) -> GlassParameters in
            var parameters = RefinedLook.panel(corner: corner, bezel: bezel, dark: true)
            parameters.light = light
            return parameters
        }
        return [
            Demo(caption: String(localized: "Band: light pooled along the bottom edge"), parameters: base(999, 18, pill)),
            Demo(caption: String(localized: "Arc"), parameters: base(40, 18, arc)),
            Demo(caption: String(localized: "Orb"), parameters: base(999, 22, orb)),
            Demo(caption: String(localized: "Field: four corners, warped"), parameters: base(34, 18, field)),
        ]
    }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        if UserDefaults.standard.bool(forKey: "lab.increaseContrast") {
            traitOverrides.accessibilityContrast = .high
        }
        setUpRendering()
        setUpContent()
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        applyPage()
        if mode == .frost {
            // The counters settle after the first frames.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.updateDiagnostics() }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutDemos()
    }

    // MARK: Rendering

    private func setUpRendering() {
        do {
            guard let device = MTLCreateSystemDefaultDevice() else { throw BenchBackground.Failure.shaderUnavailable("no Metal device") }
            guard let queue = device.makeCommandQueue() else { throw BenchBackground.Failure.shaderUnavailable("no command queue") }
            queue.label = "GlassWeaveLab bench"
            let surface = GlassSurfaceView(renderer: try GlassRenderer(commandQueue: queue))
            surface.accessibilityIdentifier = "bench.surface"
            surface.translatesAutoresizingMaskIntoConstraints = false
            if let override = LabViewController.accessibilitySettingsOverride {
                surface.accessibilitySettingsSource = .fixed(override)
            }
            view.addSubview(surface)
            NSLayoutConstraint.activate([
                surface.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                surface.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                surface.topAnchor.constraint(equalTo: view.topAnchor),
                surface.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
            let background = try BenchBackground(device: device)
            rendering = .success(Rendering(surface: surface, background: background))
            if mode == .frost { surface.renderer.metrics = frostMetrics }
            surface.visibilityHandler = { [weak self] visible in
                if !visible { self?.currentBackground?.trim() }
            }
            surface.accessibilitySettingsHandler = { [weak self] _ in
                self?.updateDiagnostics()
            }
            // A still `-lab.lightTime` holds the surface's effect clock; the
            // light's `timeOffset` then names the moment shown.
            surface.isEffectClockPaused = stillTime != nil
            surface.setFrameProducer { [weak self] commandBuffer, pixelSize in
                self?.produceBackground(into: commandBuffer, pixelSize: pixelSize)
            }
        } catch {
            rendering = .failure(error)
        }
    }

    private var currentBackground: BenchBackground? {
        if case let .success(rendering) = rendering { return rendering.background }
        return nil
    }

    private var surface: GlassSurfaceView? {
        if case let .success(rendering) = rendering { return rendering.surface }
        return nil
    }

    /// The background for the next draw, or `nil` when the frame on screen
    /// already shows it.
    private func produceBackground(into commandBuffer: any MTLCommandBuffer, pixelSize: (width: Int, height: Int)) -> BackgroundFrameLease? {
        guard case let .success(rendering) = rendering else { return nil }
        let key = "\(page.rawValue) \(pixelSize.width)x\(pixelSize.height)"
        if key == producedKey, rendering.surface.renderer.currentFrame != nil { return nil }
        let scale = Double(traitCollection.displayScale)
        guard let lease = rendering.background.encodeFrame(into: commandBuffer, page: page, pixelSize: pixelSize, scale: scale) else {
            return nil
        }
        producedKey = key
        return lease
    }

    // MARK: Content

    private func setUpContent() {
        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 0
        switch mode {
        case .bench: titleLabel.text = String(localized: "Material bench")
        case .lightFields: titleLabel.text = String(localized: "Light fields")
        case .lens: titleLabel.text = String(localized: "Thick lens")
        case .chrome: titleLabel.text = String(localized: "Chrome and light")
        case .paper: titleLabel.text = String(localized: "Paper desk")
        case .compare: titleLabel.text = String(localized: "Apple vs GlassWeave")
        case .frost: titleLabel.text = String(localized: "Frosted glass")
        }
        titleLabel.accessibilityTraits.insert(.header)
        closeButton.configuration?.title = String(localized: "Close")
        closeButton.accessibilityIdentifier = "bench.close"
        closeButton.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .primaryActionTriggered)
        pageControl.selectedSegmentIndex = pages.firstIndex(of: page) ?? 0
        pageControl.accessibilityIdentifier = "bench.pages"
        pageControl.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            page = pages[pageControl.selectedSegmentIndex]
            applyPage()
            // The light's composite and the tint depend on the page.
            applyPanels()
        }, for: .valueChanged)
        if mode == .compare {
            // Apple's glass sits above the surface, so it samples the same
            // backdrop the GlassWeave panels are drawn over.
            for row in CompareRow.allCases {
                let effect = UIGlassEffect(style: row == .clearCapsule ? .clear : .regular)
                let native = UIVisualEffectView(effect: effect)
                native.cornerConfiguration = row == .card ? .corners(radius: .fixed(28)) : .capsule()
                native.isUserInteractionEnabled = false
                native.tag = row.rawValue
                native.isAccessibilityElement = false
                view.addSubview(native)
                nativeViews.append(native)
            }
            for title in [String(localized: "Apple, UIGlassEffect"), String(localized: "GlassWeave, refined")] {
                let label = UILabel()
                label.font = .preferredFont(forTextStyle: .footnote).withSize(13)
                label.text = title
                label.textAlignment = .center
                view.addSubview(label)
                columnLabels.append(label)
            }
        }
        for label in [titleLabel, timeLabel, diagnosticsLabel] {
            label.translatesAutoresizingMaskIntoConstraints = true
            view.addSubview(label)
        }
        for demo in demos {
            let label = UILabel()
            label.font = .preferredFont(forTextStyle: .footnote)
            label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 2
            label.text = demo.caption
            view.addSubview(label)
            captionLabels.append(label)
        }
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 34, weight: .semibold)
        timeLabel.textAlignment = .center
        timeLabel.text = "00:01"
        timeLabel.isHidden = mode != .lightFields
        timeLabel.isAccessibilityElement = false
        diagnosticsLabel.font = .preferredFont(forTextStyle: .caption2)
        diagnosticsLabel.numberOfLines = 0
        diagnosticsLabel.accessibilityIdentifier = "bench.diagnostics"
        view.addSubview(pageControl)
        view.addSubview(closeButton)
        if mode == .frost {
            pageControl.isHidden = true
            headlineLabel.text = String(localized: "Frosted glass")
            headlineLabel.font = .systemFont(ofSize: 36, weight: .semibold)
            headlineLabel.textColor = .white
            headlineLabel.adjustsFontSizeToFitWidth = true
            sublineLabel.text = String(localized: "Legible over any color behind it")
            sublineLabel.font = .systemFont(ofSize: 17, weight: .regular)
            sublineLabel.textColor = .white
            sublineLabel.adjustsFontSizeToFitWidth = true
            scrimCaption.text = String(localized: "Scrim 4.5 to 1")
            scrimCaption.font = .preferredFont(forTextStyle: .footnote)
            scrimCaption.textColor = .white
            scrimCaption.isAccessibilityElement = false
            // `-lab.frostNoText YES` hides the label, so a capture shows (and a
            // pixel measurement reads) the glass the scrim shapes.
            headlineLabel.isHidden = UserDefaults.standard.bool(forKey: "lab.frostNoText")
            sublineLabel.isHidden = headlineLabel.isHidden
            scrimSwitch.isOn = !UserDefaults.standard.bool(forKey: "lab.scrimOff")
            scrimSwitch.accessibilityIdentifier = "bench.scrim"
            scrimSwitch.accessibilityLabel = String(localized: "Legibility scrim")
            scrimSwitch.addAction(UIAction { [weak self] _ in self?.applyPanels() }, for: .valueChanged)
            if frostNative {
                for index in demos.indices {
                    let native = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
                    native.cornerConfiguration = index == 2 ? .corners(radius: .fixed(34)) : .capsule()
                    native.overrideUserInterfaceStyle = .dark
                    native.isUserInteractionEnabled = false
                    native.isAccessibilityElement = false
                    view.addSubview(native)
                    frostNativeViews.append(native)
                }
            }
            for item in [headlineLabel, sublineLabel, scrimCaption, scrimSwitch] as [UIView] { view.addSubview(item) }
        }
        if mode == .chrome || mode == .paper {
            pageControl.isHidden = true
            diagnosticsLabel.isHidden = true
            // Drag anywhere to move the light: across turns the azimuth, up
            // and down the elevation.
            let pan = UIPanGestureRecognizer(target: self, action: #selector(movedLight(_:)))
            view.addGestureRecognizer(pan)
            let defaults = UserDefaults.standard
            lightAzimuth = defaults.double(forKey: "lab.lightAzimuth")
            lightElevation = defaults.double(forKey: "lab.lightElevation")
        }
    }

    private var lightAzimuth = 0.0
    private var lightElevation = 0.0
    private var panStart = (azimuth: 0.0, elevation: 0.0)

    /// The light offset (GW-23) follows a drag: `GlassRenderer.setLightOffset`.
    @objc private func movedLight(_ gesture: UIPanGestureRecognizer) {
        if gesture.state == .began { panStart = (lightAzimuth, lightElevation) }
        let translation = gesture.translation(in: view)
        lightAzimuth = panStart.azimuth + Double(translation.x) * 0.6
        lightElevation = min(max(panStart.elevation - Double(translation.y) * 0.25, -50), 40)
        applyLightOffset()
    }

    private func applyLightOffset() {
        guard let surface else { return }
        try? surface.renderer.setLightOffset(azimuth: lightAzimuth, elevation: lightElevation)
        surface.requestFrame()
    }

    /// Text and controls to match the page: white on the dark pages.
    private func applyPage() {
        let color: UIColor = page.isDark ? .white : .black
        for label in [titleLabel, timeLabel] + captionLabels + columnLabels {
            label.textColor = color
        }
        diagnosticsLabel.textColor = page.isDark ? UIColor(white: 1, alpha: 0.7) : UIColor(white: 0, alpha: 0.6)
        pageControl.selectedSegmentIndex = pages.firstIndex(of: page) ?? 0
        // A faint scrim behind the text, so it reads over the dots and cells.
        let scrim = page.isDark ? UIColor(white: 0, alpha: 0.55) : UIColor(white: 1, alpha: 0.55)
        for label in [titleLabel, diagnosticsLabel] + captionLabels + columnLabels {
            label.backgroundColor = scrim
            label.layer.cornerRadius = 6
            label.layer.masksToBounds = true
            label.textAlignment = .center
        }
        pageControl.backgroundColor = scrim
        // The native controls read on the page: light on dark pages.
        let style: UIUserInterfaceStyle = page.isDark ? .dark : .light
        for native in nativeViews { native.overrideUserInterfaceStyle = style }
        pageControl.overrideUserInterfaceStyle = style
        closeButton.overrideUserInterfaceStyle = style
        surface?.requestFrame()
        updateDiagnostics()
    }

    /// Places the demo panels and labels, and gives the surface its panels.
    private func layoutDemos() {
        let safe = view.safeAreaLayoutGuide.layoutFrame
        let margin: CGFloat = 20
        let width = min(safe.width - 2 * margin, 560)
        let left = safe.midX - width / 2
        titleLabel.frame = CGRect(x: left, y: safe.minY + 8, width: width - 96, height: 40)
        closeButton.frame = CGRect(x: left + width - 88, y: safe.minY + 8, width: 88, height: 44)
        pageControl.frame = CGRect(x: left, y: safe.minY + 60, width: width, height: 34)
        var y = safe.minY + 112
        let gap: CGFloat = 12
        let captionHeight: CGFloat = 20
        var frames: [CGRect] = []
        if mode == .lightFields {
            // The pill, an arc and an orb side by side, and the field.
            let pillHeight: CGFloat = 88
            frames.append(CGRect(x: left, y: y, width: width, height: pillHeight))
            timeLabel.frame = frames[0]
            y += pillHeight + captionHeight + gap + 10
            let side = (width - gap) / 2
            frames.append(CGRect(x: left, y: y, width: side, height: side))
            frames.append(CGRect(x: left + side + gap, y: y, width: side, height: side))
            y += side + captionHeight + gap + 10
            frames.append(CGRect(x: left, y: y, width: width, height: min(160, max(safe.maxY - y - 70, 110))))
        } else if mode == .chrome {
            // The ring button on the plate, the lens pill over the orbs, and
            // the dome over the liquid, each in its band of the backdrop.
            let bounds = view.bounds
            let inset = bounds.width * 0.04
            let topEnd = bounds.height * 0.33, middleEnd = bounds.height * 0.66
            frames.append(CGRect(x: inset + 14, y: 130, width: 84, height: 84))
            let pillHeight: CGFloat = 104
            frames.append(CGRect(x: left, y: topEnd + (middleEnd - topEnd - pillHeight - 34) / 2, width: width, height: pillHeight))
            let dome: CGFloat = 150
            frames.append(CGRect(x: bounds.midX - dome / 2, y: (middleEnd + bounds.height) / 2 - dome / 2 - 14, width: dome, height: dome))
        } else if mode == .paper {
            // The ring button and the pill on one row, 8 points apart, and
            // the marble below.
            let bounds = view.bounds
            let row = min(bounds.width - 2 * margin, 560)
            let rowLeft = bounds.midX - row / 2
            let button: CGFloat = 76
            let rowTop = safe.minY + 110
            frames.append(CGRect(x: rowLeft, y: rowTop, width: button, height: button))
            frames.append(CGRect(x: rowLeft + button + 8, y: rowTop, width: row - button - 8, height: button))
            let marble = min(row * 0.55, 210)
            frames.append(CGRect(x: bounds.midX - marble / 2, y: rowTop + button + 80, width: marble, height: marble))
        } else if mode == .frost {
            // Each panel sits on its part of the prism page, by the page's
            // own formulas: the capsule over the upper arc's crown, the pill
            // between the arcs, the card over the lower arc's crown.
            let bounds = view.bounds
            let unit = min(bounds.width, 560)
            let capsuleWidth = min(width, 340)
            let capsuleCenter = bounds.height * 0.40 - unit * 0.42
            frames.append(CGRect(x: bounds.midX - capsuleWidth / 2, y: capsuleCenter - 46, width: capsuleWidth, height: 92))
            let pillHeight: CGFloat = 104
            frames.append(CGRect(x: left, y: bounds.height * 0.50 - pillHeight / 2, width: width, height: pillHeight))
            let cardCenter = bounds.height * 0.92 - unit * 0.38
            frames.append(CGRect(x: left, y: cardCenter - 72, width: width, height: 144))
        } else if mode == .compare {
            // Two columns of the same four frames: Apple's glass on the left,
            // GlassWeave's on the right. One caption under each pair.
            let gutter: CGFloat = 16
            let column = (width - gutter) / 2
            let rowHeights: [CGFloat] = [56, 92, 104, 64]
            var theirs: [CGRect] = []
            columnLabels[0].frame = CGRect(x: left, y: y - 2, width: column, height: 22)
            columnLabels[1].frame = CGRect(x: left + column + gutter, y: y - 2, width: column, height: 22)
            y += 28
            for (index, height) in rowHeights.enumerated() {
                let frame = height == 92
                    ? CGRect(x: 0, y: y, width: 92, height: 92) : CGRect(x: 0, y: y, width: column, height: height)
                let inset = (column - frame.width) / 2
                theirs.append(frame.offsetBy(dx: left + inset, dy: 0))
                frames.append(frame.offsetBy(dx: left + column + gutter + inset, dy: 0))
                y += height + captionHeight + gap + 8
                _ = index
            }
            for (native, frame) in zip(nativeViews, theirs) { native.frame = frame }
        } else if mode == .lens {
            // The pill, then a dome and a ring, then the fold pair.
            let pillHeight: CGFloat = 104
            frames.append(CGRect(x: left, y: y, width: width, height: pillHeight))
            y += pillHeight + captionHeight + gap + 10
            let side = min((width - gap) / 2, 130)
            frames.append(CGRect(x: left, y: y, width: side, height: side))
            frames.append(CGRect(x: left + width - side, y: y, width: side, height: side))
            y += side + captionHeight + gap + 10
            let half = (width - gap) / 2
            let foldHeight = min(110, max(safe.maxY - y - 90, 80))
            frames.append(CGRect(x: left, y: y, width: half, height: foldHeight))
            frames.append(CGRect(x: left + half + gap, y: y, width: half, height: foldHeight))
        } else {
            let pillHeight: CGFloat = 84
            frames.append(CGRect(x: left, y: y, width: width, height: pillHeight))
            y += pillHeight + captionHeight + gap + 10
            frames.append(CGRect(x: left, y: y, width: width, height: 96))
            y += 96 + captionHeight + gap + 10
            let side = (width - gap) / 2
            frames.append(CGRect(x: left, y: y, width: min(side, 150), height: min(side, 150)))
            frames.append(CGRect(x: left + side + gap, y: y, width: side, height: min(side, 150)))
        }
        for index in demos.indices {
            demos[index].frame = frames[index]
            // A caption is at least as wide as a small button's neighbours.
            if mode == .compare {
                captionLabels[index].frame = CGRect(x: left, y: frames[index].maxY + 4, width: width, height: captionHeight + 14)
                continue
            }
            let wide = mode == .chrome || mode == .paper
            let captionWidth = wide ? max(frames[index].width, 300) : frames[index].width
            let captionX = wide && frames[index].width < 300 ? frames[index].midX - captionWidth / 2 : frames[index].minX
            captionLabels[index].frame = CGRect(
                x: max(captionX, 8) + 4, y: frames[index].maxY + 4, width: captionWidth - 8, height: captionHeight + 14
            )
        }
        diagnosticsLabel.frame = CGRect(x: left, y: safe.maxY - 36, width: width, height: 32)
        if mode == .frost, let card = demos.last?.frame {
            headlineLabel.frame = CGRect(x: card.minX + 28, y: card.minY + 26, width: card.width - 56, height: 46)
            sublineLabel.frame = CGRect(x: card.minX + 28, y: card.minY + 76, width: card.width - 56, height: 26)
            scrimRect = headlineLabel.frame.union(sublineLabel.frame).insetBy(dx: -6, dy: -4)
            let switchSize = scrimSwitch.intrinsicContentSize
            scrimSwitch.frame = CGRect(x: left + width - switchSize.width, y: safe.maxY - 78, width: switchSize.width, height: switchSize.height)
            scrimCaption.sizeToFit()
            scrimCaption.frame.origin = CGPoint(x: scrimSwitch.frame.minX - scrimCaption.frame.width - 10, y: scrimSwitch.frame.midY - scrimCaption.frame.height / 2)
        }
        // Hug the text, so the scrim is no wider than it.
        for label in [titleLabel, diagnosticsLabel] + captionLabels {
            let fitted = label.sizeThatFits(CGSize(width: label.frame.width, height: .greatestFiniteMagnitude))
            label.frame.size = CGSize(width: min(fitted.width + 14, label.frame.width), height: min(fitted.height + 6, label.frame.height))
        }
        for (native, demo) in zip(frostNativeViews, demos) { native.frame = demo.frame }
        applyPanels()
        applyLightOffset()
        updateDiagnostics()
    }

    /// Gives the surface the demo panels. The light flows by the surface's
    /// own effect clock; only a still `-lab.lightTime` sets the moment, as
    /// each light's `timeOffset`.
    private func applyPanels() {
        let base = stillTime ?? 0
        if mode == .compare {
            let fresh = Self.compareDemos(dark: page.isDark)
            for index in demos.indices { demos[index].parameters = fresh[index].parameters }
        }
        let panels = demos.map { demo -> GlassPanel in
            var parameters = demo.parameters
            parameters.light.timeOffset = base
            // `-lab.frostOff YES` draws the same panels without frost, for
            // comparison.
            if mode == .frost, UserDefaults.standard.bool(forKey: "lab.frostOff") { parameters.frost = .none }
            // The card's scrim guarantees its label 4.5 to 1.
            if demo.hasLabel, scrimSwitch.isOn {
                parameters.frost = parameters.frost.legibility(text: .white, contrast: 4.5, rect: scrimRect, feather: 28)
            }
            // An inlaid dome button sits at the panel's right end.
            for index in parameters.lens.inlays.indices {
                parameters.lens.inlays[index].x = demo.frame.width / 2 - parameters.lens.inlays[index].radius - 10
                parameters.lens.inlays[index].y = 0
            }
            // Screened light does not show on white: paint it on the paper.
            if mode == .lightFields {
                parameters.light.composite = page.isDark ? .light : .paint
                // Smoky glass on the dark and colorful pages, so light shows
                // over any of them.
                parameters.tint = page.isDark ? RefinedLook.tint(dark: true, strength: 0.12) : RefinedLook.tint(dark: false)
                parameters.lighting = RefinedLook.lighting(dark: page.isDark)
                parameters.grounding = RefinedLook.grounding(dark: page.isDark)
            }
            return GlassPanel(frame: demo.frame, parameters: parameters)
        }
        try? surface?.setPanels(frostNative ? [] : panels)
    }

    private func updateDiagnostics() {
        guard let surface else {
            if case let .failure(error) = rendering { diagnosticsLabel.text = String(describing: error) }
            return
        }
        let settings = surface.accessibilitySettings
        var text = "\(page.identifier)"
        if mode == .frost {
            // Under Reduce Transparency the card is the system's opaque
            // surface, so its label uses the system label color.
            let opaque = settings.reduceTransparency
            headlineLabel.textColor = opaque ? .label : .white
            sublineLabel.textColor = opaque ? .label : .white
            let counts = frostMetrics.counts
            text += " | pyramid builds=\(counts.pyramidBuilds) reuses=\(counts.pyramidReuses) | frost memory \(surface.renderer.frostMemoryBytes) bytes"
            text += " | scrim \(scrimSwitch.isOn ? "on" : "off")"
        }
        if mode == .lightFields {
            text += " | light: \(surface.presentedPanels.filter { $0.parameters.light.isVisible }.count)/\(demos.count) drawn"
            text += settings.reduceMotion ? " | still" : (stillTime == nil ? " | flowing" : " | t=\(stillTime ?? 0)s")
        }
        diagnosticsLabel.text = text
    }
}
