import Foundation
import SQLite3
import CryptoKit
import Darwin

enum DatabaseSchema {
    static let currentVersion = 1
    static let metadataKey = "database_schema_version"
}

enum DatabaseMigrationStep: Equatable, Sendable {
    case legacyToVersion1

    var sourceVersion: Int {
        switch self {
        case .legacyToVersion1: 0
        }
    }

    var targetVersion: Int {
        switch self {
        case .legacyToVersion1: 1
        }
    }
}

enum DatabaseMigrationPlan {
    static func requiredStep(for schema: ExistingDatabaseSchema) throws -> DatabaseMigrationStep? {
        switch schema {
        case .legacy, .versioned(0):
            return .legacyToVersion1
        case .new, .versioned(DatabaseSchema.currentVersion):
            return nil
        case .versioned:
            throw StoreError.invalidDatabaseSchemaMetadata
        }
    }
}

public struct StoreCompatibilityFailure: Equatable, Sendable {
    public static let newerSchemaReasonCode = "STORE_SCHEMA_NEWER_THAN_APP"
    public static let upgradeOrResetActionCode = "UPGRADE_OR_RESET_DATA"

    public let reasonCode: String
    public let actionCode: String
    public let databaseSchemaVersion: Int
    public let supportedSchemaVersion: Int

    init(databaseSchemaVersion: Int, supportedSchemaVersion: Int) {
        reasonCode = Self.newerSchemaReasonCode
        actionCode = Self.upgradeOrResetActionCode
        self.databaseSchemaVersion = databaseSchemaVersion
        self.supportedSchemaVersion = supportedSchemaVersion
    }
}

public struct StoreMigrationFailure: Equatable, Sendable {
    public static let reasonCode = "DATABASE_MIGRATION_FAILED"
    public static let actionCode = "RETRY_OR_RESET_DATA"

    public let reasonCode: String
    public let actionCode: String
    public let sourceSchemaVersion: Int
    public let targetSchemaVersion: Int
    public let backupAvailable: Bool

    public init(sourceSchemaVersion: Int, targetSchemaVersion: Int, backupAvailable: Bool) {
        reasonCode = Self.reasonCode
        actionCode = Self.actionCode
        self.sourceSchemaVersion = sourceSchemaVersion
        self.targetSchemaVersion = targetSchemaVersion
        self.backupAvailable = backupAvailable
    }
}

public struct StoreMigrationBackupFailure: Equatable, Sendable {
    public static let reasonCode = "MIGRATION_BACKUP_FAILED"
    public static let actionCode = "RETRY_OR_RESET_DATA"

    public let reasonCode: String
    public let actionCode: String
    public let sourceSchemaVersion: Int
    public let targetSchemaVersion: Int

    public init(sourceSchemaVersion: Int, targetSchemaVersion: Int) {
        reasonCode = Self.reasonCode
        actionCode = Self.actionCode
        self.sourceSchemaVersion = sourceSchemaVersion
        self.targetSchemaVersion = targetSchemaVersion
    }
}

enum ExistingDatabaseSchema: Equatable {
    case new
    case legacy
    case versioned(Int)
}

enum DatabaseMigrationCheckpoint: Equatable, Sendable {
    case initialPreflightCompleted
    case backupStagingPathResolved
    case backupStagingCreated
    case backupVerified
    case schemaChangesApplied
    case schemaValidated
    case willCommit
}

struct DatabaseMigrationOperations: @unchecked Sendable {
    var checkpoint: (DatabaseMigrationCheckpoint) throws -> Void
    var writeBackupManifest: (Data, Int32) throws -> Void

    init(
        checkpoint: @escaping (DatabaseMigrationCheckpoint) throws -> Void = { _ in },
        writeBackupManifest: @escaping (Data, Int32) throws -> Void = {
            try writeMigrationData($0, to: $1)
        }
    ) {
        self.checkpoint = checkpoint
        self.writeBackupManifest = writeBackupManifest
    }

    static let live = DatabaseMigrationOperations()
}

final class PinnedDatabaseLocation {
    let databaseURL: URL
    let databaseName: String
    let parentDescriptor: Int32

