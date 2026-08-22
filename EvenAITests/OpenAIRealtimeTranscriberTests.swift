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
    private static let propagationDelay: Duration = .milliseconds(30)

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
            for try await value in finals { received.append(value) }
        }

        let sockets = await factory.createdSockets
        #expect(sockets.count == 1)
        await sockets[0].emit(.finalTranscript("Guten Tag"))
        try? await Task.sleep(for: Self.propagationDelay)

        #expect(received == ["Guten Tag"])
        collectTask.cancel()
    }

    @Test("partial transcripts are filtered out — only finals are yielded")
    func partialsAreFiltered() async throws {
        let factory = FakeRealtimeTranscriptionSocketFactory()
        let transcriber = makeTranscriber(factory)
        let (pcmStream, _) = AsyncStream<Data>.makeStream()

        let finals = try await transcriber.startTranscribing(pcmUpdates: pcmStream)
        var received: [String] = []
        let collectTask = Task {
            for try await value in finals { received.append(value) }
        }

        let socket = await factory.createdSockets[0]
        await socket.emit(.partialTranscript("Guten Ta"))
        await socket.emit(.partialTranscript("Guten Tag jetzt"))
        await socket.emit(.finalTranscript("Guten Tag"))
        try? await Task.sleep(for: Self.propagationDelay)

        #expect(received == ["Guten Tag"])
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
            for try await value in finals { received.append(value) }
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
            for try await value in finals { received.append(value) }
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
                for try await value in finals { received.append(value) }
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
                for try await value in finals { received.append(value) }
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
