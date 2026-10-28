// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Testing
import Foundation
@testable import Cassette

private func song(_ id: String) -> DisplayableSong {
    DisplayableSong(
        id: id, title: "Song \(id)", artist: "Artist", albumId: nil, albumName: nil, artistId: nil,
        genre: nil, duration: 180, trackNumber: nil, isDownloaded: false, coverArtId: nil, audioFormat: nil,
        replayGainTrackGain: nil, replayGainTrackPeak: nil, replayGainAlbumGain: nil, replayGainAlbumPeak: nil,
        replayGainBaseGain: nil, replayGainFallbackGain: nil
    )
}

struct JamCodecTests {
    @Test func everyMessageRoundTrips() throws {
        let snapshot = JamSnapshot(
            hostName: "Car", nowPlaying: JamItem(song: song("a"), addedBy: nil),
            upNext: [JamItem(song: song("b"), addedBy: "Alex")],
            isPlaying: true, guests: ["Alex"], guestsCanControl: false
        )
        let messages: [JamMessage] = [
            .hello(name: "Alex", code: "1234", version: JamWire.protocolVersion),
            .welcome(snapshot),
            .rejected(reason: "Wrong join code."),
            .snapshot(snapshot),
            .enqueue(songIds: ["a", "b"], placement: .next),
            .enqueued(count: 2),
            .move(from: 2, to: 0, songId: "c"),
            .remove(index: 1, songId: "b"),
            .playNow(songIds: ["a"]),
            .jump(index: 3, songId: "d"),
            .control(.togglePlayPause),
            .notice("Hi")
        ]
        for message in messages {
            let data = try JamCodec.encode(message)
            #expect(data.last == 0x0A)
            #expect(data.dropLast().contains(0x0A) == false)
            #expect(try JamCodec.decode(data.dropLast()) == message)
        }
    }
}

struct JamLineBufferTests {
    @Test func reassemblesLinesSplitAcrossReads() throws {
        var buffer = JamLineBuffer()
        let stream = try JamCodec.encode(.enqueued(count: 1)) + JamCodec.encode(.notice("x"))
        let cut = stream.count / 2 + 3
        let first = try buffer.append(stream.prefix(cut))
        let second = try buffer.append(stream.dropFirst(cut))
        let lines = first + second
        #expect(lines.count == 2)
        #expect(try JamCodec.decode(lines[0]) == .enqueued(count: 1))
        #expect(try JamCodec.decode(lines[1]) == .notice("x"))
    }

    @Test func dropsAnOverlongLine() {
        var buffer = JamLineBuffer(maxLineBytes: 8)
        #expect(throws: JamLineBuffer.Overflow.self) {
            _ = try buffer.append(Data(repeating: 0x41, count: 9))
        }
    }
}

struct JamRosterTests {
    @Test func admitsOnlyWithTheRightCodeAndVersion() {
        var roster = JamRoster(joinCode: "4321")
        #expect(roster.admit(id: UUID(), requestedName: "A", code: "0000", version: JamWire.protocolVersion)
                == .rejected("Wrong join code."))
        if case .accepted = roster.admit(id: UUID(), requestedName: "A", code: "4321", version: JamWire.protocolVersion + 1) {
            Issue.record("Admitted a guest on another protocol version")
        }
        #expect(roster.admit(id: UUID(), requestedName: "A", code: "4321", version: JamWire.protocolVersion)
                == .accepted(name: "A"))
    }

    @Test func givesDuplicateNamesASuffixAndBlankNamesADefault() {
        var roster = JamRoster(joinCode: "1111")
        let v = JamWire.protocolVersion
        #expect(roster.admit(id: UUID(), requestedName: "Sam", code: "1111", version: v) == .accepted(name: "Sam"))
        #expect(roster.admit(id: UUID(), requestedName: " Sam ", code: "1111", version: v) == .accepted(name: "Sam 2"))
        #expect(roster.admit(id: UUID(), requestedName: "   ", code: "1111", version: v) == .accepted(name: "Guest"))
    }

    @Test func refusesGuestsBeyondTheLimit() {
        var roster = JamRoster(joinCode: "1111")
        for i in 0..<JamWire.maxGuests {
            _ = roster.admit(id: UUID(), requestedName: "G\(i)", code: "1111", version: JamWire.protocolVersion)
        }
        #expect(roster.admit(id: UUID(), requestedName: "Late", code: "1111", version: JamWire.protocolVersion)
                == .rejected("This Jam is full."))
    }

    @Test func removingAGuestFreesItsName() {
        var roster = JamRoster(joinCode: "1111")
        let id = UUID()
        _ = roster.admit(id: id, requestedName: "Sam", code: "1111", version: JamWire.protocolVersion)
        roster.remove(id: id)
        #expect(roster.guestNames.isEmpty)
        #expect(roster.admit(id: UUID(), requestedName: "Sam", code: "1111", version: JamWire.protocolVersion)
                == .accepted(name: "Sam"))
    }

    @Test func snapshotShowsWhoAddedEachUpcomingTrack() {
        var roster = JamRoster(joinCode: "1111")
        roster.recordAdded(songIds: ["c"], by: "Alex")
        let snapshot = roster.snapshot(
            hostName: "Car", queue: [song("a"), song("b"), song("c")], currentIndex: 1,
            hasCurrentTrack: true, isPlaying: true, guestsCanControl: true
        )
        #expect(snapshot.nowPlaying?.song.id == "b")
        #expect(snapshot.upNext.map(\.song.id) == ["c"])
        #expect(snapshot.upNext.first?.addedBy == "Alex")
        #expect(snapshot.nowPlaying?.addedBy == nil)
    }

    @Test func snapshotCapsUpNextAndHandlesAnEmptyQueue() {
        let roster = JamRoster(joinCode: "1111")
        let long = (0...(JamWire.maxUpNext + 10)).map { song("\($0)") }
        let snapshot = roster.snapshot(hostName: "Car", queue: long, currentIndex: 0,
                                       hasCurrentTrack: true, isPlaying: false, guestsCanControl: false)
        #expect(snapshot.upNext.count == JamWire.maxUpNext)

        let empty = roster.snapshot(hostName: "Car", queue: [], currentIndex: 0,
                                    hasCurrentTrack: false, isPlaying: false, guestsCanControl: false)
        #expect(empty.nowPlaying == nil)
        #expect(empty.upNext.isEmpty)
    }

    @Test func upNextRowsResolveOnlyWhileTheyHoldTheSameSong() {
        let queue = [song("a"), song("b"), song("c")]
        #expect(JamRoster.queueIndex(upNextIndex: 1, songId: "c", queue: queue, currentIndex: 0) == 2)
        #expect(JamRoster.queueIndex(upNextIndex: 0, songId: "c", queue: queue, currentIndex: 0) == nil)
        #expect(JamRoster.queueIndex(upNextIndex: 2, songId: "c", queue: queue, currentIndex: 0) == nil)
        #expect(JamRoster.queueIndex(upNextIndex: -1, songId: "a", queue: queue, currentIndex: 0) == nil)
    }

    @Test func joinCodesAreFourDigits() {
        for _ in 0..<50 {
            let code = JamRoster.makeJoinCode()
            #expect(code.count == JamWire.joinCodeLength)
            #expect(code.allSatisfy { $0.isNumber })
        }
    }
}
