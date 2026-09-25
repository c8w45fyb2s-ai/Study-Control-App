import Foundation

// MARK: - 存储位置（可注入）

/// 快照文件位置与备份命名规则。
///
/// 路径可注入，测试必须使用 `isolatedTemporary()` 之类的独立目录，
/// 绝不读写用户真实的 `store.json`。
struct SnapshotStoreLocation: Hashable, Sendable {
    var directory: URL
    var storeFileName: String
    var backupFileNamePrefix: String
    var backupFileExtension: String
    var quarantineDirectoryName: String
    var maximumBackupCount: Int

    init(
        directory: URL,
        storeFileName: String = "store.json",
        backupFileNamePrefix: String = "store.backup.",
        backupFileExtension: String = "json",
        quarantineDirectoryName: String = "quarantine",
        maximumBackupCount: Int = SnapshotFileStore.maxBackupCount
    ) {
        self.directory = directory
        self.storeFileName = storeFileName
        self.backupFileNamePrefix = backupFileNamePrefix
        self.backupFileExtension = backupFileExtension
        self.quarantineDirectoryName = quarantineDirectoryName
        self.maximumBackupCount = max(1, maximumBackupCount)
    }

    var storeURL: URL { directory.appendingPathComponent(storeFileName) }

    var quarantineDirectoryURL: URL {
        directory.appendingPathComponent(quarantineDirectoryName, isDirectory: true)
    }

    func backupURL(index: Int) -> URL {
        directory.appendingPathComponent("\(backupFileNamePrefix)\(index).\(backupFileExtension)")
    }

    /// 正式 App 的位置（Application Support/StudyCompanion）。
    static func applicationSupport(fileManager: FileManager = .default) -> SnapshotStoreLocation {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return SnapshotStoreLocation(directory: base.appendingPathComponent("StudyCompanion", isDirectory: true))
    }

    /// 隔离的临时目录（每个调用得到独立子目录），只用于测试与预览。
    static func isolatedTemporary(
        prefix: String = "StudyCompanionTests",
        fileManager: FileManager = .default
    ) -> SnapshotStoreLocation {
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        return SnapshotStoreLocation(directory: directory)
    }
}

// MARK: - 保存策略

/// 保存策略。
enum SnapshotSavePolicy {
    /// 默认：磁盘上已有文件但无法解码/迁移时拒绝写入，避免覆盖用户数据。
    case protectExistingData
    /// 显式覆盖损坏文件（仅应在用户确认后使用；建议先 `quarantineUnreadableStore()`）。
    case overwriteUnreadableExisting
}

// MARK: - 存储实现

/// 本地快照存储：原子写入 + 轮转备份 + schema 迁移。
///
/// 安全规则：
/// - 磁盘版本高于当前 App 支持的版本 → 抛错，且**绝不写入**（防降级覆盖）。
/// - 磁盘文件存在但无法解码或无法迁移 → 抛错，且**绝不写入**（防覆盖损坏数据）。
/// - 编码后的数据必须能回读并成功迁移，否则拒绝写入（防止写出半成品）。
final class SnapshotFileStore {
    static let maxBackupCount = 5

    let location: SnapshotStoreLocation
    private let fileManager: FileManager

    /// 已被完整校验过的磁盘文件签名（大小 + 修改时间）。
    ///
    /// "拒绝覆盖损坏文件"的检查需要解码一次已有文件；为了不把每次保存都变成
    /// 两次全量解码，这里记住上次校验通过的签名，文件没变就跳过重复校验。
    private struct StoreFileSignature: Equatable {
        var size: UInt64
        var modifiedAt: Date
    }

    private var validatedStoreSignature: StoreFileSignature?

    var storeURL: URL { location.storeURL }

    init(location: SnapshotStoreLocation, fileManager: FileManager = .default) throws {
        self.location = location
        self.fileManager = fileManager
        try fileManager.createDirectory(at: location.directory, withIntermediateDirectories: true)
    }

