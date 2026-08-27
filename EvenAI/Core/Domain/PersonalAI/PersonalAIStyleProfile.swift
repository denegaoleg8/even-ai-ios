import Foundation

/// The reusable, surface-agnostic model of how the user wants their Personal
/// AI to communicate. Derived/maintained by `StyleProfileLearner`, projected
/// into every `PersonalAIContext`. Explicit user commands set dimensions at
/// full weight immediately; inferred signals only move a dimension after
/// several corroborating observations (see `StyleDimensionMeta`) so one
/// unusual message can't permanently reshape the voice.
struct PersonalAIStyleProfile: Codable, Hashable, Sendable {
    enum ResponseLength: String, Codable, Hashable, Sendable, CaseIterable {
        case short, medium, long, unspecified
    }
    enum Formatting: String, Codable, Hashable, Sendable, CaseIterable {
        case prose, bullets, unspecified
    }

    var preferredLanguage: String?          // BCP-47, e.g. "uk"
    var responseLength: ResponseLength
    var directness: Double?                 // 0 = gentle/indirect … 1 = blunt
    var formality: Double?                  // 0 = casual … 1 = formal
    var technicalDepth: Double?             // 0 = layman … 1 = deep technical
    var proactiveness: Double?              // 0 = answer only … 1 = suggest next steps
    var humor: Double?                      // 0 = none … 1 = playful
    var formatting: Formatting
    var preferredVocabulary: [String]
    var phrasesToAvoid: [String]

    /// Per-dimension evidence, keyed by a stable dimension name
    /// ("directness", "responseLength", …). Absence means "never observed".
    var evidence: [String: StyleDimensionMeta]

    var updatedAt: Date

    init(
        preferredLanguage: String? = nil,
        responseLength: ResponseLength = .unspecified,
        directness: Double? = nil,
        formality: Double? = nil,
        technicalDepth: Double? = nil,
        proactiveness: Double? = nil,
        humor: Double? = nil,
        formatting: Formatting = .unspecified,
        preferredVocabulary: [String] = [],
        phrasesToAvoid: [String] = [],
        evidence: [String: StyleDimensionMeta] = [:],
        updatedAt: Date = .now
    ) {
        self.preferredLanguage = preferredLanguage
        self.responseLength = responseLength
        self.directness = directness
        self.formality = formality
        self.technicalDepth = technicalDepth
        self.proactiveness = proactiveness
        self.humor = humor
        self.formatting = formatting
        self.preferredVocabulary = preferredVocabulary
        self.phrasesToAvoid = phrasesToAvoid
        self.evidence = evidence
        self.updatedAt = updatedAt
    }

    static let empty = PersonalAIStyleProfile()

    /// Whether anything has been learned/set — the context builder skips the
    /// whole style block when this is false.
    var hasSignal: Bool {
        preferredLanguage != nil
            || responseLength != .unspecified
            || formatting != .unspecified
            || directness != nil || formality != nil || technicalDepth != nil
            || proactiveness != nil || humor != nil
            || !preferredVocabulary.isEmpty || !phrasesToAvoid.isEmpty
    }
}

/// Evidence backing one style dimension. `source == .explicitCommand` short-
/// circuits the observation gate — the user told us directly.
struct StyleDimensionMeta: Codable, Hashable, Sendable {
    var source: MemorySource
    var confidence: Double
    var observationCount: Int
    var updatedAt: Date

    init(source: MemorySource, confidence: Double, observationCount: Int = 1, updatedAt: Date = .now) {
        self.source = source
        self.confidence = confidence
        self.observationCount = observationCount
        self.updatedAt = updatedAt
    }

    /// Inferred dimensions need this many corroborating observations before
    /// they're allowed to change the projected profile.
    static let inferredObservationThreshold = 3

    var isTrusted: Bool {
        source == .explicitCommand || source == .manualEntry || observationCount >= Self.inferredObservationThreshold
    }
}
