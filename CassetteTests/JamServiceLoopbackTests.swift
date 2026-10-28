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
    private(set) var skips = 0
    private(set) var playedFrom: Int?

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
    func skipToNext() async throws {
        skips += 1
        state.currentIndex += 1
        state.currentTrack = state.queue[state.currentIndex]
    }
    func moveInQueue(fromIndex: Int, toIndex: Int) async {
        let song = state.queue.remove(at: fromIndex)
        state.queue.insert(song, at: toIndex > fromIndex ? toIndex - 1 : toIndex)
    }
    func removeFromQueue(at index: Int) async { state.queue.remove(at: index) }
    func play(tracks: [DisplayableSong], startIndex: Int) async throws {
        playedFrom = startIndex
        state.queue = tracks
        state.currentIndex = startIndex
        state.currentTrack = tracks[startIndex]
    }

    func playShuffled(tracks: [DisplayableSong]) async throws {}
    func resume() async {}
    func pause() async {}
    func stop() async {}
    func skipToPrevious() async throws {}
    func seek(to position: TimeInterval) async {}
    func setRepeatMode(_ mode: RepeatMode) async {}
    func toggleShuffle() async {}
    func appendToQueue(_ tracks: [DisplayableSong]) async {}
    func playNext(_ song: DisplayableSong) async { await playNext([song]) }
    func addToQueue(_ song: DisplayableSong) async { await addToQueue([song]) }
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
    state.queue = [song("now"), song("later"), song("last")]
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
        await until { guest.snapshot?.upNext.map(\.song.id) == ["next", "later", "last", "a", "b"] }
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

    @Test func guestsReorderAndRemoveWithoutPermission() async throws {
        let (host, hostPlayer) = makeHost()
        let guest = makeGuest()
        defer { guest.end(); host.end() }
        try await join(guest, host)
        #expect(host.guestsCanControl == false)

        // Up Next is ["later", "last"]: move "last" to the top, then remove "later".
        guest.moveUpNext(from: 1, to: 0)
        await until { hostPlayer.state.queue.map(\.id) == ["now", "last", "later"] }
        guest.removeUpNext(at: 1)
        await until { hostPlayer.state.queue.map(\.id) == ["now", "last"] }
        await until { guest.snapshot?.upNext.map(\.song.id) == ["last"] }
    }

    @Test func aStaleRowIsNotTouched() async throws {
        let (host, hostPlayer) = makeHost()
        let guest = makeGuest()
        defer { guest.end(); host.end() }
        try await join(guest, host)

        // The host reorders before the guest's snapshot catches up; the guest still sees "later" first.
        await hostPlayer.moveInQueue(fromIndex: 2, toIndex: 1)
        guest.removeUpNext(at: 0)
        // The host refuses (row 0 is now "last") and resends the real queue.
        await until { guest.lastNotice == "The queue changed. Try again." }
        await until { guest.snapshot?.upNext.map(\.song.id) == ["last", "later"] }
        #expect(hostPlayer.state.queue.map(\.id) == ["now", "last", "later"])
    }

    @Test func tappingASongPlaysItNowOnlyWhenTheHostAllows() async throws {
        let (host, hostPlayer) = makeHost()
        let guest = makeGuest()
        defer { guest.end(); host.end() }
        try await join(guest, host)
        let router = JamAwarePlayerService(base: RecordingPlayer(state: PlayerState()), jam: guest)

        // Not allowed: the tapped song joins the end of the queue and nothing is skipped.
        try await router.play(tracks: [song("x"), song("tapped")], startIndex: 1)
        await until { hostPlayer.appended == ["tapped"] }
        #expect(hostPlayer.skips == 0)

        // Allowed: it goes in next and the host skips to it.
        host.guestsCanControl = true
        await until { guest.canControl }
        try await router.play(tracks: [song("now2")], startIndex: 0)
        await until { hostPlayer.skips == 1 }
        #expect(hostPlayer.playedNext == ["now2"])
        #expect(hostPlayer.state.currentTrack?.id == "now2")
    }

    @Test func jumpingToARowNeedsPermission() async throws {
        let (host, hostPlayer) = makeHost()
        let guest = makeGuest()
        defer { guest.end(); host.end() }
        try await join(guest, host)

        guest.jumpToUpNext(1)   // dropped on the guest side: not allowed
        host.guestsCanControl = true
        await until { guest.canControl }
        guest.jumpToUpNext(1)
        await until { hostPlayer.playedFrom == 2 }
        #expect(hostPlayer.state.currentTrack?.id == "last")
    }
}

@MainActor
private func join(_ guest: JamService, _ host: JamService) async throws {
    host.startHosting()
    await until { host.port != nil }
    guest.join(loopback(try #require(host.port)), code: host.joinCode)
    await until { guest.role == .guest }
}
