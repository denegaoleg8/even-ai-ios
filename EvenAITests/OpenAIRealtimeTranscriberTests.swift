import Testing
import Foundation
@testable import EvenAI

/// Milestone 8a: `OpenAIRealtimeTranscriber`'s orchestration contract —
/// entirely against `FakeRealtimeTranscriptionSocket`, never a real
/// network connection. Not wired into `LiveTranslationService`/production
/// anywhere yet; these tests cover this type in isolation, the same way
/// `GlassesSpeechTranscriber` itself has no equivalent direct-unit-test
/// file (it's exercised through `LiveTranslationServiceTests` instead) —
/// except here we *can* unit test directly, since
/// `RealtimeTranscriptionSocket` is a seam `GlassesSpeechTranscriber`
/// never had (no fake `SFSpeechRecognizer`).
@MainActor
@Suite("OpenAIRealtimeTranscriber")
struct OpenAIRealtimeTranscriberTests {
    private static let propagationDelay: Duration = .milliseconds(200)

    private func makeTranscriber(_ factory: FakeRealtimeTranscriptionSocketFactory) -> ContinuousTranscribing {
        // Typed as the protocol itself — this is also the
        // "ContinuousTranscribing conformance" test: it only compiles
        // because OpenAIRealtimeTranscriber actually satisfies it.
        OpenAIRealtimeTranscriber(makeSocket: { await factory.makeSocket() })
    }

    @Test("starts a connection through the socket factory and yields finals")
    func startsAndYieldsFinals() async throws {
        let factory = FakeRealtimeTranscriptionSocketFactory()
        let transcriber = makeTranscriber(factory)
        let (pcmStream, _) = AsyncStream<Data>.makeStream()

        let finals = try await transcriber.startTranscribing(pcmUpdates: pcmStream)
        var received: [String] = []
        let collectTask = Task {
            for try await value in finals {
                if case .final(let text) = value { received.append(text) }
            }
        }

        let sockets = await factory.createdSockets
        #expect(sockets.count == 1)
        await sockets[0].emit(.finalTranscript("Guten Tag"))
        try? await Task.sleep(for: Self.propagationDelay)

        #expect(received == ["Guten Tag"])
        collectTask.cancel()
    }