    convenience init() throws {
        try self.init(location: .applicationSupport())
    }

    convenience init(directory: URL, fileManager: FileManager = .default) throws {
        try self.init(location: SnapshotStoreLocation(directory: directory), fileManager: fileManager)
    }

    // MARK: - 读取

    /// 读取并迁移快照。文件不存在返回 `nil`。
    func load() throws -> StoreSnapshot? {
        try loadWithReport()?.snapshot
    }

    /// 读取并迁移快照，同时返回迁移报告（供 G 记录诊断信息）。
    func loadWithReport() throws -> (snapshot: StoreSnapshot, report: MigrationReport)? {
        guard fileManager.fileExists(atPath: storeURL.path) else { return nil }
        let data = try readData(at: storeURL)
        let result = try decodeAndMigrate(data, path: storeURL.path)
        validatedStoreSignature = storeFileSignature()
        return result
    }

    /// 磁盘上当前的 schema 版本；文件不存在或无法探测时返回 `nil`。
    func storedSchemaVersion() -> Int? {
        guard let data = try? Data(contentsOf: storeURL) else { return nil }
        return Self.probeVersion(in: data)
    }

    // MARK: - 写入

    func save(_ snapshot: StoreSnapshot, policy: SnapshotSavePolicy = .protectExistingData) throws {
        try fileManager.createDirectory(at: location.directory, withIntermediateDirectories: true)

        // 1) 未来版本保护：磁盘上的数据比本 App 新时，一律不写。
        if let onDiskVersion = storedSchemaVersion(), onDiskVersion > StudySchema.currentVersion {
            throw SnapshotStoreError.futureSchemaVersionOnDisk(
                found: onDiskVersion,
                supported: StudySchema.currentVersion
            )
        }

        // 2) 未损坏保护：已有文件解码/迁移失败时不覆盖。
        //    文件签名与上次校验一致时跳过重复解码（避免每次保存都全量解码两次）。
        if policy == .protectExistingData,
           fileManager.fileExists(atPath: storeURL.path),
           storeFileSignature() != validatedStoreSignature {
            let existing = try readData(at: storeURL)
            do {
                _ = try decodeAndMigrate(existing, path: storeURL.path)
                validatedStoreSignature = storeFileSignature()
            } catch {
                throw SnapshotStoreError.existingStoreUnreadable(
                    path: storeURL.path,
                    reason: Self.describe(error)
                )
            }
        }

        // 3) 内存快照不允许声称自己是未来版本。
        guard snapshot.schemaVersion <= StudySchema.currentVersion else {
            throw SnapshotStoreError.snapshotSchemaTooNew(
                found: snapshot.schemaVersion,
                supported: StudySchema.currentVersion
            )
        }

        // 4) 归一化到当前版本后编码，并做回读校验（含迁移）。
        let normalized = snapshot.normalizedToCurrentSchema()
        let data = try encode(normalized)
        do {
            _ = try decodeAndMigrate(data, path: storeURL.path)
        } catch {
            throw SnapshotStoreError.validationFailed(reason: Self.describe(error))
        }

        // 5) 只有全部校验通过后才轮转备份并原子写入。
        rotateBackups()
        do {
            try data.write(to: storeURL, options: .atomic)
        } catch {
            throw SnapshotStoreError.writeFailed(path: storeURL.path, reason: Self.describe(error))
        }
        validatedStoreSignature = storeFileSignature()
    }

    // MARK: - 备份

    func availableBackups() -> [BackupInfo] {
        var backups: [BackupInfo] = []
        for index in 1...location.maximumBackupCount {
            let url = location.backupURL(index: index)
            guard fileManager.fileExists(atPath: url.path) else { continue }
            if let attrs = try? fileManager.attributesOfItem(atPath: url.path),
               let date = attrs[.modificationDate] as? Date {
                backups.append(BackupInfo(index: index, date: date, url: url))
            }
        }
        return backups.sorted { $0.index < $1.index }
    }

