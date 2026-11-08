import GlassWeave
import Synchronization

/// Records lease releases from any thread.
final class ReleaseRecorder: Sendable {
    private let recorded = Mutex<[BackgroundFrameRelease]>([])

    var handler: @Sendable (BackgroundFrameRelease) -> Void {
        { [self] release in recorded.withLock { $0.append(release) } }
    }

    var releases: [BackgroundFrameRelease] {
        recorded.withLock { $0 }
    }
}
