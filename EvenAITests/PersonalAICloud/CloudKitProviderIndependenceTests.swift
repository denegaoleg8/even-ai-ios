import Testing
import Foundation
@testable import EvenAI

/// CloudKit is a storage adapter, nothing more. The canonical domain model,
/// the proven AI Conversation / Voice / Glasses paths, and the in-process
/// simulated cloud must all be untouched.
@MainActor
@Suite("CloudKit: provider independence")
struct CloudKitProviderIndependenceTests {

    /// Source files that must never import CloudKit.
    private static let cloudKitFreePaths: [String] = [
        "EvenAI/Core",
        "EvenAI/Infrastructure/PersonalAI/MemoryMerger.swift",
        "EvenAI/Infrastructure/PersonalAI/PersonalConflictResolver.swift",
        "EvenAI/Infrastructure/PersonalAI/PersonalAISyncEngine.swift",
        "EvenAI/Infrastructure/PersonalAI/PersonalDataExporter.swift",
        "EvenAI/Infrastructure/PersonalAI/PersonalDataImporter.swift",
        "EvenAI/Infrastructure/PersonalAI/LocalPersonalDataStore.swift",
        "EvenAI/Infrastructure/Voice",
        "EvenAI/Infrastructure/Glasses",
        "EvenAI/Infrastructure/Chat",
        "EvenAI/Features/Voice",
        "EvenAI/Features/Glasses",
        "EvenAI/Features/Conversations",
    ]

    private func repoRoot() -> URL {
        // .../EvenAITests/PersonalAICloud/<thisFile> → repo root is 3 up.
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func swiftFiles(under relativePath: String) -> [URL] {
        let base = repoRoot().appendingPathComponent(relativePath)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: base.path, isDirectory: &isDir) else { return [] }
        if !isDir.boolValue { return base.pathExtension == "swift" ? [base] : [] }
        let e = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)
        var out: [URL] = []
        while let url = e?.nextObject() as? URL {
            if url.pathExtension == "swift" { out.append(url) }
        }
        return out
    }

    @Test("canonical domain + proven runtime paths do not import CloudKit")
    func noCloudKitImportsWhereForbidden() throws {
        var offenders: [String] = []
        for path in Self.cloudKitFreePaths {
            for file in swiftFiles(under: path) {
                let source = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
                if source.contains("import CloudKit") {
                    offenders.append(file.lastPathComponent)
                }
            }
        }
        #expect(offenders.isEmpty, "these files import CloudKit but must not: \(offenders)")
    }

    @Test("AIConversationEngine has no CloudKit / Personal AI cloud coupling")
    func aiConversationEngineUntouched() throws {
        let file = repoRoot().appendingPathComponent("EvenAI/Infrastructure/Chat/AIConversationEngine.swift")
        let source = try? String(contentsOf: file, encoding: .utf8)
        if let source {
            #expect(!source.contains("import CloudKit"))
            #expect(!source.contains("CloudKitPersonalCloudService"))
            #expect(!source.contains("PersonalCloudService"))
        }
    }

    @Test("only the CloudKit adapter directory imports CloudKit in the app target")
    func cloudKitConfinedToAdapterDirectory() {
        let appSources = swiftFiles(under: "EvenAI")
        let importers = appSources
            .filter { ((try? String(contentsOf: $0, encoding: .utf8)) ?? "").contains("import CloudKit") }
            .map { $0.deletingLastPathComponent().lastPathComponent }
        #expect(Set(importers).isSubset(of: ["CloudKit"]),
                "CloudKit imported outside Infrastructure/PersonalAI/CloudKit: \(importers)")
    }

    @Test("the in-process simulated cloud still works end to end")
    func simulatedCloudStillWorks() async {
        let harness = await PersonalCloudHarness(ownerID: "sim-user")
        await harness.memoryStore.upsert([MemoryRecord.fixture("simulated fact")])
        let outcome = await harness.syncEngine.sync()
        #expect(outcome.isSuccess)
        #expect(await harness.backend.recordCount(ownerID: "sim-user") >= 1)
    }

    @Test("PersonalAIContainer.live is still .notConfigured — CloudKit is not wired as production default")
    func productionStillNotConfigured() {
        let container = PersonalAIContainer.live
        #expect(container.cloudEnvironment == .notConfigured)
        #expect(container.cloudService == nil)
    }

    @Test("CloudKitPersonalCloudService satisfies the unchanged PersonalCloudService contract")
    func adapterConformsToSeam() async {
        let db = FakeCloudKitDatabase()
        let service: any PersonalCloudService = CloudKitPersonalCloudService(
            database: db,
            stateStore: InMemoryCloudKitAdapterStateStore(),
            personalAIUserID: { "u" }
        )
        // The four seam methods exist and are callable (bind on first use).
        let pull = try? await service.pull(ownerID: "u", since: nil)
        #expect(pull != nil)
    }

    @Test("LiveCloudKitDatabaseFacade is dormant — instantiated nowhere in App composition")
    func liveFacadeDormant() {
        let appComposition = swiftFiles(under: "EvenAI/App")
            + swiftFiles(under: "EvenAI/Infrastructure/PersonalAI/CloudKit")
        var instantiations: [String] = []
        for file in appComposition {
            let source = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            // The type may be *defined* (its own file) but must not be
            // *constructed* anywhere in the composition path.
            if source.contains("LiveCloudKitDatabaseFacade(") ,
               !file.lastPathComponent.contains("LiveCloudKitDatabaseFacade") {
                instantiations.append(file.lastPathComponent)
            }
        }
        #expect(instantiations.isEmpty, "LiveCloudKitDatabaseFacade constructed in: \(instantiations)")
    }

    @Test("no CloudKit container / account access is wired into PersonalAIContainer")
    func containerHasNoCloudKitWiring() throws {
        let file = repoRoot().appendingPathComponent("EvenAI/App/DI/PersonalAIContainer.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        #expect(!source.contains("import CloudKit"))
        #expect(!source.contains("CKContainer"))
        #expect(!source.contains("LiveCloudKitDatabaseFacade("))
        #expect(!source.contains("CloudKitPersonalCloudService("))
    }
}
