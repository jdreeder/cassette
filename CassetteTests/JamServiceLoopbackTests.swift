// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Testing
import Foundation
import Network
import Observation
import SwiftSonic
@testable import Cassette

// MARK: - Stubs

/// Records queue calls on the host's player.
@MainActor
@Observable
private final class RecordingPlayer: PlayerServiceProtocol {
    let state: PlayerState
    private(set) var playedNext: [String] = []
    private(set) var appended: [String] = []
    private(set) var toggles = 0

    init(state: PlayerState) { self.state = state }

    func playNext(_ songs: [DisplayableSong]) async {
        playedNext += songs.map(\.id)
        let insertAt = state.queue.isEmpty ? 0 : state.currentIndex + 1
        state.queue.insert(contentsOf: songs, at: insertAt)
    }
    func addToQueue(_ songs: [DisplayableSong]) async {
        appended += songs.map(\.id)
        state.queue.append(contentsOf: songs)
    }
    func togglePlayPause() async { toggles += 1 }

    func play(tracks: [DisplayableSong], startIndex: Int) async throws {}
    func playShuffled(tracks: [DisplayableSong]) async throws {}
    func resume() async {}
    func pause() async {}
    func stop() async {}
    func skipToNext() async throws {}
    func skipToPrevious() async throws {}
    func seek(to position: TimeInterval) async {}
    func setRepeatMode(_ mode: RepeatMode) async {}
    func toggleShuffle() async {}
    func appendToQueue(_ tracks: [DisplayableSong]) async {}
    func playNext(_ song: DisplayableSong) async { await playNext([song]) }
    func addToQueue(_ song: DisplayableSong) async { await addToQueue([song]) }
    func removeFromQueue(at index: Int) async {}
    func moveInQueue(fromIndex: Int, toIndex: Int) async {}
    func restoreSession() async {}
    func handleNetworkRestored() async {}
    func playRadio(_ station: InternetRadioStation) async throws {}
    func playSmartShuffle() async throws {}
    func toggleSmartShuffle() async throws {}
    func playInstantMix(from seed: InstantMixSeed, startingWith seedTrack: DisplayableSong?) async throws {}
    func setAutoExtendEnabled(_ enabled: Bool) async {}
    func setVolume(_ volume: Float) async {}
    func saveCurrentPosition() async {}
    func replayGainSettingsDidChange() async {}
    func crossfadeSettingsDidChange() async {}
    nonisolated func stopAudioEngineSync() {}
}

private nonisolated func song(_ id: String) -> DisplayableSong {
    DisplayableSong(
        id: id, title: "Song \(id)", artist: "Artist", albumId: nil, albumName: nil, artistId: nil,
        genre: nil, duration: 180, trackNumber: nil, isDownloaded: false, coverArtId: nil, audioFormat: nil,
        replayGainTrackGain: nil, replayGainTrackPeak: nil, replayGainAlbumGain: nil, replayGainAlbumPeak: nil,
        replayGainBaseGain: nil, replayGainFallbackGain: nil
    )
}

/// Suspends until `condition` holds, re-checking only when something it reads changes — it awaits
/// the network work, not the clock. The suite's time limit catches a hang.
@MainActor
private func until(_ condition: @escaping @MainActor () -> Bool) async {
    while !condition() {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            final class Once: @unchecked Sendable { var resumed = false }
            let once = Once()
            let resume: @Sendable () -> Void = {
                Task { @MainActor in
                    guard !once.resumed else { return }
                    once.resumed = true
                    continuation.resume()
                }
            }
            let done = withObservationTracking { condition() } onChange: { resume() }
            if done { resume() }
        }
    }
}

@MainActor
private func makeHost() -> (JamService, RecordingPlayer) {
    let state = PlayerState()
    state.queue = [song("now"), song("later")]
    state.currentIndex = 0
    state.currentTrack = state.queue[0]
    state.playbackState = .playing
    let player = RecordingPlayer(state: state)
    let jam = JamService(
        playerService: player,
        playerState: state,
        // The host's "server" knows every id except "elsewhere".
        resolveSongs: { ids in ids.filter { $0 != "elsewhere" }.map(song) },
        toastService: ToastService(),
        broadcastInterval: .milliseconds(20)
    )
    return (jam, player)
}

@MainActor
private func makeGuest() -> JamService {
    let state = PlayerState()
    return JamService(
        playerService: RecordingPlayer(state: state),
        playerState: state,
        resolveSongs: { _ in [] },
        toastService: ToastService()
    )
}

@MainActor
private func loopback(_ port: UInt16) -> JamHost {
    JamHost(name: "Host", endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!))
}

// MARK: - Tests

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct JamServiceLoopbackTests {
    @Test func guestJoinsAndItsQueueActionsLandOnTheHost() async throws {
        let (host, hostPlayer) = makeHost()
        let guest = makeGuest()
        defer { guest.end(); host.end() }

        host.startHosting()
        await until { host.port != nil }
        guest.join(loopback(try #require(host.port)), code: host.joinCode)
        await until { guest.role == .guest }

        #expect(guest.snapshot?.nowPlaying?.song.id == "now")
        await until { host.guestNames.count == 1 }

        // Routed through the same decorator the UI uses.
        let router = JamAwarePlayerService(base: RecordingPlayer(state: PlayerState()), jam: guest)
        await router.playNext(song("next"))
        await until { hostPlayer.playedNext == ["next"] }
        await router.addToQueue([song("a"), song("elsewhere"), song("b")])
        await until { hostPlayer.appended == ["a", "b"] }

        // The guest sees the new queue, with its own name on the tracks it added.
        await until { guest.snapshot?.upNext.map(\.song.id) == ["next", "later", "a", "b"] }
        let guestName = try #require(host.guestNames.first)
        #expect(guest.snapshot?.upNext.first?.addedBy == guestName)
        #expect(guest.snapshot?.upNext[1].addedBy == nil)
    }

    @Test func wrongCodeIsRejected() async throws {
        let (host, _) = makeHost()
        let guest = makeGuest()
        defer { guest.end(); host.end() }

        host.startHosting()
        await until { host.port != nil }
        let wrong = host.joinCode == "0000" ? "1111" : "0000"
        guest.join(loopback(try #require(host.port)), code: wrong)
        await until { guest.role == .idle && guest.lastError != nil }
        #expect(guest.lastError == "Wrong join code.")
        #expect(host.guestNames.isEmpty)
    }

    @Test func controlsNeedTheHostsPermission() async throws {
        let (host, hostPlayer) = makeHost()
        let guest = makeGuest()
        defer { guest.end(); host.end() }

        host.startHosting()
        await until { host.port != nil }
        guest.join(loopback(try #require(host.port)), code: host.joinCode)
        await until { guest.role == .guest }

        guest.sendControl(.togglePlayPause)   // not allowed yet: dropped on the guest side
        host.guestsCanControl = true
        await until { guest.snapshot?.guestsCanControl == true }
        guest.sendControl(.togglePlayPause)
        await until { hostPlayer.toggles == 1 }
    }

    @Test func endingTheJamDisconnectsGuests() async throws {
        let (host, _) = makeHost()
        let guest = makeGuest()
        defer { guest.end(); host.end() }

        host.startHosting()
        await until { host.port != nil }
        guest.join(loopback(try #require(host.port)), code: host.joinCode)
        await until { guest.role == .guest }

        host.end()
        await until { guest.role == .idle }
        #expect(guest.snapshot == nil)

        // Not a guest any more: queue actions stay local.
        #expect(guest.routeEnqueue([song("x")], placement: .end) == false)
    }
}
