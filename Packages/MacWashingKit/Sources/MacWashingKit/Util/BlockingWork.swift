import Foundation

/// Runs blocking work — `fts` walks, directory enumeration, size measurement — on a few dedicated threads instead of
/// the Swift cooperative pool. The pool has one thread per core: synchronous walks running in it stall every other
/// task of the app (helper replies, other sections’ scans) until they finish.
///
/// Three lanes, each `width` threads wide, so a long walk (Large Files) never queues the short measurements of another
/// section behind it, and Storage's walks (`browse`, utility priority) never compete with the interface.
public enum BlockingWork {
    public enum Lane: Sendable {
        /// Long whole-tree walks: the Large Files deep scan, Storage measurements.
        case walk
        /// Sizes of found items, the app inventory, other short file-system work.
        case measure
        /// Folder sizes of the Storage browser: started by clicking around, so they run at utility priority and never
        /// take the cores the interface needs (scrolling, switching sections) while they walk.
        case browse
    }

    /// Threads per lane: two cores stay free for the main thread and the cooperative pool.
    public static let width = max(ProcessInfo.processInfo.activeProcessorCount - 2, 2)

    private static let walkQueue = makeQueue("walk")
    private static let measureQueue = makeQueue("measure")
    private static let browseQueue = makeQueue("browse", qos: .utility)

    private static func makeQueue(_ name: String, qos: QualityOfService = .userInitiated) -> LockedOperationQueue {
        let queue = OperationQueue()
        queue.name = "MacWashing.blocking.\(name)"
        queue.maxConcurrentOperationCount = width
        queue.qualityOfService = qos
        return LockedOperationQueue(queue)
    }

    /// Runs `work` on a thread of `lane` and returns its result. Cancelling the calling task raises the flag `work`
    /// gets: long work checks it now and then and returns early with what it has.
    public static func run<T: Sendable>(
        _ lane: Lane = .measure,
        _ work: @escaping @Sendable (CancellationFlag) -> T
    ) async -> T {
        let flag = CancellationFlag()
        let queue = switch lane {
        case .walk: walkQueue
        case .measure: measureQueue
        case .browse: browseQueue
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.add { continuation.resume(returning: work(flag)) }
            }
        } onCancel: {
            flag.cancel()
        }
    }
}

/// Set once, read from any thread.
public final class CancellationFlag: Sendable {
    private let state = Locked(false)

    public init() {}

    public func cancel() { state.store(true) }

    public var isCancelled: Bool { state.load() }
}

/// `OperationQueue` is thread-safe; the box only carries it into `Sendable` code.
private final class LockedOperationQueue: @unchecked Sendable {
    private let queue: OperationQueue
    init(_ queue: OperationQueue) { self.queue = queue }
    func add(_ block: @escaping @Sendable () -> Void) { queue.addOperation(block) }
}
