import Foundation
import SQLite3

/// Overwrites a clip's content before SwiftData deletes it, so deleted clips don't linger in
/// the database file, its write-ahead log or the large-data folder.
///
/// SQLite normally just marks a deleted row's space as free, leaving the old bytes in place until
/// something reuses it. Here, each content column is first rewritten in place with blanks of the
/// same size (so SQLite overwrites the same bytes rather than moving the row), and any file a
/// large value lives in is overwritten with zeros. After SwiftData deletes the rows, a checkpoint
/// copies the log into the database and empties it.
///
/// This is best effort: APFS and SSDs can keep old copies of blocks out of reach of any app, and
/// clips deleted on another device and removed here by iCloud aren't scrubbed. The writes go
/// through a separate SQLite connection and never change Core Data's bookkeeping (`Z_OPT`), so
/// nothing about them is synced; only the deletion itself is.
enum SecureDelete {
    /// Content columns of `ClipItem`: text, then binary (possibly stored in external files).
    /// The file paths and keywords arrays are left as they are: Core Data decodes them while
    /// deleting the row, and blanked bytes can't be decoded.
    private static let clipTextColumns = ["ZTEXT", "ZTITLE", "ZLINKTITLE", "ZCONTENTHASH"]
    private static let clipBinaryColumns = ["ZRTFDATA", "ZIMAGEDATA", "ZLINKIMAGEDATA"]

    /// Blanks the given clips in the synced store. Call it right before deleting them with SwiftData.
    static func scrubClips(_ ids: [UUID], store: URL) {
        scrub(ids, store: store, table: "ZCLIPITEM", idColumn: "ZID",
              textColumns: clipTextColumns, binaryColumns: clipBinaryColumns, supportFolder: ".Klip_SUPPORT")
    }

    /// Blanks the local-only images of the given clips. Call it right before deleting them.
    static func scrubLocalImages(_ clipIDs: [UUID], store: URL) {
        scrub(clipIDs, store: store, table: "ZLOCALIMAGE", idColumn: "ZCLIPID",
              textColumns: [], binaryColumns: ["ZDATA"], supportFolder: ".KlipLocal_SUPPORT")
    }

    /// Moves the write-ahead log into the database and empties it, so old versions of
    /// overwritten pages don't stay in the log. Call it after saving the deletion.
    static func checkpoint(store: URL) {
        guard let db = open(store) else { return }
        defer { sqlite3_close(db) }
        sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE)", nil, nil, nil)
    }

    // MARK: -

    /// Always on since 1.72; it used to be a setting in Settings → Privacy, off by default.
    private static func scrub(_ ids: [UUID], store: URL, table: String, idColumn: String,
                              textColumns: [String], binaryColumns: [String], supportFolder: String) {
        guard !ids.isEmpty, let db = open(store) else { return }
        defer { sqlite3_close(db) }
        let externalFolder = store.deletingLastPathComponent().appending(path: "\(supportFolder)/_EXTERNAL_DATA")

        // How many of each ID are being deleted: a row is only blanked when every row with its ID
        // is going away, so a duplicate that iCloud imported with the same ID is never touched.
        var deleting: [UUID: Int] = [:]
        for id in ids { deleting[id, default: 0] += 1 }

        // Text keeps its byte length as spaces; binary keeps its first byte (Core Data's marker for
        // inline data or a file reference) and the rest becomes zeros. Same size means SQLite
        // rewrites the row where it is. File references are left alone, so Core Data can still
        // remove the file; the file itself is zeroed instead.
        let blankText = textColumns.map { "\($0) = CASE WHEN \($0) IS NULL THEN NULL ELSE printf('%.*c', length(CAST(\($0) AS BLOB)), ' ') END" }
        let blankBinary = binaryColumns.map {
            "\($0) = CASE WHEN \($0) IS NULL OR length(\($0)) = 0 OR substr(\($0), 1, 1) = x'02' THEN \($0) ELSE substr(\($0), 1, 1) || zeroblob(length(\($0)) - 1) END"
        }
        let update = "UPDATE \(table) SET \((blankText + blankBinary).joined(separator: ", ")) WHERE \(idColumn) = ?1"
        let count = "SELECT count(*) FROM \(table) WHERE \(idColumn) = ?1"
        let references = "SELECT \(binaryColumns.joined(separator: ", ")) FROM \(table) WHERE \(idColumn) = ?1"

        guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { return }
        for (id, deletingCount) in deleting {
            let rows = queryInt(db, count, id: id) ?? .max
            guard rows > 0, rows <= deletingCount else { continue }
            for name in externalFileNames(db, references, id: id, columnCount: binaryColumns.count) {
                zeroFile(externalFolder.appending(path: name))
            }
            run(db, update, id: id)
        }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
    }

    private static func open(_ store: URL) -> OpaquePointer? {
        guard FileManager.default.fileExists(atPath: store.path) else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(store.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        // Core Data may be writing at the same moment; wait for it rather than fail.
        sqlite3_busy_timeout(db, 3000)
        return db
    }

    private static func bind(_ statement: OpaquePointer?, _ id: UUID) {
        let bytes = withUnsafeBytes(of: id.uuid) { Data($0) }
        _ = bytes.withUnsafeBytes { buffer in
            sqlite3_bind_blob(statement, 1, buffer.baseAddress, Int32(buffer.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
    }

    private static func run(_ db: OpaquePointer, _ sql: String, id: UUID) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        bind(statement, id)
        sqlite3_step(statement)
    }

    private static func queryInt(_ db: OpaquePointer, _ sql: String, id: UUID) -> Int? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        bind(statement, id)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int64(statement, 0))
    }

    /// Core Data stores a large value as 0x02, the file's name, and a NUL.
    private static func externalFileNames(_ db: OpaquePointer, _ sql: String, id: UUID, columnCount: Int) -> [String] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        bind(statement, id)
        var names: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            for column in 0..<Int32(columnCount) {
                let length = Int(sqlite3_column_bytes(statement, column))
                guard length > 2, let blob = sqlite3_column_blob(statement, column) else { continue }
                let data = Data(bytes: blob, count: length)
                guard data.first == 0x02,
                      let name = String(data: data.dropFirst().prefix { $0 != 0 }, encoding: .utf8),
                      !name.isEmpty, !name.contains("/"), !name.contains("..")
                else { continue }
                names.append(name)
            }
        }
        return names
    }

    private static func zeroFile(_ url: URL) {
        guard let handle = try? FileHandle(forUpdating: url) else { return }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 0 else { return }
        try? handle.seek(toOffset: 0)
        let chunk = Data(count: 1 << 20)
        var remaining = Int(size)
        while remaining > 0 {
            let count = min(remaining, chunk.count)
            try? handle.write(contentsOf: chunk.prefix(count))
            remaining -= count
        }
        try? handle.synchronize()
    }
}
