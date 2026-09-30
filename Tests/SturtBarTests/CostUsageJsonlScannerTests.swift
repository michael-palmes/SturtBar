import Foundation
import Testing
@testable import SturtBarCore

struct CostUsageJsonlScannerTests {
    @Test
    func `jsonl scanner handles lines across read chunks`() throws {
        let root = try self.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let fileURL = root.appendingPathComponent("large-lines.jsonl", isDirectory: false)
        let largeLine = String(repeating: "x", count: 300_000)
        let contents = "\(largeLine)\nsmall\n"
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)

        var scanned: [(count: Int, truncated: Bool)] = []
        let endOffset = try CostUsageJsonl.scan(
            fileURL: fileURL,
            maxLineBytes: 400_000,
            prefixBytes: 400_000)
        { line in
            scanned.append((line.bytes.count, line.wasTruncated))
        }

        #expect(endOffset == Int64(Data(contents.utf8).count))
        #expect(scanned.count == 2)
        #expect(scanned[0].count == 300_000)
        #expect(scanned[0].truncated == false)
        #expect(scanned[1].count == 5)
        #expect(scanned[1].truncated == false)
    }

    @Test
    func `jsonl scanner retains prefix for truncated lines`() throws {
        let root = try self.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let fileURL = root.appendingPathComponent("truncated-lines.jsonl", isDirectory: false)
        let shortLine = "ok"
        let longLine = String(repeating: "a", count: 2000)
        let contents = "\(shortLine)\n\(longLine)\n"
        try contents.write(to: fileURL, atomically: true, encoding: .utf8)

        var scanned: [CostUsageJsonl.Line] = []
        _ = try CostUsageJsonl.scan(
            fileURL: fileURL,
            maxLineBytes: 10000,
            prefixBytes: 64)
        { line in
            scanned.append(line)
        }

        #expect(scanned.count == 2)
        #expect(String(data: scanned[0].bytes, encoding: .utf8) == "ok")
        #expect(scanned[0].wasTruncated == false)
        #expect(scanned[1].bytes.count == 64)
        #expect(String(data: scanned[1].bytes, encoding: .utf8) == String(repeating: "a", count: 64))
        #expect(scanned[1].wasTruncated == true)
    }

    @Test
    func `jsonl scanner retries an incomplete final record after append`() throws {
        let root = try self.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let fileURL = root.appendingPathComponent("appending.jsonl", isDirectory: false)
        let complete = #"{"id":"done"}"# + "\n"
        let partial = #"{"id":"partial"#
        try (complete + partial).write(to: fileURL, atomically: true, encoding: .utf8)

        var firstPass: [String] = []
        let resumeOffset = try CostUsageJsonl.scan(fileURL: fileURL, maxLineBytes: 1024, prefixBytes: 1024) { line in
            firstPass.append(String(bytes: line.bytes, encoding: .utf8) ?? "")
        }

        #expect(firstPass == [#"{"id":"done"}"#])
        #expect(resumeOffset == Int64(Data(complete.utf8).count))

        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((#""}"# + "\n").utf8))
        try handle.close()

        var secondPass: [String] = []
        let endOffset = try CostUsageJsonl.scan(
            fileURL: fileURL,
            offset: resumeOffset,
            maxLineBytes: 1024,
            prefixBytes: 1024)
        { line in
            secondPass.append(String(bytes: line.bytes, encoding: .utf8) ?? "")
        }

        #expect(secondPass == [#"{"id":"partial"}"#])
        #expect(endOffset == Int64(Data((complete + partial + #""}"# + "\n").utf8).count))
    }

    @Test
    func `jsonl scanner accepts a complete final record without newline`() throws {
        let root = try self.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let fileURL = root.appendingPathComponent("final-record.jsonl", isDirectory: false)
        let record = #"{"id":"complete"}"#
        try record.write(to: fileURL, atomically: true, encoding: .utf8)

        var scanned: [String] = []
        let endOffset = try CostUsageJsonl.scan(fileURL: fileURL, maxLineBytes: 1024, prefixBytes: 1024) { line in
            scanned.append(String(bytes: line.bytes, encoding: .utf8) ?? "")
        }

        #expect(scanned == [record])
        #expect(endOffset == Int64(Data(record.utf8).count))
    }

    @Test
    func `jsonl scanner commits an oversized final record it would drop anyway`() throws {
        let root = try self.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let fileURL = root.appendingPathComponent("oversized-tail.jsonl", isDirectory: false)
        let oversized = #"{"message":""# + String(repeating: "x", count: 256)
        try oversized.write(to: fileURL, atomically: true, encoding: .utf8)

        var scanned: [CostUsageJsonl.Line] = []
        let endOffset = try CostUsageJsonl.scan(fileURL: fileURL, maxLineBytes: 64, prefixBytes: 64) { line in
            scanned.append(line)
        }

        #expect(scanned.count == 1)
        #expect(scanned[0].wasTruncated)
        #expect(endOffset == Int64(Data(oversized.utf8).count))
    }

    private func makeTemporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sturtbar-cost-usage-jsonl-\(UUID().uuidString)",
            isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
