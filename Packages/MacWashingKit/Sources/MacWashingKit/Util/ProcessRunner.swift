import Darwin
import Foundation

/// Runs a command-line tool without holding a thread while it runs: output is read as it arrives (so a chatty tool
/// never blocks on a full pipe) and the exit comes through `terminationHandler`. A timeout terminates the process, and
/// so does cancelling the calling task unless `terminateOnCancel` is off (tools that change something are left to
/// finish).
public enum ProcessRunner {
    public enum ErrorOutput: Sendable {
        /// Thrown away.
        case discard
        /// Read into `Result.output` together with standard output.
        case merge
        /// Read into `Result.error`.
        case capture
    }

    public struct Result: Sendable {
        public let status: Int32
        public let output: Data
        public let error: Data
    }

    /// Nil when the tool could not be started (or the task was cancelled before it was).
    public static func run(
        _ tool: String,
        _ arguments: [String],
        timeout: TimeInterval,
        errorOutput: ErrorOutput = .discard,
        terminateOnCancel: Bool = true
    ) async -> Result? {
        let running = RunningProcess(tool: tool, arguments: arguments, timeout: timeout, errorOutput: errorOutput)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                running.start(continuation)
            }
        } onCancel: {
            if terminateOnCancel { running.cancel() }
        }
    }
}

/// One run. Everything happens on its own serial queue: reading, the exit, the timeout, cancellation.
private final class RunningProcess: @unchecked Sendable {
    private let queue = DispatchQueue(label: "MacWashing.process")
    private let process = Process()
    private let tool: String
    private let arguments: [String]
    private let timeout: TimeInterval
    private let errorOutput: ProcessRunner.ErrorOutput

    private var continuation: CheckedContinuation<ProcessRunner.Result?, Never>?
    private var readers: [Reader] = []
    private var output = Data()
    private var error = Data()
    private var cancelled = false
    private var finished = false

    private struct Reader {
        let source: DispatchSourceRead
        let fd: Int32
        let isError: Bool
    }

    init(tool: String, arguments: [String], timeout: TimeInterval, errorOutput: ProcessRunner.ErrorOutput) {
        self.tool = tool
        self.arguments = arguments
        self.timeout = timeout
        self.errorOutput = errorOutput
    }

    func start(_ continuation: CheckedContinuation<ProcessRunner.Result?, Never>) {
        queue.async { [self] in
            self.continuation = continuation
            guard !cancelled else { return finish(nil) }
            process.executableURL = URL(filePath: tool)
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            let out = Pipe()
            process.standardOutput = out
            watch(out, isError: false)
            switch errorOutput {
            case .discard:
                process.standardError = FileHandle.nullDevice
            case .merge:
                process.standardError = out
            case .capture:
                let err = Pipe()
                process.standardError = err
                watch(err, isError: true)
            }
            process.terminationHandler = { [self] _ in queue.async { self.exited() } }
            do {
                try process.run()
            } catch {
                return finish(nil)
            }
            queue.asyncAfter(deadline: .now() + timeout) { [self] in
                if process.isRunning { process.terminate() }
            }
        }
    }

    func cancel() {
        queue.async { [self] in
            cancelled = true
            if process.isRunning { process.terminate() }
        }
    }

    private func watch(_ pipe: Pipe, isError: Bool) {
        let fd = pipe.fileHandleForReading.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self, weak source] in
            guard let self else { return }
            if !self.drain(fd, isError: isError) { source?.cancel() }
        }
        // The pipe (and with it the descriptor) lives until the source is done with it.
        source.setCancelHandler { _ = pipe }
        readers.append(Reader(source: source, fd: fd, isError: isError))
        source.resume()
    }

    /// Reads whatever is in the pipe now. False at end of file or on an error.
    private func drain(_ fd: Int32, isError: Bool) -> Bool {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                if isError { error.append(contentsOf: buffer[0..<count]) } else { output.append(contentsOf: buffer[0..<count]) }
                continue
            }
            if count == 0 { return false }
            if errno == EINTR { continue }
            return errno == EAGAIN
        }
    }

    private func exited() {
        // What the tool wrote just before it quit; a helper it left running may keep the pipe open, so never wait for
        // the end of file.
        for reader in readers where !reader.source.isCancelled {
            _ = drain(reader.fd, isError: reader.isError)
        }
        finish(ProcessRunner.Result(status: process.terminationStatus, output: output, error: error))
    }

    private func finish(_ result: ProcessRunner.Result?) {
        guard !finished else { return }
        finished = true
        process.terminationHandler = nil
        for reader in readers where !reader.source.isCancelled { reader.source.cancel() }
        readers = []
        continuation?.resume(returning: result)
        continuation = nil
    }
}