    /// 从备份恢复（会迁移到当前 schema，但**不会**自动写回 store.json）。
    func restoreFromBackup(index: Int) throws -> StoreSnapshot {
        let url = location.backupURL(index: index)
        guard fileManager.fileExists(atPath: url.path) else {
            throw SnapshotStoreError.backupNotFound
        }
        let data = try readData(at: url)
        return try decodeAndMigrate(data, path: url.path).snapshot
    }

    /// 兼容入口：返回最近的备份（index 1）。
    func loadRecoverySnapshot() throws -> StoreSnapshot? {
        try? restoreFromBackup(index: 1)
    }

    private func rotateBackups() {
        let oldest = location.backupURL(index: location.maximumBackupCount)
        try? fileManager.removeItem(at: oldest)

        for index in stride(from: location.maximumBackupCount - 1, through: 1, by: -1) {
            let source = location.backupURL(index: index)
            let destination = location.backupURL(index: index + 1)
            if fileManager.fileExists(atPath: source.path) {
                try? fileManager.removeItem(at: destination)
                try? fileManager.moveItem(at: source, to: destination)
            }
        }

        if fileManager.fileExists(atPath: storeURL.path) {
            let destination = location.backupURL(index: 1)
            try? fileManager.removeItem(at: destination)
            try? fileManager.copyItem(at: storeURL, to: destination)
        }
    }

    // MARK: - 导入 / 导出

    func exportSnapshot(_ snapshot: StoreSnapshot, to url: URL) throws {
        let normalized = snapshot.normalizedToCurrentSchema()
        let data = try encode(normalized)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw SnapshotStoreError.writeFailed(path: url.path, reason: Self.describe(error))
        }
    }

    func importSnapshot(from url: URL) throws -> StoreSnapshot {
        let data = try readData(at: url)
        return try decodeAndMigrate(data, path: url.path).snapshot
    }

    // MARK: - 损坏文件隔离

    /// 把无法读取的 store.json 移到隔离目录，返回隔离后的 URL。
    ///
    /// 这是"错误文件不覆盖原数据"的配套恢复手段：先隔离，再由 G 决定是否重建。
    @discardableResult
    func quarantineUnreadableStore(at now: Date = Date()) throws -> URL? {
        guard fileManager.fileExists(atPath: storeURL.path) else { return nil }
        do {
            try fileManager.createDirectory(at: location.quarantineDirectoryURL, withIntermediateDirectories: true)
            let stamp = Int(now.timeIntervalSince1970.rounded())
            let suffix = location.storeFileName.hasSuffix(".json") ? "" : ".json"
            let destination = location.quarantineDirectoryURL
                .appendingPathComponent("quarantined-\(stamp)-\(location.storeFileName)\(suffix)")
            try? fileManager.removeItem(at: destination)
            try fileManager.moveItem(at: storeURL, to: destination)
            return destination
        } catch {
            throw SnapshotStoreError.writeFailed(path: storeURL.path, reason: Self.describe(error))
        }
    }

    // MARK: - 内部

    /// 只探测版本号，避免为了读版本而完整解码。
    private struct SchemaProbe: Decodable {
        var schemaVersion: Int?
    }

    static func probeVersion(in data: Data) -> Int? {
        (try? JSONDecoder().decode(SchemaProbe.self, from: data))?.schemaVersion
    }

    /// 磁盘文件签名；文件不存在时返回 `nil`。
    private func storeFileSignature() -> StoreFileSignature? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: storeURL.path) else { return nil }
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let modifiedAt = attributes[.modificationDate] as? Date ?? Date(timeIntervalSince1970: 0)
        return StoreFileSignature(size: size, modifiedAt: modifiedAt)
    }

    private func readData(at url: URL) throws -> Data {
        do {
            return try Data(contentsOf: url)
        } catch {
            throw SnapshotStoreError.readFailed(path: url.path, reason: Self.describe(error))
        }
    }

    private func encode(_ snapshot: StoreSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            return try encoder.encode(snapshot)
        } catch {
            throw SnapshotStoreError.encodingFailed(reason: Self.describe(error))
        }
    }

    /// 解码 + 迁移。任何一步失败都会抛出可诊断错误，调用方不得继续写入。
    private func decodeAndMigrate(_ data: Data, path: String) throws -> (snapshot: StoreSnapshot, report: MigrationReport) {
        let version = Self.probeVersion(in: data) ?? StudySchema.minimumReadableVersion
        guard version <= StudySchema.currentVersion else {
            throw SnapshotStoreError.futureSchemaVersionOnDisk(
                found: version,
                supported: StudySchema.currentVersion
            )
        }
        let decoded: StoreSnapshot
        do {
            decoded = try JSONDecoder().decode(StoreSnapshot.self, from: data)
        } catch {
            throw SnapshotStoreError.decodingFailed(path: path, reason: Self.describe(error))
        }
        var snapshot = decoded
        do {
            let report = try SnapshotMigrator.migrate(&snapshot)
            return (snapshot, report)
        } catch let migrationError as SnapshotMigrationError {
            throw migrationError
        } catch {
            throw SnapshotStoreError.noMigrationPath(
                from: decoded.schemaVersion,
                to: StudySchema.currentVersion
            )
        }
    }

    static func describe(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        let nsError = error as NSError
        return "\(nsError.domain) \(nsError.code)：\(nsError.localizedDescription)"
    }
}

