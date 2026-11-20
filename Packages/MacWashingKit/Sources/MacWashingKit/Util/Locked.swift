import os

/// A value guarded by an unfair lock, readable and writable from any thread.
///
/// Stands in for `Synchronization.Mutex`/`Atomic`, which need macOS 15: the app runs on macOS 14. A class, so it can be
/// captured by reference (a render callback, a `Sendable` box) without the non-copyable dance `Mutex` needs.
public final class Locked<Value>: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var value: Value

    public init(_ value: Value) {
        self.value = value
    }

    /// Runs `body` with exclusive access to the value. Keep it short: every other reader waits.
    public func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }

    /// A copy of the current value.
    public func load() -> Value {
        withLock { $0 }
    }

    public func store(_ newValue: Value) {
        withLock { $0 = newValue }
    }
}
