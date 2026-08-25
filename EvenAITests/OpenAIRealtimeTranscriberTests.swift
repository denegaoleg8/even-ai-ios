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

    @Test("a second consecutive unexpected close ends the stream with an error, without a third reconnect attempt")
    func secondCloseEndsStream() async throws {
        let factory = FakeRealtimeTranscriptionSocketFactory()
        let transcriber = makeTranscriber(factory)
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

        let firstSocket = await factory.createdSockets[0]
        await firstSocket.emit(.closed(reason: "first drop"))
        try? await Task.sleep(for: Self.propagationDelay)

        let secondSocket = await factory.createdSockets[1]
        await secondSocket.emit(.closed(reason: "second drop"))
        try? await Task.sleep(for: Self.propagationDelay)

        #expect(await factory.createdSockets.count == 2) // no third attempt
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

    @Test("a connect failure on reconnect surfaces as a thrown error, not a silent stall")
    func reconnectConnectFailureSurfaces() async throws {
        let firstSocket = FakeRealtimeTranscriptionSocket()
        let secondSocket = FakeRealtimeTranscriptionSocket()
        await secondSocket.failNextConnect(with: FakeError(message: "reconnect refused"))
        var callCount = 0
        let transcriber = OpenAIRealtimeTranscriber(makeSocket: {
            callCount += 1
            return callCount == 1 ? firstSocket : secondSocket
        })
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

        await firstSocket.emit(.closed(reason: "network blip"))
        try? await Task.sleep(for: Self.propagationDelay)

        #expect(callCount == 2) // the reconnect attempt did happen
        #expect(threw) // ...and its own connect() failure surfaced, not stalled silently
        collectTask.cancel()
    }
}