    @Test("partial transcripts are yielded as .partial(_:), distinct from and never confused with .final(_:)")
    func partialsAreYieldedDistinctlyFromFinals() async throws {
        let factory = FakeRealtimeTranscriptionSocketFactory()
        let transcriber = makeTranscriber(factory)
        let (pcmStream, _) = AsyncStream<Data>.makeStream()

        let updates = try await transcriber.startTranscribing(pcmUpdates: pcmStream)
        var received: [TranscriptionUpdate] = []
        let collectTask = Task {
            for try await value in updates { received.append(value) }
        }

        let socket = await factory.createdSockets[0]
        await socket.emit(.partialTranscript("Guten Ta"))
        await socket.emit(.partialTranscript("Guten Tag jetzt"))
        await socket.emit(.finalTranscript("Guten Tag"))
        try? await Task.sleep(for: Self.propagationDelay)

        #expect(received == [
            .partial("Guten Ta"),
            .partial("Guten Tag jetzt"),
            .final("Guten Tag"),
        ])
        collectTask.cancel()
    }

    @Test("language info is captured but never yielded through the output stream")
    func languageInfoIsCapturedNotYielded() async throws {
        let factory = FakeRealtimeTranscriptionSocketFactory()
        guard let transcriber = makeTranscriber(factory) as? OpenAIRealtimeTranscriber else {
            Issue.record("expected a concrete OpenAIRealtimeTranscriber")
            return
        }
        let (pcmStream, _) = AsyncStream<Data>.makeStream()

        let finals = try await transcriber.startTranscribing(pcmUpdates: pcmStream)
        var received: [String] = []
        let collectTask = Task {
            for try await value in finals {
                if case .final(let text) = value { received.append(text) }
            }
        }

        let socket = await factory.createdSockets[0]
        await socket.emit(.languageInfo(["de"]))
        await socket.emit(.finalTranscript("Guten Tag"))
        try? await Task.sleep(for: Self.propagationDelay)

        #expect(transcriber.lastKnownLanguages == ["de"])
        #expect(received == ["Guten Tag"]) // language_info never itself becomes a yielded value
        collectTask.cancel()
    }

    @Test("stopTranscribing closes the socket and ends the stream, yielding nothing further")
    func stopClosesSocketAndEndsStream() async throws {
        let factory = FakeRealtimeTranscriptionSocketFactory()
        let transcriber = makeTranscriber(factory)
        let (pcmStream, _) = AsyncStream<Data>.makeStream()

        let finals = try await transcriber.startTranscribing(pcmUpdates: pcmStream)
        var received: [String] = []
        var finished = false
        let collectTask = Task {
            for try await value in finals {
                if case .final(let text) = value { received.append(text) }
            }
            finished = true
        }

        let socket = await factory.createdSockets[0]
        await transcriber.stopTranscribing()
        try? await Task.sleep(for: Self.propagationDelay)

        #expect(await socket.isClosed)
        #expect(finished)
        #expect(received.isEmpty)

        // A late event on the now-stopped socket must never resurrect the
        // finished stream.
        await socket.emit(.finalTranscript("too late"))
        try? await Task.sleep(for: Self.propagationDelay)
        #expect(received.isEmpty)

        collectTask.cancel()
    }

    @Test("a provider error event does not end the stream — later finals still arrive")
    func providerErrorIsNonFatal() async throws {
        let factory = FakeRealtimeTranscriptionSocketFactory()
        let transcriber = makeTranscriber(factory)
        let (pcmStream, _) = AsyncStream<Data>.makeStream()

        let finals = try await transcriber.startTranscribing(pcmUpdates: pcmStream)
        var received: [String] = []
        var threw = false
        let collectTask = Task {
            do {
                for try await value in finals {
                    if case .final(let text) = value { received.append(text) }
                }
            } catch {
                threw = true
            }
        }

        let socket = await factory.createdSockets[0]
        await socket.emit(.providerError("upstream boom"))
        await socket.emit(.finalTranscript("still works"))
        try? await Task.sleep(for: Self.propagationDelay)

        #expect(received == ["still works"])
        #expect(!threw)
        collectTask.cancel()
    }

    @Test("an unexpected close reconnects once and resumes yielding finals from the new socket")
    func reconnectsOnceAndResumes() async throws {
        let factory = FakeRealtimeTranscriptionSocketFactory()
        let transcriber = makeTranscriber(factory)
        let (pcmStream, _) = AsyncStream<Data>.makeStream()

        let finals = try await transcriber.startTranscribing(pcmUpdates: pcmStream)
        var received: [String] = []
        var threw = false
        let collectTask = Task {
            do {
                for try await value in finals {
                    if case .final(let text) = value { received.append(text) }
                }
            } catch {
                threw = true
            }
        }

        let firstSocket = await factory.createdSockets[0]
        await firstSocket.emit(.closed(reason: "network blip"))
        try? await Task.sleep(for: Self.propagationDelay)

        #expect(await factory.createdSockets.count == 2)
        let secondSocket = await factory.createdSockets[1]
        await secondSocket.emit(.finalTranscript("resumed"))
        try? await Task.sleep(for: Self.propagationDelay)

        #expect(received == ["resumed"])
        #expect(!threw)
        collectTask.cancel()
    }

    /// Bounded-reconnect regression test (physical-device "Live
    /// Translation stopped unexpectedly" hardening pass): the OLD policy
    /// gave up after exactly ONE reconnect attempt, so any two blips in a
    /// row — very plausible on a real G2-BLE↔phone↔backend↔OpenAI chain
    /// — ended the whole Live Translation session. The bounded budget
    /// must survive MORE than one consecutive failure before giving up,
    /// not just one.
    @Test("bounded reconnect survives multiple consecutive drops within its budget, not just one")
    func boundedReconnectSurvivesMultipleConsecutiveDrops() async throws {
        let factory = FakeRealtimeTranscriptionSocketFactory()
        let transcriber = OpenAIRealtimeTranscriber(
            makeSocket: { await factory.makeSocket() },
            maxConsecutiveReconnectAttempts: 3,
            reconnectBackoffSchedule: [.zero, .zero, .zero]
        )
        let (pcmStream, _) = AsyncStream<Data>.makeStream()

        let finals = try await transcriber.startTranscribing(pcmUpdates: pcmStream)
        var received: [String] = []
        var threw = false
        let collectTask = Task {
            do {
                for try await value in finals {
                    if case .final(let text) = value { received.append(text) }
                }
            } catch {
                threw = true
            }
        }

        // Two drops in a row — the OLD "one retry then give up" policy
        // would already have surfaced a fatal error by now.
        await (await factory.createdSockets[0]).emit(.closed(reason: "drop 1"))
        try? await Task.sleep(for: Self.propagationDelay)
        await (await factory.createdSockets[1]).emit(.closed(reason: "drop 2"))
        try? await Task.sleep(for: Self.propagationDelay)

        #expect(await factory.createdSockets.count == 3) // 2 reconnect attempts made, budget of 3 not yet exhausted
        #expect(!threw) // still alive — never gave up after just 2 drops

        // The third connection stays up and keeps working normally.
        await (await factory.createdSockets[2]).emit(.finalTranscript("resumed"))
        try? await Task.sleep(for: Self.propagationDelay)

        #expect(received == ["resumed"])
        #expect(!threw)
        collectTask.cancel()
    }

    @Test("the bounded reconnect budget still exhausts and ends the stream with an error once every attempt fails")
    func boundedReconnectExhaustsAfterBudget() async throws {
        let factory = FakeRealtimeTranscriptionSocketFactory()
        let transcriber = OpenAIRealtimeTranscriber(
            makeSocket: { await factory.makeSocket() },
            maxConsecutiveReconnectAttempts: 2,
            reconnectBackoffSchedule: [.zero, .zero]
        )
        let (pcmStream, _) = AsyncStream<Data>.makeStream()

        let finals = try await transcriber.startTranscribing(pcmUpdates: pcmStream)
        var threw = false
        let collectTask = Task {
            do {
                for try await _ in finals {}
            } catch {
                threw = true
            }
        }

        // Three drops in a row: the original connection, plus BOTH
        // attempts in the bounded budget of 2 (each attempt connects
        // successfully before being dropped again — this is testing the
        // budget being exhausted by repeated DROPS, not by repeated
        // connect() failures; see `reconnectConnectFailureExhaustsBudget`
        // for that distinct case) — the budget must exhaust on this
        // third drop, not sooner and not later.
        await (await factory.createdSockets[0]).emit(.closed(reason: "drop 1"))
        try? await Task.sleep(for: Self.propagationDelay)
        await (await factory.createdSockets[1]).emit(.closed(reason: "drop 2"))
        try? await Task.sleep(for: Self.propagationDelay)
        await (await factory.createdSockets[2]).emit(.closed(reason: "drop 3"))
        try? await Task.sleep(for: Self.propagationDelay)

        #expect(await factory.createdSockets.count == 3) // 2 reconnect attempts made, no third — budget was 2
        #expect(threw)
        collectTask.cancel()
    }

    @Test("PCM fed into the input stream is forwarded to the current socket")
    func pcmIsForwarded() async throws {
        let factory = FakeRealtimeTranscriptionSocketFactory()
        let transcriber = makeTranscriber(factory)
        let (pcmStream, pcmContinuation) = AsyncStream<Data>.makeStream()

        let finals = try await transcriber.startTranscribing(pcmUpdates: pcmStream)
        // Held and iterated (even though this test doesn't care about
        // its values) — an unconsumed, unretained AsyncThrowingStream can
        // fire `onTermination` on deinit, which would cancel
        // pcmConsumerTask before it ever forwards anything.
        let collectTask = Task {
            for try await _ in finals {}
        }
        let chunk = Data([1, 2, 3, 4])
        pcmContinuation.yield(chunk)
        try? await Task.sleep(for: Self.propagationDelay)

        let socket = await factory.createdSockets[0]
        #expect(await socket.sentPCM == [chunk])
        collectTask.cancel()
    }

    /// Regression test for a real bug found auditing reconnect behavior
    /// (Conversation Mode follow-up, Section 4): the one long-lived PCM-
    /// forwarding task is created exactly once, in `startTranscribing`,
    /// and is deliberately never recreated on reconnect (see
    /// `buildStream(from:pcmUpdates:socket:)`'s own doc comment for why
    /// running a second consumer over the same `AsyncStream` concurrently
    /// would be unsafe) — it used to keep routing every chunk to the
    /// FIRST socket's `sendPCM(_:)`, captured once and never updated, so
    /// after any reconnect the new socket's event stream could still
    /// yield transcripts (as `reconnectsOnceAndResumes` above proves) but
    /// the backend would never receive another byte of audio to
    /// transcribe from — a real "recovery" gap this specific test now
    /// closes.
    @Test("PCM sent after a reconnect is forwarded to the NEW socket, not the closed original one")
    func pcmAfterReconnectRoutesToNewSocket() async throws {
        let factory = FakeRealtimeTranscriptionSocketFactory()
        let transcriber = makeTranscriber(factory)
        let (pcmStream, pcmContinuation) = AsyncStream<Data>.makeStream()

        let finals = try await transcriber.startTranscribing(pcmUpdates: pcmStream)
        let collectTask = Task {
            for try await _ in finals {}
        }

        let beforeReconnectChunk = Data([1, 2, 3])
        pcmContinuation.yield(beforeReconnectChunk)
        try? await Task.sleep(for: Self.propagationDelay)

        let firstSocket = await factory.createdSockets[0]
        #expect(await firstSocket.sentPCM == [beforeReconnectChunk])

        await firstSocket.emit(.closed(reason: "network blip"))
        try? await Task.sleep(for: Self.propagationDelay)
        #expect(await factory.createdSockets.count == 2)
        let secondSocket = await factory.createdSockets[1]

        let afterReconnectChunk = Data([4, 5, 6])
        pcmContinuation.yield(afterReconnectChunk)
        try? await Task.sleep(for: Self.propagationDelay)

        #expect(await secondSocket.sentPCM == [afterReconnectChunk])
        // The original socket never receives anything past the moment
        // it closed — no chunk is silently lost into the void, and none
        // is duplicated onto the wrong socket either.
        #expect(await firstSocket.sentPCM == [beforeReconnectChunk])
        collectTask.cancel()
    }

    @Test("a connect() failure on ONE reconnect attempt retries again within the bounded budget, not an immediate stall or give-up")
    func reconnectConnectFailureRetriesWithinBudget() async throws {
        var callCount = 0
        var createdSockets: [FakeRealtimeTranscriptionSocket] = []
        let transcriber = OpenAIRealtimeTranscriber(
            makeSocket: {
                callCount += 1
                let socket = FakeRealtimeTranscriptionSocket()
                if callCount == 2 {
                    // Only the SECOND socket (the first reconnect
                    // attempt) fails to connect — the third (second
                    // attempt) succeeds normally.
                    await socket.failNextConnect(with: FakeError(message: "reconnect refused"))
                }
                createdSockets.append(socket)
                return socket
            },
            maxConsecutiveReconnectAttempts: 3,
            reconnectBackoffSchedule: [.zero, .zero, .zero]
        )
        let (pcmStream, _) = AsyncStream<Data>.makeStream()

        let finals = try await transcriber.startTranscribing(pcmUpdates: pcmStream)
        var received: [String] = []
        var threw = false
        let collectTask = Task {
            do {
                for try await value in finals {
                    if case .final(let text) = value { received.append(text) }
                }
            } catch {
                threw = true
            }
        }

        await createdSockets[0].emit(.closed(reason: "network blip"))
        try? await Task.sleep(for: Self.propagationDelay)

        #expect(callCount == 3) // attempt 1's connect() failed; attempt 2 was tried next automatically
        #expect(!threw) // never gave up after a single failed connect()

        await createdSockets[2].emit(.finalTranscript("resumed"))
        try? await Task.sleep(for: Self.propagationDelay)

        #expect(received == ["resumed"])
        collectTask.cancel()
    }

    @Test("if every reconnect attempt's connect() fails, the bounded budget still exhausts and surfaces the failure")
    func reconnectConnectFailureExhaustsBudget() async throws {
        var callCount = 0
        var createdSockets: [FakeRealtimeTranscriptionSocket] = []
        let transcriber = OpenAIRealtimeTranscriber(
            makeSocket: {
                callCount += 1
                let socket = FakeRealtimeTranscriptionSocket()
                if callCount > 1 {
                    // Every reconnect attempt's own socket fails to
                    // connect — only the ORIGINAL (first) connection
                    // succeeds.
                    await socket.failNextConnect(with: FakeError(message: "reconnect refused"))
                }
                createdSockets.append(socket)
                return socket
            },
            maxConsecutiveReconnectAttempts: 2,
            reconnectBackoffSchedule: [.zero, .zero]
        )
        let (pcmStream, _) = AsyncStream<Data>.makeStream()

        let finals = try await transcriber.startTranscribing(pcmUpdates: pcmStream)
        var threw = false
        let collectTask = Task {
            do {
                for try await _ in finals {}
            } catch {
                threw = true
            }
        }

        await createdSockets[0].emit(.closed(reason: "network blip"))
        try? await Task.sleep(for: Self.propagationDelay)

        #expect(threw) // both reconnect attempts' connect() calls failed — budget exhausted
        collectTask.cancel()
    }
}
