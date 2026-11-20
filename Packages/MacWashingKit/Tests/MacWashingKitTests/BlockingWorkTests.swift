import Darwin
import Foundation
import Testing
@testable import MacWashingKit

/// Blocking walks and child processes stay off the cooperative pool, and both can be stopped. No assertion depends on
/// how fast the (shared, busy) test machine schedules tasks.
@Suite("Blocking work and processes")
struct BlockingWorkTests {
    /// Twice as many blocking jobs as there are cores, each waiting for a signal only an ordinary task can give. Had
    /// they run on the cooperative pool (one thread per core), they would hold every thread and the signal would never
    /// come; on `BlockingWork` the pool stays free and all of them get it.
    @Test func blockingWorkLeavesThePoolFree() async {
        let jobs = 2 * ProcessInfo.processInfo.activeProcessorCount
        let signal = SendableSemaphore()
        let work = Task {
            await withTaskGroup(of: Bool.self) { group in
                for _ in 0..<jobs {
                    group.addTask { await BlockingWork.run(.walk) { _ in signal.wait(seconds: 30) } }
                }
                var all = true
                for await signalled in group { all = all && signalled }
                return all
            }
        }
        await Task.yield()
        for _ in 0..<jobs { signal.signal() }
        #expect(await work.value)
    }

    @Test func cancellingRaisesTheFlag() async {
        let task = Task {
            await BlockingWork.run { flag -> Bool in
                for _ in 0..<3_000 {
                    if flag.isCancelled { return true }
                    usleep(10_000)
                }
                return false
            }
        }
        task.cancel()
        #expect(await task.value)
    }

    /// More than a pipe buffer of output: read as it arrives, the tool never blocks on a full pipe.
    @Test func shellReadsLargeOutput() async {
        let data = await Shell.run("/bin/sh", ["-c", "head -c 300000 /dev/zero"])
        #expect(data?.count == 300_000)
    }

    @Test func shellReportsFailure() async {
        #expect(await Shell.run("/bin/sh", ["-c", "echo nope; exit 3"]) == nil)
        #expect(await Shell.run("/nonexistent/tool", []) == nil)
    }

    /// The timeout terminates the tool (SIGTERM), rather than waiting the full 60 seconds.
    @Test func timeoutTerminatesTheTool() async throws {
        let result = try #require(await ProcessRunner.run("/bin/sleep", ["60"], timeout: 0.3))
        #expect(result.status == SIGTERM)
        #expect(await Shell.run("/bin/sleep", ["60"], timeout: 0.3) == nil)
    }

    /// Cancelled once the tool really runs (it leaves a marker, then becomes `sleep`): on a busy machine a fixed wait
    /// may end before the tool starts, or after a short tool has already finished on its own.
    @Test func cancellingTerminatesTheTool() async throws {
        let marker = FileManager.default.temporaryDirectory.appending(path: "mw-cancel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let task = Task {
            await ProcessRunner.run("/bin/sh", ["-c", "touch \"$0\" && exec /bin/sleep 3600", marker.path], timeout: 7200)
        }
        while !FileManager.default.fileExists(atPath: marker.path) {
            try await Task.sleep(for: .milliseconds(20))
        }
        task.cancel()
        let result = try #require(await task.value)
        #expect(result.status == SIGTERM)
    }

    /// A tool that changes something is left to finish when its caller is cancelled.
    @Test func toolsThatChangeSomethingFinish() async throws {
        let task = Task { await ProcessRunner.run("/bin/sh", ["-c", "sleep 0.3; echo done"], timeout: 30, terminateOnCancel: false) }
        task.cancel()
        let result = try #require(await task.value)
        #expect(result.status == 0)
        #expect(String(decoding: result.output, as: UTF8.self) == "done\n")
    }

    @Test func errorOutputIsCapturedOrMerged() async throws {
        let captured = try #require(await ProcessRunner.run("/bin/sh", ["-c", "echo out; echo err >&2"], timeout: 5, errorOutput: .capture))
        #expect(String(decoding: captured.output, as: UTF8.self) == "out\n")
        #expect(String(decoding: captured.error, as: UTF8.self) == "err\n")
        let merged = try #require(await ProcessRunner.run("/bin/sh", ["-c", "echo out; echo err >&2"], timeout: 5, errorOutput: .merge))
        #expect(String(decoding: merged.output, as: UTF8.self).contains("err"))
    }

    /// A cancelled size walk returns nothing rather than a partial size.
    @Test func cancelledSizesAreLeftOut() async throws {
        let mac = try FakeMac()
        let folder = try mac.folder("big")
        for index in 0..<50 { try mac.file("big/\(index).bin", bytes: 1024) }
        let task = Task { () -> [URL: Int64] in
            withUnsafeCurrentTask { $0?.cancel() }
            return await FileSystem.sizes(of: [folder])
        }
        #expect(await task.value.isEmpty)
        #expect(await FileSystem.size(of: folder) > 0)
    }
}

/// `DispatchSemaphore` is thread-safe; the box only carries it into `Sendable` closures.
private final class SendableSemaphore: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    func signal() { semaphore.signal() }
    func wait(seconds: Double) -> Bool { semaphore.wait(timeout: .now() + seconds) == .success }
}
