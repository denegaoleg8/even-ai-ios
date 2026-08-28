import Foundation

/// `BackupStore` that writes sealed backup blobs to a directory — the Phase
/// 2 stand-in for S3 / R2 / GCS. Deliberately a *separate* store from the
/// primary `PersonalCloudService`: a bug or outage in one cannot corrupt the
/// other. A real object-storage conformer is a drop-in replacement; nothing
/// in `PersonalAIBackupCoordinator` changes.
///
/// Files are named `<ownerHash>/<bundleVersion>-<tier>-<id>.paibak` and are
/// already AES-GCM sealed by the coordinator before they arrive here — this
/// type never sees plaintext.
actor LocalDirectoryBackupStore: BackupStore {

    private let root: URL

    init(directory: URL? = nil) {
        let base = directory ?? {
            let fm = FileManager.default
            let dir = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
                ?? fm.temporaryDirectory
            return dir.appendingPathComponent("PersonalAI/Backups", isDirectory: true)
        }()
        self.root = base
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    private func ownerDir(_ ownerID: String) -> URL {
        let hashed = ownerID.data(using: .utf8).map { String($0.map { String(format: "%02x", $0) }.joined().prefix(16)) } ?? "local"
        let dir = root.appendingPathComponent(hashed, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func fileURL(_ handle: BackupHandle, ownerID: String) -> URL {
        ownerDir(ownerID).appendingPathComponent("\(handle.bundleVersion)-\(handle.tier)-\(handle.id).paibak")
    }

    private let manifestName = "_manifests.json"

    private func manifests(_ ownerID: String) -> [BackupHandle] {
        let url = ownerDir(ownerID).appendingPathComponent(manifestName)
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder.personalAI.decode([BackupHandle].self, from: data) else { return [] }
        return list
    }

    private func writeManifests(_ list: [BackupHandle], ownerID: String) {
        let url = ownerDir(ownerID).appendingPathComponent(manifestName)
        if let data = try? JSONEncoder.personalAI.encode(list) {
            try? data.write(to: url, options: [.atomic])
        }
    }

    func putBackup(_ sealed: Data, handle: BackupHandle, ownerID: String) async throws {
        try sealed.write(to: fileURL(handle, ownerID: ownerID), options: [.atomic, .completeFileProtection])
        var list = manifests(ownerID).filter { $0.id != handle.id }
        list.append(handle)
        writeManifests(list, ownerID: ownerID)
    }

    func listBackups(ownerID: String) async throws -> [BackupHandle] {
        manifests(ownerID).sorted { $0.createdAt > $1.createdAt }
    }

    func getBackup(_ handle: BackupHandle, ownerID: String) async throws -> Data {
        try Data(contentsOf: fileURL(handle, ownerID: ownerID))
    }

    func deleteBackup(_ handle: BackupHandle, ownerID: String) async throws {
        try? FileManager.default.removeItem(at: fileURL(handle, ownerID: ownerID))
        writeManifests(manifests(ownerID).filter { $0.id != handle.id }, ownerID: ownerID)
    }
}