// MARK: - Backup info

struct BackupInfo: Identifiable {
    var id: Int { index }
    var index: Int
    var date: Date
    var url: URL
}

// MARK: - Errors

enum SnapshotStoreError: LocalizedError {
    case validationFailed(reason: String)
    case backupNotFound
    /// 磁盘数据版本高于当前 App 支持的版本（禁止降级覆盖）。
    case futureSchemaVersionOnDisk(found: Int, supported: Int)
    /// 内存快照自称的版本高于当前 App 支持的版本。
    case snapshotSchemaTooNew(found: Int, supported: Int)
    case decodingFailed(path: String, reason: String)
    case encodingFailed(reason: String)
    /// 已存在的 store.json 无法解码或无法迁移，拒绝覆盖。
    case existingStoreUnreadable(path: String, reason: String)
    case readFailed(path: String, reason: String)
    case writeFailed(path: String, reason: String)
    case noMigrationPath(from: Int, to: Int)

    var errorDescription: String? {
        switch self {
        case .validationFailed(let reason):
            return "数据验证失败：写入前的回读校验未通过（\(reason)），已拒绝保存。"
        case .backupNotFound:
            return "未找到指定的备份文件。"
        case .futureSchemaVersionOnDisk(let found, let supported):
            return "磁盘数据版本 \(found) 高于当前 App 支持的版本 \(supported)，为避免降级覆盖已停止写入。请升级 App。"
        case .snapshotSchemaTooNew(let found, let supported):
            return "待保存的数据版本 \(found) 高于当前 App 支持的版本 \(supported)，已拒绝写入。"
        case .decodingFailed(let path, let reason):
            return "读取失败：\(path) 无法解码（\(reason)）。原文件未被修改。"
        case .encodingFailed(let reason):
            return "编码失败：\(reason)。未写入任何文件。"
        case .existingStoreUnreadable(let path, let reason):
            return "已有数据文件无法读取（\(reason)），为避免覆盖用户数据已拒绝保存。文件位置：\(path)。可先隔离该文件再重建。"
        case .readFailed(let path, let reason):
            return "读取失败：\(path)（\(reason)）。"
        case .writeFailed(let path, let reason):
            return "写入失败：\(path)（\(reason)）。"
        case .noMigrationPath(let from, let to):
            return "没有从数据版本 \(from) 到 \(to) 的迁移路径，已停止加载以避免覆盖原文件。"
        }
    }
}
