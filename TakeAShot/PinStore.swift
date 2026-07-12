import Foundation

protocol PinFileOperating: Sendable {
    func createDirectory(at url: URL) throws
    func data(at url: URL) throws -> Data
    func write(_ data: Data, to url: URL) throws
    func replaceItem(at destination: URL, with source: URL) throws
    func removeItem(at url: URL) throws
    func fileExists(at url: URL) -> Bool
}

struct LivePinFileOperations: PinFileOperating {
    func createDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func data(at url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    func write(_ data: Data, to url: URL) throws {
        try data.write(to: url)
    }

    func replaceItem(at destination: URL, with source: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: source)
        } else {
            try FileManager.default.moveItem(at: source, to: destination)
        }
    }

    func removeItem(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}

actor PinStore {
    private let rootURL: URL
    private let documentURL: URL
    private let fileOperations: any PinFileOperating
    private var pins: [PinnedReference] = []
    private var issues: [PinLoadIssue] = []
    private var pendingWrite: Task<Void, Error>?

    init(
        rootURL: URL,
        fileOperations: any PinFileOperating = LivePinFileOperations()
    ) {
        self.rootURL = rootURL
        documentURL = rootURL.appendingPathComponent("pins.json")
        self.fileOperations = fileOperations
    }

    func load() throws -> [PinnedReference] {
        guard fileOperations.fileExists(at: documentURL) else {
            pins = []
            issues = []
            return []
        }
        let result = try PinDocumentCodec.decode(fileOperations.data(at: documentURL))
        pins = Self.deduplicate(result.pins)
        issues = result.issues
        return pins
    }

    func loadIssues() -> [PinLoadIssue] { issues }

    func replaceAll(_ newPins: [PinnedReference]) throws {
        pins = Self.deduplicate(newPins)
        try publishNow()
    }

    func scheduleUpsert(_ pin: PinnedReference) {
        var normalizedPin = pin
        normalizedPin.normalize()
        pins.removeAll { $0.id == normalizedPin.id || $0.captureID == normalizedPin.captureID }
        pins.append(normalizedPin)
        pendingWrite?.cancel()
        pendingWrite = Task {
            try await Task.sleep(for: .milliseconds(250))
            try Task.checkCancellation()
            try self.publishNow()
        }
    }

    func remove(id: UUID) throws {
        pins.removeAll { $0.id == id }
        try publishNow()
    }

    func flush() async throws {
        try await pendingWrite?.value
        pendingWrite = nil
    }

    private func publishNow() throws {
        let temporaryURL = rootURL.appendingPathComponent("pins.json.tmp")
        do {
            try fileOperations.createDirectory(at: rootURL)
            let document = PinStoreDocument(
                schemaVersion: PinStoreDocument.currentSchemaVersion,
                pins: pins
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try fileOperations.write(encoder.encode(document), to: temporaryURL)
            try fileOperations.replaceItem(at: documentURL, with: temporaryURL)
        } catch {
            try? fileOperations.removeItem(at: temporaryURL)
            throw PinStoreError.atomicPublishFailed(error.localizedDescription)
        }
    }

    private static func deduplicate(_ records: [PinnedReference]) -> [PinnedReference] {
        var deduplicated: [PinnedReference] = []
        var indexesByCaptureID: [UUID: Int] = [:]

        for var record in records {
            record.normalize()
            if let index = indexesByCaptureID[record.captureID] {
                if record.updatedAt > deduplicated[index].updatedAt {
                    deduplicated[index] = record
                }
            } else {
                indexesByCaptureID[record.captureID] = deduplicated.count
                deduplicated.append(record)
            }
        }

        return deduplicated
    }
}

private enum PinDocumentCodec {
    struct Result {
        var pins: [PinnedReference]
        var issues: [PinLoadIssue]
    }

    static func decode(_ data: Data) throws -> Result {
        guard let source = String(data: data, encoding: .utf8) else {
            throw PinStoreError.malformedDocument
        }
        let parser = PinDocumentTextParser(source: source)
        let schemaVersion = try parser.schemaVersion()
        guard schemaVersion == PinStoreDocument.currentSchemaVersion else {
            throw PinStoreError.unsupportedSchema(schemaVersion)
        }

        var pins: [PinnedReference] = []
        var issues: [PinLoadIssue] = []
        let decoder = JSONDecoder()
        for candidate in try parser.pinCandidates() {
            switch candidate.contents {
            case let .json(object):
                do {
                    var pin = try decoder.decode(PinnedReference.self, from: Data(object.utf8))
                    pin.normalize()
                    pins.append(pin)
                } catch {
                    issues.append(PinLoadIssue(recordIndex: candidate.index, reason: error.localizedDescription))
                }
            case let .malformed(reason):
                issues.append(PinLoadIssue(recordIndex: candidate.index, reason: reason))
            }
        }
        return Result(pins: pins, issues: issues)
    }
}

private struct PinDocumentTextParser {
    private let source: String

    init(source: String) {
        self.source = source
    }

    func schemaVersion() throws -> Int {
        guard source.first == "{", source.last == "}",
              let value = valueFollowing(key: "schemaVersion"),
              let version = Int(value.token) else {
            throw PinStoreError.malformedDocument
        }
        return version
    }

    func pinCandidates() throws -> [PinCandidate] {
        guard let value = valueFollowing(key: "pins"), value.first == "[" else {
            throw PinStoreError.malformedDocument
        }

        var index = source.index(after: value.start)
        var candidates: [PinCandidate] = []
        var recordIndex = 0

        while index < source.endIndex {
            skipSeparators(from: &index)
            guard index < source.endIndex else { break }
            if source[index] == "]" { return candidates }

            let candidate = objectCandidate(from: index, index: recordIndex)
            candidates.append(candidate.candidate)
            recordIndex += 1
            index = candidate.nextIndex
        }

        throw PinStoreError.malformedDocument
    }

    private func valueFollowing(key: String) -> (start: String.Index, first: Character?, token: String)? {
        guard let keyRange = source.range(of: "\"\(key)\"") else { return nil }
        var index = keyRange.upperBound
        skipWhitespace(from: &index)
        guard index < source.endIndex, source[index] == ":" else { return nil }
        index = source.index(after: index)
        skipWhitespace(from: &index)
        let start = index
        while index < source.endIndex,
              !source[index].isWhitespace,
              source[index] != ",",
              source[index] != "}",
              source[index] != "]" {
            index = source.index(after: index)
        }
        return (start, start < source.endIndex ? source[start] : nil, String(source[start..<index]))
    }

    private func objectCandidate(
        from start: String.Index,
        index recordIndex: Int
    ) -> (candidate: PinCandidate, nextIndex: String.Index) {
        guard source[start] == "{" else {
            return malformedCandidate(from: start, index: recordIndex, reason: "Expected a JSON object.")
        }

        var stack: [Character] = ["{"]
        var index = source.index(after: start)
        var inString = false
        var escaped = false

        while index < source.endIndex {
            let character = source[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
            } else if character == "\"" {
                inString = true
            } else if character == "{" || character == "[" {
                stack.append(character)
            } else if character == "}" || character == "]" {
                let expectedOpen: Character = character == "}" ? "{" : "["
                guard !stack.isEmpty, stack[stack.count - 1] == expectedOpen else {
                    return (
                        PinCandidate(index: recordIndex, contents: .malformed("Unbalanced JSON object.")),
                        source.index(after: index)
                    )
                }
                stack.removeLast()
                if stack.isEmpty {
                    let end = source.index(after: index)
                    return (PinCandidate(index: recordIndex, contents: .json(String(source[start..<end]))), end)
                }
            }
            index = source.index(after: index)
        }

        return (PinCandidate(index: recordIndex, contents: .malformed("Unterminated JSON object.")), index)
    }

    private func malformedCandidate(
        from start: String.Index,
        index recordIndex: Int,
        reason: String
    ) -> (candidate: PinCandidate, nextIndex: String.Index) {
        var index = start
        while index < source.endIndex, source[index] != ",", source[index] != "]" {
            index = source.index(after: index)
        }
        return (PinCandidate(index: recordIndex, contents: .malformed(reason)), index)
    }

    private func skipSeparators(from index: inout String.Index) {
        while index < source.endIndex, source[index].isWhitespace || source[index] == "," {
            index = source.index(after: index)
        }
    }

    private func skipWhitespace(from index: inout String.Index) {
        while index < source.endIndex, source[index].isWhitespace {
            index = source.index(after: index)
        }
    }
}

private struct PinCandidate {
    enum Contents {
        case json(String)
        case malformed(String)
    }

    let index: Int
    let contents: Contents
}
