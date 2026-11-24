import XCTest
@testable import PsyNeuView

/// Process output reaches the Logs window as whole lines (#75), however the
/// pipe happened to cut it up.
final class LineBufferTests: XCTestCase {

    private func bytes(_ text: String) -> Data { Data(text.utf8) }

    func testChunksSplitMidLineAreJoinedIntoWholeLines() {
        // The fragments from the issue's screenshot.
        var buffer = LineBuffer()
        XCTAssertEqual(buffer.append(bytes(" +")), [])
        XCTAssertEqual(buffer.append(bytes(" wcwidth")), [])
        XCTAssertEqual(buffer.append(bytes("==0")), [])
        XCTAssertEqual(buffer.append(bytes(".2.13\n + webencodings==")), [" + wcwidth==0.2.13"])
        XCTAssertEqual(buffer.append(bytes("0.5.1\n")), [" + webencodings==0.5.1"])
        XCTAssertNil(buffer.flush())
    }

    func testSeveralLinesInOneChunkComeOutSeparately() {
        var buffer = LineBuffer()
        XCTAssertEqual(buffer.append(bytes("one\ntwo\n\nthree\n")), ["one", "two", "", "three"])
    }

    func testAMultiByteCharacterSplitAcrossChunksIsKeptWhole() {
        // "✓" is three bytes, "é" two: cut each between its bytes.
        let line = Data("  ✓ café ready\n".utf8)
        let check = line.firstIndex(of: 0xE2)!
        let cuts = [check + 1, check + 2, line.firstIndex(of: 0xC3)! + 1]
        var buffer = LineBuffer()
        var lines: [String] = []
        var start = line.startIndex
        for cut in cuts + [line.endIndex] {
            lines += buffer.append(line.subdata(in: start..<cut))
            start = cut
        }
        XCTAssertEqual(lines, ["  ✓ café ready"])
    }

    func testCarriageReturnProgressReplacesTheLineRatherThanAddingRows() {
        var buffer = LineBuffer()
        XCTAssertEqual(buffer.append(bytes("Downloading 10%\rDownloading 50%")), [])
        XCTAssertEqual(buffer.append(bytes("\rDownloading 100%\nDone\n")), ["Downloading 100%", "Done"])
    }

    func testCarriageReturnNewlineEndsALineEvenAcrossChunks() {
        var buffer = LineBuffer()
        XCTAssertEqual(buffer.append(bytes("first\r")), [])
        XCTAssertEqual(buffer.append(bytes("\nsecond\r\n")), ["first", "second"])
        XCTAssertEqual(buffer.append(bytes("third\r\r\n")), ["third"])
    }

    func testAFinalLineWithoutANewlineIsFlushedAtExit() {
        var buffer = LineBuffer()
        XCTAssertEqual(buffer.append(bytes("Resolved 214 packages\nInstalled 214 pack")), ["Resolved 214 packages"])
        XCTAssertEqual(buffer.append(bytes("ages in 3.2s")), [])
        XCTAssertEqual(buffer.flush(), "Installed 214 packages in 3.2s")
        XCTAssertNil(buffer.flush(), "a flush empties the buffer")
    }

    func testInvalidUTF8IsShownNotDropped() {
        var buffer = LineBuffer()
        XCTAssertEqual(buffer.append(Data([0x61, 0xFF, 0x62, 0x0A])), ["a\u{FFFD}b"])
    }

    /// The whole path, through a real process: a last line with no newline
    /// still arrives, and arrives before the exit status does.
    func testRunStreamingDeliversWholeLinesIncludingAnUnterminatedLastOne() async {
        let box = LinesBox()
        let status = await Shell.runStreaming(
            "/bin/sh",
            arguments: ["-c", "printf 'one\\ntw'; sleep 0.1; printf 'o\\nthree'"],
            onOutput: { box.add($0) })
        XCTAssertEqual(status, 0)
        XCTAssertEqual(box.lines, ["one\n", "two\n", "three\n"])
    }
}

private final class LinesBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func add(_ line: String) { lock.lock(); stored.append(line); lock.unlock() }
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return stored }
}
