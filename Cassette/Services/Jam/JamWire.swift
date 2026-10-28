// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation

/// Wire format for a Listening Jam: one host device plays, nearby guests add to its queue.
///
/// Messages are JSON objects, one per line (`\n`-terminated), over a TCP connection the host
/// advertises with Bonjour. Guests send song ids only — the host re-resolves every id against its
/// own server, so a guest can only queue tracks that exist in the host's library, and the metadata
/// the host shows always comes from that server.
nonisolated enum JamWire {
    static let serviceType = "_cassette-jam._tcp"
    /// Bumped on any incompatible message change. The host rejects a guest on a different version.
    static let protocolVersion = 1
    static let maxGuests = 8
    /// Upcoming tracks sent in each snapshot; guests only need what is coming soon.
    static let maxUpNext = 50
    /// Song ids accepted in one enqueue (one album or a short playlist).
    static let maxEnqueueBatch = 100
    /// A line longer than this is a misbehaving peer; the connection is dropped.
    static let maxLineBytes = 1 << 20
    static let joinCodeLength = 4
}

/// A track in the shared queue, with the guest who added it (`nil` when the host did).
nonisolated struct JamItem: Codable, Hashable, Sendable {
    let song: DisplayableSong
    let addedBy: String?
}

/// What guests see of the host's player.
nonisolated struct JamSnapshot: Codable, Equatable, Sendable {
    var hostName: String
    var nowPlaying: JamItem?
    var upNext: [JamItem]
    var isPlaying: Bool
    var guests: [String]
    /// Whether guests may skip, play/pause and play songs now. Adding to and reordering the queue
    /// is always allowed.
    var guestsCanControl: Bool
}

nonisolated enum JamPlacement: String, Codable, Sendable {
    case next
    case end
}

nonisolated enum JamCommand: String, Codable, Sendable {
    case togglePlayPause
    case next
    case previous
}

nonisolated enum JamMessage: Codable, Equatable, Sendable {
    /// Guest → host, first message on a connection.
    case hello(name: String, code: String, version: Int)
    /// Host → guest: accepted. Carries the current snapshot.
    case welcome(JamSnapshot)
    /// Host → guest: refused (wrong code, full, version mismatch). The host closes the connection.
    case rejected(reason: String)
    /// Host → guest, whenever the queue or playback changes.
    case snapshot(JamSnapshot)
    /// Guest → host.
    case enqueue(songIds: [String], placement: JamPlacement)
    /// Host → guest: how many of the requested ids were queued.
    case enqueued(count: Int)
    /// Guest → host: move an Up Next row. `from`/`to` are `Array.move` offsets within the Up Next
    /// the guest was shown; `songId` is the song it moved, so a stale view can't move another one.
    case move(from: Int, to: Int, songId: String)
    /// Guest → host: remove an Up Next row, checked against `songId` the same way.
    case remove(index: Int, songId: String)
    /// Guest → host: play these songs right away. Needs the host's permission.
    case playNow(songIds: [String])
    /// Guest → host: jump to an Up Next row. Needs the host's permission.
    case jump(index: Int, songId: String)
    /// Guest → host: play/pause and skip. Needs the host's permission.
    case control(JamCommand)
    /// Host → guest: a short human-readable message (e.g. a failed enqueue).
    case notice(String)
}

nonisolated enum JamCodec {
    static func encode(_ message: JamMessage) throws -> Data {
        var data = try JSONEncoder().encode(message)
        data.append(0x0A)
        return data
    }

    static func decode(_ line: Data) throws -> JamMessage {
        try JSONDecoder().decode(JamMessage.self, from: line)
    }
}

/// Splits a TCP byte stream into newline-terminated lines.
nonisolated struct JamLineBuffer {
    enum Overflow: Error { case lineTooLong }

    private var pending = Data()
    private let maxLineBytes: Int

    init(maxLineBytes: Int = JamWire.maxLineBytes) {
        self.maxLineBytes = maxLineBytes
    }

    /// Appends received bytes and returns every complete line (without the terminator).
    mutating func append(_ data: Data) throws -> [Data] {
        pending.append(data)
        var lines: [Data] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex..<newline]
            if !line.isEmpty { lines.append(Data(line)) }
            pending = Data(pending[pending.index(after: newline)...])
        }
        if pending.count > maxLineBytes { throw Overflow.lineTooLong }
        return lines
    }
}

/// Host-side bookkeeping that does not touch the network: guest names, join code checks and who
/// added which track. Kept separate so it can be tested without sockets.
nonisolated struct JamRoster {
    let joinCode: String
    private(set) var guests: [UUID: String] = [:]
    /// Song id → guest name. A song queued twice keeps the most recent name.
    private(set) var addedBy: [String: String] = [:]

    init(joinCode: String) {
        self.joinCode = joinCode
    }

    static func makeJoinCode() -> String {
        (0..<JamWire.joinCodeLength).map { _ in String(Int.random(in: 0...9)) }.joined()
    }

    enum Admission: Equatable {
        case accepted(name: String)
        case rejected(String)
    }

    /// Admits a guest, giving it a unique display name ("Alex", "Alex 2", …).
    mutating func admit(id: UUID, requestedName: String, code: String, version: Int) -> Admission {
        guard version == JamWire.protocolVersion else {
            return .rejected("This Jam uses a different version of Cassette. Update both apps and try again.")
        }
        guard code == joinCode else { return .rejected("Wrong join code.") }
        guard guests.count < JamWire.maxGuests else { return .rejected("This Jam is full.") }
        let base = Self.cleanName(requestedName)
        var name = base
        var suffix = 2
        let taken = Set(guests.values)
        while taken.contains(name) {
            name = "\(base) \(suffix)"
            suffix += 1
        }
        guests[id] = name
        return .accepted(name: name)
    }

    mutating func remove(id: UUID) {
        guests[id] = nil
    }

    mutating func recordAdded(songIds: [String], by name: String) {
        for id in songIds { addedBy[id] = name }
    }

    var guestNames: [String] { guests.values.sorted() }

    func snapshot(hostName: String, queue: [DisplayableSong], currentIndex: Int,
                  hasCurrentTrack: Bool, isPlaying: Bool, guestsCanControl: Bool) -> JamSnapshot {
        let current = hasCurrentTrack && queue.indices.contains(currentIndex) ? queue[currentIndex] : nil
        let upcoming = queue.indices.contains(currentIndex)
            ? Array(queue.dropFirst(currentIndex + 1).prefix(JamWire.maxUpNext))
            : []
        return JamSnapshot(
            hostName: hostName,
            nowPlaying: current.map { JamItem(song: $0, addedBy: addedBy[$0.id]) },
            upNext: upcoming.map { JamItem(song: $0, addedBy: addedBy[$0.id]) },
            isPlaying: isPlaying,
            guests: guestNames,
            guestsCanControl: guestsCanControl
        )
    }

    /// The host queue index for row `upNextIndex` of the Up Next a guest was shown, or `nil` when that
    /// row no longer holds `songId` (the queue moved on since the guest's last snapshot).
    static func queueIndex(upNextIndex: Int, songId: String, queue: [DisplayableSong], currentIndex: Int) -> Int? {
        let index = currentIndex + 1 + upNextIndex
        guard upNextIndex >= 0, queue.indices.contains(index), queue[index].id == songId else { return nil }
        return index
    }

    static func cleanName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Guest" : String(trimmed.prefix(32))
    }
}
