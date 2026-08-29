import Testing
import Foundation
@testable import EvenAI

/// The independent-backup layer is provider-neutral: no Cloudflare / R2 / S3
/// type appears in a Personal AI domain model, and production ships dormant.
@Suite("Backup: provider independence")
struct BackupProviderIndependenceTests {

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func swiftFiles(under path: String) -> [URL] {
        let base = repoRoot().appendingPathComponent(path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: base.path, isDirectory: &isDir) else { return [] }
        if !isDir.boolValue { return base.pathExtension == "swift" ? [base] : [] }
        let e = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)
        var out: [URL] = []
        while let url = e?.nextObject() as? URL { if url.pathExtension == "swift" { out.append(url) } }
        return out
    }

    @Test("no Cloudflare / R2 / S3 / AWS SDK symbol appears anywhere in the app target")
    func noProviderSDK() {
        let banned = ["import Cloudflare", "import AWSS3", "import Soto", "import AWSSDK",
                      "CloudflareR2", "S3Client", "AmazonS3"]
        var hits: [String] = []
        for file in swiftFiles(under: "EvenAI") {
            let source = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            for token in banned where source.contains(token) {
                hits.append("\(file.lastPathComponent): \(token)")
            }
        }
        #expect(hits.isEmpty, "provider SDK reference(s): \(hits)")
    }

    @Test("Personal AI domain files don't *use* the concrete backup providers (doc comments in the seam file aside)")
    func domainStaysNeutral() {
        // The seam-definition file may *name* its default conformers in doc
        // comments; every other Core file must not mention them at all.
        let providerTypes = ["R2BackupStore", "URLSessionBackupObjectTransport",
                             "WorkerBackupCredentialProvider", "CompositeBackupStore"]
        for file in swiftFiles(under: "EvenAI/Core") where file.lastPathComponent != "BackupProviderProtocols.swift" {
            let source = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            for type in providerTypes {
                #expect(!source.contains(type), "\(file.lastPathComponent) references \(type)")
            }
        }
        // And even the seam file must not *use* them in code (only doc comments).
        let seam = (try? String(contentsOf: repoRoot().appendingPathComponent("EvenAI/Core/Domain/PersonalAI/BackupProviderProtocols.swift"), encoding: .utf8)) ?? ""
        for line in seam.split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
            for type in providerTypes {
                #expect(!line.contains(type), "seam file uses \(type) in code: \(line)")
            }
        }
    }

    @Test("the domain backup *seams* are protocols and import no provider SDK")
    func seamsAreProtocols() {
        let core = repoRoot().appendingPathComponent("EvenAI/Core/Domain/PersonalAI/BackupProviderProtocols.swift")
        let src = (try? String(contentsOf: core, encoding: .utf8)) ?? ""
        #expect(src.contains("protocol BackupEncryptionProviding"))
        #expect(src.contains("protocol BackupObjectTransport"))
        #expect(src.contains("protocol BackupCredentialProviding"))
        #expect(!src.contains("import CloudKit"))
        // "Cloudflare" appears only in doc comments explaining the boundary —
        // never in an import or a type.
        for line in src.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("import") { #expect(!trimmed.lowercased().contains("cloud")) }
        }
    }

    @Test("production defaults are dormant — nothing about R2 is live")
    func productionDefaultsDormant() async {
        #expect(NotConfiguredBackupCredentialProvider().isConfigured == false)
        let dormant = DormantBackupObjectTransport()
        await #expect(throws: BackupTransportError.self) {
            _ = try await dormant.get(URL(string: "https://example.com")!)
        }
        // PersonalAIContainer.live still uses the on-device LocalDirectoryBackupStore.
        let containerSrc = (try? String(contentsOf: repoRoot().appendingPathComponent("EvenAI/App/DI/PersonalAIContainer.swift"), encoding: .utf8)) ?? ""
        #expect(containerSrc.contains("LocalDirectoryBackupStore()"))
        #expect(!containerSrc.contains("R2BackupStore"))
        #expect(!containerSrc.contains("WorkerBackupCredentialProvider"))
    }

    @Test("R2BackupStore conforms to the unchanged BackupStore seam")
    func r2ConformsToSeam() {
        let _: any BackupStore = R2BackupStore.dormant
        let _: any BackupStore = CompositeBackupStore(primary: R2BackupStore.dormant)
    }
}