    init(databaseURL: URL) throws {
        let parentURL = databaseURL.deletingLastPathComponent().standardizedFileURL
        let databaseName = databaseURL.lastPathComponent
        guard !databaseName.isEmpty, databaseName != ".", databaseName != ".." else {
            throw StoreError.openFailed(SQLITE_CANTOPEN)
        }
        var parentInfo = stat()
        guard lstat(parentURL.path, &parentInfo) == 0,
              parentInfo.st_mode & S_IFMT == S_IFDIR else {
            throw StoreError.openFailed(SQLITE_CANTOPEN)
        }
        let parentDescriptor = Darwin.open(
            parentURL.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard parentDescriptor >= 0 else {
            throw StoreError.openFailed(SQLITE_CANTOPEN)
        }
        do {
            let canonicalParentPath = try Self.path(for: parentDescriptor)
            self.databaseURL = URL(fileURLWithPath: canonicalParentPath, isDirectory: true)
                .appendingPathComponent(databaseName)
            self.databaseName = databaseName
            self.parentDescriptor = parentDescriptor
            _ = try databaseExists()
        } catch {
            Darwin.close(parentDescriptor)
            throw error
        }
    }

    func databaseExists() throws -> Bool {
        var info = stat()
        guard fstatat(parentDescriptor, databaseName, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return false }
            throw StoreError.openFailed(SQLITE_CANTOPEN)
        }
        guard info.st_mode & S_IFMT == S_IFREG else {
            throw StoreError.openFailed(SQLITE_CANTOPEN)
        }
        return true
    }

    deinit {
        Darwin.close(parentDescriptor)
    }

    private static func path(for descriptor: Int32) throws -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard fcntl(descriptor, F_GETPATH, &buffer) == 0 else {
            throw StoreError.openFailed(SQLITE_CANTOPEN)
        }
        return String(
            decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
    }
}

final class DatabaseUpgradeLock {
    private var descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    static func acquire(for location: PinnedDatabaseLocation) throws -> DatabaseUpgradeLock {
        let descriptor = openat(
            location.parentDescriptor,
            ".\(location.databaseName).migration.lock",
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw StoreError.openFailed(errno)
        }
        guard flock(descriptor, LOCK_EX) == 0 else {
            let status = errno
            close(descriptor)
            throw StoreError.openFailed(status)
        }
        return DatabaseUpgradeLock(descriptor: descriptor)
    }

    func release() {
        guard descriptor >= 0 else { return }
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }

    deinit {
        release()
    }
}

struct MigrationBackupManifest: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable {
        case ready
        case migrationSucceeded
        case migrationFailed
    }

    static let currentFormatVersion = 1

    let formatVersion: Int
    let backupID: String
    let sourceSchemaVersion: Int
    let targetSchemaVersion: Int
    let applicationVersion: String
    let checksumSHA256: String
    let byteSize: Int64
    let createdAt: Date
    var status: Status

    init(
        backupID: String,
        sourceSchemaVersion: Int,
        targetSchemaVersion: Int,
        applicationVersion: String,
        checksumSHA256: String,
        byteSize: Int64,
        createdAt: Date,
        status: Status
    ) {
        formatVersion = Self.currentFormatVersion
        self.backupID = backupID
        self.sourceSchemaVersion = sourceSchemaVersion
        self.targetSchemaVersion = targetSchemaVersion
        self.applicationVersion = applicationVersion
        self.checksumSHA256 = checksumSHA256
        self.byteSize = byteSize
        self.createdAt = createdAt
        self.status = status
    }
}

struct MigrationBackup {
    let databaseURL: URL
    var manifest: MigrationBackupManifest
}

private final class PinnedMigrationBackupDirectory {
    let databaseURL: URL
    let parentDescriptor: Int32
    let descriptor: Int32

    private init(databaseURL: URL, parentDescriptor: Int32, descriptor: Int32) {
        self.databaseURL = databaseURL
        self.parentDescriptor = parentDescriptor
        self.descriptor = descriptor
    }

