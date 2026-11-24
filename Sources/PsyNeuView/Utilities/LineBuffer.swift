import Foundation

/// Turns a stream of pipe chunks into whole lines (#75).
///
/// A pipe hands over whatever bytes happen to be ready, so one chunk can end
/// in the middle of a line, or in the middle of a character. Passing chunks on
/// as they came made every chunk its own row in the Logs window:
/// ` + wcwidth==0.2.13` arrived as `+`, `wcwidth`, `==0`, `.2.13`.
///
/// The buffer works on bytes and only decodes a line once it is complete.
/// Newline and carriage-return bytes never occur inside a multi-byte UTF-8
/// character, so a complete line always holds complete characters; anything
/// that is still not valid UTF-8 is shown with replacement characters rather
/// than dropped.
///
/// A bare carriage return is a progress update that redraws the line it is
/// on, as a terminal shows it: only what follows the last `\r` is kept, so
/// `10%\r50%\r100%\n` is one line, `100%`. `\r\n` ends a line like `\n` does.
struct LineBuffer {
    private var pending: [UInt8] = []

    private static let newline = UInt8(ascii: "\n")
    private static let carriageReturn = UInt8(ascii: "\r")

    /// The complete lines in `chunk` (without their line endings), with any
    /// unfinished tail kept back for the next chunk.
    mutating func append(_ chunk: Data) -> [String] {
        var lines: [String] = []
        for byte in chunk {
            if byte == Self.newline {
                // "\r\n" ends the line; the "\r" is not a redraw.
                if pending.last == Self.carriageReturn { pending.removeLast() }
                lines.append(Self.decode(pending))
                pending.removeAll(keepingCapacity: true)
                continue
            }
            if pending.last == Self.carriageReturn {
                // "\r\r" is one redraw, so "abc\r\r\n" is still "abc".
                if byte == Self.carriageReturn { continue }
                // A "\r" followed by more of the line: the line is redrawn
                // from its start, so what came before it is gone.
                pending.removeAll(keepingCapacity: true)
            }
            pending.append(byte)
        }
        return lines
    }

    /// Convenience for text that is already decoded.
    mutating func append(_ text: String) -> [String] {
        append(Data(text.utf8))
    }

    /// Whatever is left when the stream ends: a last line with no newline.
    /// Nil when there is nothing left.
    mutating func flush() -> String? {
        defer { pending.removeAll() }
        if pending.last == Self.carriageReturn { pending.removeLast() }
        return pending.isEmpty ? nil : Self.decode(pending)
    }

    private static func decode(_ bytes: [UInt8]) -> String {
        String(decoding: bytes, as: UTF8.self)
    }
}

/// Reads one pipe as whole lines while its process runs (#75).
///
/// Each `readabilityHandler` call adds a chunk to this pipe's own
/// `LineBuffer` and passes on the lines it completed. When the process exits,
/// `finish()` reads anything still waiting in the pipe and passes on the last
/// line even if it had no newline. A lock keeps the handler's chunks and the
/// final read in order, since they run on different threads.
final class PipeLineReader: @unchecked Sendable {
    private let handle: FileHandle
    private let onLine: @Sendable (String) -> Void
    private let lock = NSLock()
    private var buffer = LineBuffer()
    private var finished = false

    /// `onLine` receives each line with a trailing `\n`, so callers that join
    /// what they receive get the same text the process wrote.
    init(_ pipe: Pipe, onLine: @escaping @Sendable (String) -> Void) {
        self.handle = pipe.fileHandleForReading
        self.onLine = onLine
    }

    func start() {
        handle.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            guard !self.finished else { return }
            let data = handle.availableData
            guard !data.isEmpty else { return }
            for line in self.buffer.append(data) { self.onLine(line + "\n") }
        }
    }

    /// Stop reading, take what is left in the pipe, and pass on the last line.
    /// Safe to call more than once.
    func finish() {
        handle.readabilityHandler = nil
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        let rest = Self.readWithoutWaiting(handle)
        for line in buffer.append(rest) { onLine(line + "\n") }
        if let last = buffer.flush() { onLine(last + "\n") }
    }

    /// Whatever the pipe holds right now, without blocking. A process can
    /// leave a child behind that still holds the pipe open, and waiting for
    /// the end of the file would then wait for that child.
    private static func readWithoutWaiting(_ handle: FileHandle) -> Data {
        let fd = handle.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else { return Data() }
        defer { _ = fcntl(fd, F_SETFL, flags) }
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                data.append(contentsOf: chunk[0..<n])
            } else {
                break  // 0: end of file; -1: nothing waiting (EAGAIN) or an error
            }
        }
        return data
    }
}
