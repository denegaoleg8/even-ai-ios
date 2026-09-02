import Testing
import Foundation
@testable import EvenAI

/// PHASE 3 — Slice 3: production composition / wiring.
///
/// The enriching decorator is injected through the SAME `SuggestedReplyGenerating`
/// parameter `AIConversationEngine` already takes; it is constructed from the
/// local `PersonalAIContainer.live` (`.notConfigured` — no CloudKit, no R2, no
/// network) and degrades to the base local generator on every failure.
@Suite("Phase 3: G2 reply enrichment — composition")
struct PersonalAIG2ReplyEnrichmentCompositionTests {

    private func repoFile(_ rel: String) -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return (try? String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)) ?? ""
    }

    // MARK: wiring

    @Test("EvenAIApp injects PersonalAIContextEnrichingSuggestedReplyGenerator wrapping LocalSuggestedReplyGenerator, through the existing replyGenerator parameter")
    func appWiresTheDecorator() {
        let app = repoFile("EvenAI/App/EvenAIApp.swift").replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\n", with: "")
        #expect(app.contains("replyGenerator:PersonalAIContextEnrichingSuggestedReplyGenerator("))
        #expect(app.contains("base:LocalSuggestedReplyGenerator()"))
        #expect(app.contains("contextBuilder:PersonalAIContainer.live.contextBuilder"))
        #expect(app.contains("ownerID:{PersonalAIContainer.live.ownerBox.ownerID}"))
        // reads the SAME persisted profile key the engine owns — no engine reference
        #expect(app.contains("com.evenai.liveTranslation.conversationProfile"))
    }

    @Test("AIConversationEngine is NOT modified for Phase 3 — it knows nothing about Personal AI")
    func engineUntouched() {
        let engine = repoFile("EvenAI/App/AIConversationEngine.swift")
        for token in ["PersonalAIContext", "PersonalAIContextBuilding", "PersonalMemoryStore",
                      "PersonalAIContainer", "personalAIContext", "PersonalAIReplyEnrichment"] {
            #expect(!engine.contains(token), "AIConversationEngine references \(token)")
        }
    }

    @Test("the G2 transport / glasses code is NOT modified for Phase 3")
    func transportUntouched() {
        for rel in ["EvenAI/Infrastructure/Glasses/MentraGlassesTransport.swift",
                    "EvenAI/App/GlassesChatProvider.swift"] {
            let src = repoFile(rel)
            #expect(!src.contains("PersonalAI"), "\(rel) references PersonalAI")
        }
    }

    @Test("the decorator itself imports no networking / backend / CloudKit / R2 type")
    func decoratorHasNoCloudDependency() {
        let src = repoFile("EvenAI/Infrastructure/PersonalAI/PersonalAIReplyEnrichment.swift")
        for token in ["URLSession", "URLRequest", "AuthenticatedAPIClient", "import CloudKit",
                      "CKContainer", "R2BackupStore", "BackupObjectTransport", "Railway",
                      "NetworkSuggestedReplyGenerator", "import Network"] {
            #expect(!src.contains(token), "decorator references \(token)")
        }
    }

    // MARK: constructs + runs with the shipping local state

    @Test("the decorator constructs from PersonalAIContainer.live (.notConfigured) and produces replies")
    func constructsFromLiveContainer() async throws {
        #expect(PersonalAIContainer.live.cloudEnvironment == .notConfigured)

        let baseReplies = [SuggestedReply(originalLanguageText: "OK.", ukrainianText: "Добре.", ordering: 0)]
        let sut = PersonalAIContextEnrichingSuggestedReplyGenerator(
            base: FakeSuggestedReplyGenerator(defaultReplies: baseReplies),
            contextBuilder: PersonalAIContainer.live.contextBuilder,
            ownerID: { PersonalAIContainer.live.ownerBox.ownerID },
            conversationProfile: { .auto }
        )
        let turn = ConversationTurn.liveConversationTurn(originalText: "hello there", detectedLanguage: "en-US", ukrainianTranslation: "привіт")
        let out = try await sut.generateReplies(for: turn, context: SuggestedReplyContext())
        #expect(out == baseReplies)   // no CloudKit / R2 / network needed
    }

    @Test("the real production base generator, wrapped, still returns replies-or-LocalReplyUnavailableError only")
    func wrappedRealBaseStaysContractual() async {
        let sut = PersonalAIContextEnrichingSuggestedReplyGenerator(
            base: LocalSuggestedReplyGenerator(),
            contextBuilder: PersonalAIContainer.live.contextBuilder,
            ownerID: { nil },                              // anonymous — Personal AI still works locally
            conversationProfile: { .conversation }
        )
        let turn = ConversationTurn.liveConversationTurn(originalText: "Do you want to grab lunch?", detectedLanguage: "en-US", ukrainianTranslation: "…")
        do {
            let out = try await sut.generateReplies(for: turn, context: SuggestedReplyContext())
            #expect(out.count <= 3)
            #expect(!out.isEmpty)   // LightweightLocalReplyGenerator always answers an invitation
        } catch is LocalReplyUnavailableError {
            // acceptable — the FoundationModels tier can be unavailable
        } catch is CancellationError {
            Issue.record("should not cancel")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    // MARK: profile-guidance mapping (the renderer, directly)

    @Test("profile guidance maps every ConversationProfile case")
    func profileGuidanceMapping() {
        #expect(PersonalAIReplyContextRenderer.profileGuidance(for: .conversation).localizedCaseInsensitiveContains("one-to-one"))
        #expect(PersonalAIReplyContextRenderer.profileGuidance(for: .auto).localizedCaseInsensitiveContains("one-to-one"))
        #expect(PersonalAIReplyContextRenderer.profileGuidance(for: .meeting).localizedCaseInsensitiveContains("meeting"))
    }
}