    static func open(databaseURL: URL, create: Bool) throws -> PinnedMigrationBackupDirectory? {
        let parentURL = databaseURL.deletingLastPathComponent()
        let parentDescriptor = Darwin.open(
            parentURL.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard parentDescriptor >= 0 else { throw MigrationBackupOperationError() }
        do {
            guard let rootDescriptor = try openDirectory(
                named: MigrationBackupManager.directoryName,
                relativeTo: parentDescriptor,
                create: create
            ) else {
                Darwin.close(parentDescriptor)
                return nil
            }
            defer { Darwin.close(rootDescriptor) }
            guard let storeDescriptor = try openDirectory(
                named: MigrationBackupManager.storeIdentifier(for: databaseURL),
                relativeTo: rootDescriptor,
                create: create
            ) else {
                Darwin.close(parentDescriptor)
                return nil
            }
            cleanupStagingArtifacts(in: storeDescriptor)
            return PinnedMigrationBackupDirectory(
                databaseURL: databaseURL,
                parentDescriptor: parentDescriptor,
                descriptor: storeDescriptor
            )
        } catch {
            Darwin.close(parentDescriptor)
            throw error
        }
    }

    func entryNames() throws -> [String] {
        let streamDescriptor = openat(
            descriptor,
            ".",
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard streamDescriptor >= 0, let stream = fdopendir(streamDescriptor) else {
            if streamDescriptor >= 0 { Darwin.close(streamDescriptor) }
            throw MigrationBackupOperationError()
        }
        defer { closedir(stream) }
        var names: [String] = []
        errno = 0
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                    String(cString: $0)
                }
            }
            if name != ".", name != ".." { names.append(name) }
        }
        guard errno == 0 else { throw MigrationBackupOperationError() }
        return names
    }

    func pinnedPath() throws -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard fcntl(descriptor, F_GETPATH, &buffer) == 0 else {
            throw MigrationBackupOperationError()
        }
        return String(
            decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
    }

    func readRegularFile(named name: String) throws -> Data {
        let fileDescriptor = openRegularFile(named: name, flags: O_RDONLY)
        guard fileDescriptor >= 0 else { throw MigrationBackupOperationError() }
        let handle = FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        return try handle.readToEnd() ?? Data()
    }

    func fileSize(named name: String) throws -> Int64 {
        let fileDescriptor = openRegularFile(named: name, flags: O_RDONLY)
        guard fileDescriptor >= 0 else { throw MigrationBackupOperationError() }
        defer { Darwin.close(fileDescriptor) }
        var info = stat()
        guard fstat(fileDescriptor, &info) == 0 else { throw MigrationBackupOperationError() }
        return info.st_size
    }

    func sha256(named name: String) throws -> String {
        let fileDescriptor = openRegularFile(named: name, flags: O_RDONLY)
        guard fileDescriptor >= 0 else { throw MigrationBackupOperationError() }
        let handle = FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var digest = SHA256()
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            guard !data.isEmpty else { break }
            digest.update(data: data)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func integrityCheck(named name: String) throws -> Bool {
        let fileDescriptor = openRegularFile(named: name, flags: O_RDONLY)
        guard fileDescriptor >= 0 else { throw MigrationBackupOperationError() }
        defer { Darwin.close(fileDescriptor) }
        var database: OpaquePointer?
        let status = sqlite3_open_v2(
            "/dev/fd/\(fileDescriptor)",
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard status == SQLITE_OK, let database else {
            sqlite3_close(database)
            throw MigrationBackupOperationError()
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA integrity_check;", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw MigrationBackupOperationError()
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let result = sqlite3_column_text(statement, 0) else {
            throw MigrationBackupOperationError()
        }
        return String(cString: result) == "ok"
    }

    func containsRegularFile(named name: String) -> Bool {
        let fileDescriptor = openRegularFile(named: name, flags: O_RDONLY)
        guard fileDescriptor >= 0 else { return false }
        Darwin.close(fileDescriptor)
        return true
    }

    func removeArtifact(named name: String) {
        let path = name as NSString
        guard ["sqlite", "json"].contains(path.pathExtension),
              UUID(uuidString: path.deletingPathExtension) != nil else {
            return
        }
        var info = stat()
        guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return }
        let fileType = info.st_mode & S_IFMT
        guard fileType == S_IFREG || fileType == S_IFLNK else { return }
        _ = unlinkat(descriptor, name, 0)
    }

    func writeManifest(
        _ data: Data,
        named name: String,
        using writer: (Data, Int32) throws -> Void = { try writeMigrationData($0, to: $1) }
    ) throws {
        let path = name as NSString
        guard path.pathExtension == "json", UUID(uuidString: path.deletingPathExtension) != nil else {
            throw MigrationBackupOperationError()
        }
        let temporaryName = ".manifest-\(UUID().uuidString.lowercased()).tmp"
        let fileDescriptor = openat(
            descriptor,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard fileDescriptor >= 0 else { throw MigrationBackupOperationError() }
        var published = false
        defer {
            Darwin.close(fileDescriptor)
            if !published { _ = unlinkat(descriptor, temporaryName, 0) }
        }
        try writer(data, fileDescriptor)
        guard fsync(fileDescriptor) == 0,
              renameat(descriptor, temporaryName, descriptor, name) == 0 else {
            throw MigrationBackupOperationError()
        }
        guard fsync(descriptor) == 0 else { throw MigrationBackupOperationError() }
        published = true
    }

    deinit {
        Darwin.close(descriptor)
        Darwin.close(parentDescriptor)
    }

    private func openRegularFile(named name: String, flags: Int32) -> Int32 {
        let fileDescriptor = openat(descriptor, name, flags | O_CLOEXEC | O_NOFOLLOW)
        guard fileDescriptor >= 0 else { return -1 }
        var info = stat()
        guard fstat(fileDescriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            Darwin.close(fileDescriptor)
            return -1
        }
        return fileDescriptor
    }

    private static func openDirectory(
        named name: String,
        relativeTo parentDescriptor: Int32,
        create: Bool
    ) throws -> Int32? {
        var directoryDescriptor = openat(
            parentDescriptor,
            name,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        if directoryDescriptor >= 0 { return directoryDescriptor }
        guard errno == ENOENT else { throw MigrationBackupOperationError() }
        guard create else { return nil }
        guard mkdirat(parentDescriptor, name, S_IRWXU) == 0 || errno == EEXIST else {
            throw MigrationBackupOperationError()
        }
        directoryDescriptor = openat(
            parentDescriptor,
            name,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard directoryDescriptor >= 0 else { throw MigrationBackupOperationError() }
        return directoryDescriptor
    }

    private static func cleanupStagingArtifacts(in directoryDescriptor: Int32) {
        let streamDescriptor = openat(
            directoryDescriptor,
            ".",
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard streamDescriptor >= 0, let stream = fdopendir(streamDescriptor) else {
            if streamDescriptor >= 0 { Darwin.close(streamDescriptor) }
            return
        }
        defer { closedir(stream) }
        let prefix = ".migration-backup-staging-"
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                    String(cString: $0)
                }
            }
            guard name.hasPrefix(prefix) else { continue }
            let remainder = String(name.dropFirst(prefix.count))
            let rawID: String
            if remainder.hasSuffix(".sqlite-journal") {
                rawID = String(remainder.dropLast(".sqlite-journal".count))
            } else if remainder.hasSuffix(".sqlite-wal") {
                rawID = String(remainder.dropLast(".sqlite-wal".count))
            } else if remainder.hasSuffix(".sqlite-shm") {
                rawID = String(remainder.dropLast(".sqlite-shm".count))
            } else if remainder.hasSuffix(".sqlite") {
                rawID = String(remainder.dropLast(".sqlite".count))
            } else {
                continue
            }
            guard UUID(uuidString: rawID) != nil else { continue }
            var info = stat()
            guard fstatat(directoryDescriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            let fileType = info.st_mode & S_IFMT
            guard fileType == S_IFREG || fileType == S_IFLNK else { continue }
            _ = unlinkat(directoryDescriptor, name, 0)
        }
    }
}

enum MigrationBackupManager {
    static let directoryName = "migration-backups"
    static let retainedBackupLimit = 3

    static func directory(for databaseURL: URL) -> URL {
        backupRoot(for: databaseURL)
            .appendingPathComponent(storeIdentifier(for: databaseURL), isDirectory: true)
    }

    static func create(
        databaseURL: URL,
        sourceVersion: Int,
        targetVersion: Int,
        checkpoint: (DatabaseMigrationCheckpoint) throws -> Void,
        writeManifest: (Data, Int32) throws -> Void,
        now: Date = Date(),
        applicationVersion: String = currentApplicationVersion
    ) throws -> MigrationBackup {
        do {
            return try createVerifiedBackup(
                databaseURL: databaseURL,
                sourceVersion: sourceVersion,
                targetVersion: targetVersion,
                checkpoint: checkpoint,
                writeManifest: writeManifest,
                now: now,
                applicationVersion: applicationVersion
            )
        } catch {
            throw StoreError.migrationBackupFailed(StoreMigrationBackupFailure(
                sourceSchemaVersion: sourceVersion,
                targetSchemaVersion: targetVersion
            ))
        }
    }

    private static func createVerifiedBackup(
        databaseURL: URL,
        sourceVersion: Int,
        targetVersion: Int,
        checkpoint: (DatabaseMigrationCheckpoint) throws -> Void,
        writeManifest: (Data, Int32) throws -> Void,
        now: Date,
        applicationVersion: String
    ) throws -> MigrationBackup {
        guard let directory = try PinnedMigrationBackupDirectory.open(
            databaseURL: databaseURL,
            create: true
        ) else { throw MigrationBackupOperationError() }
        let backupID = UUID().uuidString.lowercased()
        let backupName = "\(backupID).sqlite"
        let manifestName = "\(backupID).json"
        var manifestWritten = false
        defer {
            if !manifestWritten {
                directory.removeArtifact(named: backupName)
                directory.removeArtifact(named: manifestName)
            }
        }
        try createConsistentBackup(
            databaseURL: databaseURL,
            directory: directory,
            backupName: backupName,
            checkpoint: checkpoint
        )
        guard try directory.integrityCheck(named: backupName) else {
            throw MigrationBackupOperationError()
        }
        let byteSize = try directory.fileSize(named: backupName)
        let checksum = try directory.sha256(named: backupName)
        guard try directory.fileSize(named: backupName) == byteSize,
              try directory.sha256(named: backupName) == checksum else {
            throw MigrationBackupOperationError()
        }
        let manifest = MigrationBackupManifest(
            backupID: backupID,
            sourceSchemaVersion: sourceVersion,
            targetSchemaVersion: targetVersion,
            applicationVersion: applicationVersion,
            checksumSHA256: checksum,
            byteSize: byteSize,
            createdAt: now,
            status: .ready
        )
        try directory.writeManifest(
            try encodedManifest(manifest),
            named: manifestName,
            using: writeManifest
        )
        manifestWritten = true
        return MigrationBackup(databaseURL: databaseURL, manifest: manifest)
    }

    static func mark(_ backup: MigrationBackup, status: MigrationBackupManifest.Status) throws {
        guard let directory = try PinnedMigrationBackupDirectory.open(
            databaseURL: backup.databaseURL,
            create: false
        ) else { throw MigrationBackupOperationError() }
        var manifest = backup.manifest
        manifest.status = status
        try directory.writeManifest(
            try encodedManifest(manifest),
            named: "\(manifest.backupID).json"
        )
    }

    static func reconcileReadyBackups(databaseURL: URL, currentVersion: Int) {
        guard let directory = try? PinnedMigrationBackupDirectory.open(
            databaseURL: databaseURL,
            create: false
        ), let entries = try? directory.entryNames() else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        for manifestName in entries where (manifestName as NSString).pathExtension == "json" {
            guard let data = try? directory.readRegularFile(named: manifestName),
                  var manifest = try? decoder.decode(MigrationBackupManifest.self, from: data),
                  manifest.status == .ready,
                  manifest.targetSchemaVersion == currentVersion,
                  UUID(uuidString: manifest.backupID) != nil,
                  manifestName == "\(manifest.backupID).json" else {
                continue
            }
            guard isVerified(manifest, in: directory) else {
                continue
            }
            manifest.status = .migrationSucceeded
            if let data = try? encodedManifest(manifest) {
                try? directory.writeManifest(data, named: manifestName)
            }
        }
    }

    static func cleanupVerifiedBackups(databaseURL: URL) {
        guard let directory = try? PinnedMigrationBackupDirectory.open(
            databaseURL: databaseURL,
            create: false
        ), let entries = try? directory.entryNames() else { return }
        removeOrphanedBackupFiles(from: directory, entries: entries)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let verified: [MigrationBackupManifest] = entries.compactMap { manifestName in
            guard (manifestName as NSString).pathExtension == "json",
                  let data = try? directory.readRegularFile(named: manifestName),
                  let manifest = try? decoder.decode(MigrationBackupManifest.self, from: data),
                  UUID(uuidString: manifest.backupID) != nil,
                  manifestName == "\(manifest.backupID).json",
                  manifest.formatVersion == MigrationBackupManifest.currentFormatVersion else {
                return nil
            }
            return isVerified(manifest, in: directory) ? manifest : nil
        }.sorted {
            if $0.createdAt != $1.createdAt {
                return $0.createdAt > $1.createdAt
            }
            return $0.backupID > $1.backupID
        }

        guard verified.count > retainedBackupLimit else { return }
        var retainedIDs = Set<String>()
        if let lastGood = verified.first(where: { $0.status == .migrationSucceeded }) {
            retainedIDs.insert(lastGood.backupID)
        }
        for backup in verified where retainedIDs.count < retainedBackupLimit {
            retainedIDs.insert(backup.backupID)
        }
        for backup in verified where !retainedIDs.contains(backup.backupID) {
            directory.removeArtifact(named: "\(backup.backupID).sqlite")
            directory.removeArtifact(named: "\(backup.backupID).json")
        }
    }

    static func cleanupOrphanedBackups(databaseURL: URL) {
        guard let directory = try? PinnedMigrationBackupDirectory.open(
            databaseURL: databaseURL,
            create: false
        ), let entries = try? directory.entryNames() else { return }
        removeOrphanedBackupFiles(from: directory, entries: entries)
    }

    private static func removeOrphanedBackupFiles(
        from directory: PinnedMigrationBackupDirectory,
        entries: [String]
    ) {
        let manifestNames = Set(entries.compactMap { name -> String? in
            let path = name as NSString
            guard path.pathExtension == "json",
                  UUID(uuidString: path.deletingPathExtension) != nil,
                  directory.containsRegularFile(named: name) else {
                return nil
            }
            return name
        })
        for name in entries {
            let path = name as NSString
            guard path.pathExtension == "sqlite",
                  UUID(uuidString: path.deletingPathExtension) != nil,
                  !manifestNames.contains("\(path.deletingPathExtension).json") else {
                continue
            }
            directory.removeArtifact(named: name)
        }
    }

    private static func encodedManifest(_ manifest: MigrationBackupManifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(manifest)
    }

    private static func isVerified(
        _ manifest: MigrationBackupManifest,
        in directory: PinnedMigrationBackupDirectory
    ) -> Bool {
        let backupName = "\(manifest.backupID).sqlite"
        return (try? directory.fileSize(named: backupName)) == manifest.byteSize
            && (try? directory.sha256(named: backupName)) == manifest.checksumSHA256
            && (try? directory.integrityCheck(named: backupName)) == true
    }

    private static func createConsistentBackup(
        databaseURL: URL,
        directory: PinnedMigrationBackupDirectory,
        backupName: String,
        checkpoint: (DatabaseMigrationCheckpoint) throws -> Void
    ) throws {
        let stagingID = UUID().uuidString.lowercased()
        let stagingName = ".migration-backup-staging-\(stagingID).sqlite"
        defer {
            _ = unlinkat(directory.descriptor, "\(stagingName)-journal", 0)
            _ = unlinkat(directory.descriptor, "\(stagingName)-wal", 0)
            _ = unlinkat(directory.descriptor, "\(stagingName)-shm", 0)
            _ = unlinkat(directory.descriptor, stagingName, 0)
        }
        var sourceDatabase: OpaquePointer?
        let openStatus = sqlite3_open_v2(
            databaseURL.path,
            &sourceDatabase,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW,
            nil
        )
        guard openStatus == SQLITE_OK, let sourceDatabase else {
            sqlite3_close(sourceDatabase)
            throw MigrationBackupOperationError()
        }
        defer { sqlite3_close(sourceDatabase) }
        sqlite3_busy_timeout(sourceDatabase, 5_000)
        let directoryPath = try directory.pinnedPath()
        let stagingURL = URL(fileURLWithPath: directoryPath, isDirectory: true)
            .appendingPathComponent(stagingName)
        try checkpoint(.backupStagingPathResolved)
        let escapedPath = stagingURL.path.replacingOccurrences(of: "'", with: "''")
        guard sqlite3_exec(
            sourceDatabase,
            "VACUUM INTO '\(escapedPath)';",
            nil,
            nil,
            nil
        ) == SQLITE_OK else {
            throw MigrationBackupOperationError()
        }
        try checkpoint(.backupStagingCreated)
        var stagingInfo = stat()
        guard fstatat(directory.descriptor, stagingName, &stagingInfo, AT_SYMLINK_NOFOLLOW) == 0,
              stagingInfo.st_mode & S_IFMT == S_IFREG,
              renameat(
                directory.descriptor,
                stagingName,
                directory.descriptor,
                backupName
              ) == 0 else {
            throw MigrationBackupOperationError()
        }
        let backupDescriptor = openat(
            directory.descriptor,
            backupName,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard backupDescriptor >= 0 else {
            throw MigrationBackupOperationError()
        }
        defer { Darwin.close(backupDescriptor) }
        guard fsync(backupDescriptor) == 0,
              fsync(directory.descriptor) == 0 else {
            throw MigrationBackupOperationError()
        }
    }

    private static func backupRoot(for databaseURL: URL) -> URL {
        databaseURL.deletingLastPathComponent()
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    fileprivate static func storeIdentifier(for databaseURL: URL) -> String {
        let canonicalURL = databaseURL.deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .appendingPathComponent(databaseURL.lastPathComponent)
        let bytes = Data(canonicalURL.standardizedFileURL.path.utf8)
        return SHA256.hash(data: bytes).prefix(16)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static var currentApplicationVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? "development"
    }
}

private struct MigrationBackupOperationError: Error {}

private func writeMigrationData(_ data: Data, to descriptor: Int32) throws {
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
    try handle.write(contentsOf: data)
}

enum DatabaseMigrationPreflight {
    static func inspect(at location: PinnedDatabaseLocation) throws -> ExistingDatabaseSchema {
        guard try location.databaseExists() else { return .new }

        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW
        let status = sqlite3_open_v2(location.databaseURL.path, &database, flags, nil)
        guard status == SQLITE_OK, let database else {
            sqlite3_close(database)
            throw StoreError.openFailed(status)
        }
        defer { sqlite3_close(database) }

        return try inspect(database: database)
    }

    static func inspect(database: OpaquePointer) throws -> ExistingDatabaseSchema {
        guard try containsApplicationTables(database) else { return .new }
        guard try tableExists("schema_metadata", in: database) else { return .legacy }
        guard let rawVersion = try metadataValue(DatabaseSchema.metadataKey, in: database) else {
            guard try metadataValue("schema_version", in: database) == "retention-v1" else {
                throw StoreError.invalidDatabaseSchemaMetadata
            }
            return .legacy
        }
        guard let version = Int(rawVersion), version >= 0 else {
            throw StoreError.invalidDatabaseSchemaMetadata
        }
        if version > DatabaseSchema.currentVersion {
            throw StoreError.incompatibleDatabaseSchema(StoreCompatibilityFailure(
                databaseSchemaVersion: version,
                supportedSchemaVersion: DatabaseSchema.currentVersion
            ))
        }
        return .versioned(version)
    }

    private static func containsApplicationTables(_ database: OpaquePointer) throws -> Bool {
        var statement: OpaquePointer?
        let sql = "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' LIMIT 1;"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw StoreError.prepareFailed
        }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private static func tableExists(_ table: String, in database: OpaquePointer) throws -> Bool {
        var statement: OpaquePointer?
        let sql = "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1;"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw StoreError.prepareFailed
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, table, -1, SQLITE_TRANSIENT_MIGRATION)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private static func metadataValue(_ key: String, in database: OpaquePointer) throws -> String? {
        var statement: OpaquePointer?
        let sql = "SELECT value FROM schema_metadata WHERE key = ? LIMIT 1;"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw StoreError.invalidDatabaseSchemaMetadata
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, key, -1, SQLITE_TRANSIENT_MIGRATION)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let value = sqlite3_column_text(statement, 0) else {
            return nil
        }
        return String(cString: value)
    }
}

private let SQLITE_TRANSIENT_MIGRATION = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
