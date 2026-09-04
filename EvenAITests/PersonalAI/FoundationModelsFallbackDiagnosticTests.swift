import Testing
import Foundation
@testable import EvenAI

/// Verifies the content-free Foundation Models tier diagnostic in
/// `OnDevicePersonalAIModelProvider`. Since the provider router
/// (`FallbackPersonalAIModelProvider`) took over fallback, this type no
/// longer swallows a failure into a heuristic answer itself — it logs and
/// **rethrows**, so this suite tests exactly that: a failure is both
/// diagnosed (content-free) and propagated, not silently absorbed.
///
/// Exercised through the **real** provider (no test override): Simulator
/// has no on-device Apple Intelligence model, so
/// `SystemLanguageModel.default.availability` is `.unavailable` there too
/// — the exact same failure path a physical device without Apple
/// Intelligence hits is reachable here, end to end, through production
/// code, not a mock.
@Suite("Personal AI: Foundation Models tier diagnostic")
struct FoundationModelsFallbackDiagnosticTests {

    @Test("a real on-device generate() failure logs a content-free PERSONAL_AI_FM_PROVIDER diagnostic and rethrows rather than answering")
    @MainActor
    func fmTierDiagnosticIsContentFreeAndRethrows() async throws {
        let distinctiveUserText = "ZebraQuokkaMarmoset what is my name"
        let distinctiveMemory = "PlatypusOcelotFlamingo the user's name is Oleg"
        let distinctivePrompt = "Known facts about the user — the user is asking about themselves"

        let context = PersonalAIContext(
            activeRules: [], relevantMemories: [], relevantProjects: [], relevantPeople: [],
            historicalExcerpts: [], styleInstructions: "",
            systemPromptText: "\(distinctivePrompt): \(distinctiveMemory)",
            memoryDisabled: false, buildTrace: ["retrieved=1/1", "knownProfile=1"]
        )

        let provider = OnDevicePersonalAIModelProvider()
        var thrown: Error?
        let captured = await StdoutCapture.capture {
            do {
                _ = try await provider.generate(PersonalAIGenerationRequest(
                    personalContext: context, messages: [], userMessage: distinctiveUserText
                ))
            } catch {
                thrown = error
            }
        }

        // The on-device tier alone no longer falls back — it fails loudly
        // (the router, tested separately, is what recovers from this).
        #expect(thrown != nil)

        // The diagnostic fired with the required, content-free shape. Which
        // of the two stages fires depends on the runtime's on-device model
        // asset state (not something a test should hardcode) — either is a
        // correct, informative outcome.
        #expect(captured.contains("PERSONAL_AI_FM_PROVIDER"))
        #expect(captured.contains("provider=onDeviceFoundationModel"))
        #expect(
            captured.contains("failureStage=availabilityCheck")
            || captured.contains("failureStage=sessionRespond")
        )
        #expect(captured.contains("availability="))
        #expect(captured.contains("underlyingErrorType="))
        #expect(captured.contains("mappedError="))

        // Never the user's message, the memory, or the assembled prompt.
        #expect(captured.contains(distinctiveUserText) == false)
        #expect(captured.contains(distinctiveMemory) == false)
        #expect(captured.contains(distinctivePrompt) == false)
        #expect(captured.contains("Oleg") == false)
    }
}
