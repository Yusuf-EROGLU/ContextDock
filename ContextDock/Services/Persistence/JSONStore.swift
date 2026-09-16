import Foundation

/// Outcome of loading a versioned JSON document.
enum JSONLoadResult<Value: Sendable>: Sendable {
    case loaded(Value)
    case missing
    /// The file could not be decoded; it was renamed so the user can recover it.
    case corrupt(preservedAt: URL?)
    /// The file was written by a newer ContextDock; it must not be overwritten.
    case newerSchema(found: Int)
}

/// Versioned, atomically written JSON file. Never crashes on bad input and never silently
/// discards data it cannot understand.
struct JSONStore<Value: Codable & Sendable>: Sendable {
    let url: URL
    let currentSchemaVersion: Int

    private struct SchemaPeek: Decodable {
        let schemaVersion: Int?
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    func load() -> JSONLoadResult<Value> {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return .missing }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            Log.store.error("Failed to read \(self.url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return .corrupt(preservedAt: nil)
        }

        if let peek = try? Self.decoder.decode(SchemaPeek.self, from: data),
           let version = peek.schemaVersion, version > currentSchemaVersion {
            return .newerSchema(found: version)
        }

        do {
            return .loaded(try Self.decoder.decode(Value.self, from: data))
        } catch {
            Log.store.error("Corrupt \(self.url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return .corrupt(preservedAt: preserveCorruptFile())
        }
    }

    func save(_ value: Value) throws {
        let data = try Self.encoder.encode(value)
        try Self.writeAtomically(data, to: url)
    }

    static func writeAtomically(_ data: Data, to url: URL) throws {
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        try data.write(to: temporary, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        if fileManager.fileExists(atPath: url.path) {
            _ = try fileManager.replaceItemAt(url, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: url)
        }
    }

    private func preserveCorruptFile() -> URL? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let destination = url.appendingPathExtension("corrupt-\(formatter.string(from: Date()))")
        do {
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        } catch {
            Log.store.error("Could not preserve corrupt file: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
