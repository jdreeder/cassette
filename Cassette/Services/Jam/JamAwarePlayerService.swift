// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import SwiftSonic

/// The `PlayerServiceProtocol` the UI talks to. Forwards everything to `PlayerService`, except that
/// while this device is a Jam guest, "Add to Queue" and "Play Next" go to the host's queue instead.
///
/// Every queue action in the app already goes through these two calls, so routing them here makes
/// all of them Jam-aware without touching a view. `PlayerService` stays the single source of truth
/// for this device's playback; `JamService` holds the unwrapped one so a host's guest adds never
/// loop back through the router.
nonisolated final class JamAwarePlayerService: PlayerServiceProtocol {
    private let base: any PlayerServiceProtocol
    private let jam: JamService

    init(base: any PlayerServiceProtocol, jam: JamService) {
        self.base = base
        self.jam = jam
    }

    var state: PlayerState { base.state }

    private func routed(_ songs: [DisplayableSong], _ placement: JamPlacement) async -> Bool {
        await jam.routeEnqueue(songs, placement: placement)
    }

    // MARK: - Routed while a guest

    func appendToQueue(_ tracks: [DisplayableSong]) async {
        if await routed(tracks, .end) { return }
        await base.appendToQueue(tracks)
    }

    func addToQueue(_ songs: [DisplayableSong]) async {
        if await routed(songs, .end) { return }
        await base.addToQueue(songs)
    }

    func addToQueue(_ song: DisplayableSong) async {
        await addToQueue([song])
    }

    func playNext(_ songs: [DisplayableSong]) async {
        if await routed(songs, .next) { return }
        await base.playNext(songs)
    }

    func playNext(_ song: DisplayableSong) async {
        await playNext([song])
    }

    // MARK: - Forwarded

    func play(tracks: [DisplayableSong], startIndex: Int) async throws { try await base.play(tracks: tracks, startIndex: startIndex) }
    func playShuffled(tracks: [DisplayableSong]) async throws { try await base.playShuffled(tracks: tracks) }
    func resume() async { await base.resume() }
    func pause() async { await base.pause() }
    func stop() async { await base.stop() }
    func skipToNext() async throws { try await base.skipToNext() }
    func skipToPrevious() async throws { try await base.skipToPrevious() }
    func seek(to position: TimeInterval) async { await base.seek(to: position) }
    func setRepeatMode(_ mode: RepeatMode) async { await base.setRepeatMode(mode) }
    func toggleShuffle() async { await base.toggleShuffle() }
    func removeFromQueue(at index: Int) async { await base.removeFromQueue(at: index) }
    func moveInQueue(fromIndex: Int, toIndex: Int) async { await base.moveInQueue(fromIndex: fromIndex, toIndex: toIndex) }
    func restoreSession() async { await base.restoreSession() }
    func restoreFromOtherDevice() async -> Bool { await base.restoreFromOtherDevice() }
    func handleNetworkRestored() async { await base.handleNetworkRestored() }
    func playRadio(_ station: InternetRadioStation) async throws { try await base.playRadio(station) }
    func playSmartShuffle() async throws { try await base.playSmartShuffle() }
    func toggleSmartShuffle() async throws { try await base.toggleSmartShuffle() }
    func playInstantMix(from seed: InstantMixSeed, startingWith seedTrack: DisplayableSong?) async throws {
        try await base.playInstantMix(from: seed, startingWith: seedTrack)
    }
    func setAutoExtendEnabled(_ enabled: Bool) async { await base.setAutoExtendEnabled(enabled) }
    func setVolume(_ volume: Float) async { await base.setVolume(volume) }
    func togglePlayPause() async { await base.togglePlayPause() }
    func saveCurrentPosition() async { await base.saveCurrentPosition() }
    func replayGainSettingsDidChange() async { await base.replayGainSettingsDidChange() }
    func crossfadeSettingsDidChange() async { await base.crossfadeSettingsDidChange() }
    func stopAudioEngineSync() { base.stopAudioEngineSync() }
}
