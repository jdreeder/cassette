// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import Foundation
import Network
import Observation
import OSLog
import SwiftSonic

/// A nearby Cassette that is hosting a Jam, found over Bonjour.
struct JamHost: Identifiable, Hashable {
    let name: String
    let endpoint: NWEndpoint
    var id: String { "\(endpoint)" }
}

/// Listening Jam: one device plays, friends nearby add to its queue from their own Cassette.
///
/// The host advertises `_cassette-jam._tcp` (Wi-Fi or peer-to-peer Wi-Fi) and keeps playing through
/// its normal `PlayerService`. Guests browse their own connection to the same server and send song
/// ids; the host resolves them with SwiftSonic and queues them. Nothing changes on the server.
///
/// Network callbacks run on the main queue, so all state here is MainActor-isolated.
@Observable
@MainActor
final class JamService {
    enum Role: Equatable {
        case idle
        case hosting
        /// Connecting to a host; the name is shown while waiting for its reply.
        case joining(String)
        case guest
    }

    private(set) var role: Role = .idle
    /// Host: the code guests type to join.
    private(set) var joinCode = ""
    /// Host: names of connected guests.
    private(set) var guestNames: [String] = []
    /// Host: whether guests may play/pause and skip.
    var guestsCanControl = false {
        didSet { if role == .hosting { broadcastIfChanged(force: true) } }
    }
    /// Guest: hosts found nearby.
    private(set) var discoveredHosts: [JamHost] = []
    /// Guest: the host's player as last reported.
    private(set) var snapshot: JamSnapshot?
    /// Last connection or admission error, shown in the Jam sheet.
    private(set) var lastError: String?
    /// Host: the TCP port once the listener is ready.
    private(set) var port: UInt16?

    /// The name other people see. Persisted; defaults to "Cassette".
    var displayName: String {
        didSet { UserDefaults.standard.set(displayName, forKey: Self.displayNameKey) }
    }

    var isActive: Bool { role != .idle }
    var isGuest: Bool { role == .guest }

    private static let displayNameKey = "cassette.jam.displayName"

    private let playerService: any PlayerServiceProtocol
    private let playerState: PlayerState
    /// Looks song ids up on this device's server; unknown ids are left out.
    private let resolveSongs: @Sendable ([String]) async -> [DisplayableSong]
    private let toastService: ToastService
    private let broadcastInterval: Duration

    // Host
    private var listener: NWListener?
    private var roster = JamRoster(joinCode: "")
    private var peers: [UUID: Peer] = [:]
    private var broadcastTask: Task<Void, Never>?
    private var lastBroadcast: JamSnapshot?

    // Guest
    private var browser: NWBrowser?
    private var hostConnection: NWConnection?
    private var hostBuffer = JamLineBuffer()

    private final class Peer {
        let connection: NWConnection
        var buffer = JamLineBuffer()
        var name: String?
        init(connection: NWConnection) { self.connection = connection }
    }

    init(playerService: any PlayerServiceProtocol,
         playerState: PlayerState,
         resolveSongs: @escaping @Sendable ([String]) async -> [DisplayableSong],
         toastService: ToastService,
         broadcastInterval: Duration = .seconds(1)) {
        self.playerService = playerService
        self.playerState = playerState
        self.resolveSongs = resolveSongs
        self.toastService = toastService
        self.broadcastInterval = broadcastInterval
        self.displayName = UserDefaults.standard.string(forKey: Self.displayNameKey) ?? "Cassette"
    }

    private static func parameters() -> NWParameters {
        let parameters = NWParameters.tcp
        // Lets two phones find each other with no shared Wi-Fi (AWDL), as well as over a hotspot
        // or a travel router that isolates nothing.
        parameters.includePeerToPeer = true
        return parameters
    }

    // MARK: - Host

    func startHosting() {
        guard role == .idle else { return }
        lastError = nil
        roster = JamRoster(joinCode: JamRoster.makeJoinCode())
        joinCode = roster.joinCode
        do {
            let listener = try NWListener(using: Self.parameters())
            listener.service = NWListener.Service(name: JamRoster.cleanName(displayName), type: JamWire.serviceType)
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated { self?.accept(connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated { self?.listenerStateChanged(state) }
            }
            listener.start(queue: .main)
            self.listener = listener
            role = .hosting
            startBroadcasting()
            Logger.jam.info("Hosting Jam")
        } catch {
            lastError = "Couldn't start the Jam: \(error.localizedDescription)"
            Logger.jam.error("NWListener failed: \(error, privacy: .public)")
        }
    }

    private func listenerStateChanged(_ state: NWListener.State) {
        if case .ready = state { port = listener?.port?.rawValue }
        if case .failed(let error) = state {
            Logger.jam.error("Listener failed: \(error, privacy: .public)")
            lastError = "The Jam stopped: \(error.localizedDescription)"
            end()
        }
    }

    private func accept(_ connection: NWConnection) {
        let id = UUID()
        guard peers.count < JamWire.maxGuests * 2 else {
            connection.cancel()
            return
        }
        let peer = Peer(connection: connection)
        peers[id] = peer
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .failed, .cancelled: self?.dropPeer(id)
                default: break
                }
            }
        }
        connection.start(queue: .main)
        receive(on: connection) { [weak self] data in self?.peerReceived(data, from: id) ?? false }
    }

    private func dropPeer(_ id: UUID) {
        guard let peer = peers.removeValue(forKey: id) else { return }
        peer.connection.cancel()
        if let name = peer.name {
            roster.remove(id: id)
            guestNames = roster.guestNames
            toastService.show("\(name) left the Jam")
            broadcastIfChanged(force: true)
        }
    }

    /// Returns false to stop reading.
    private func peerReceived(_ data: Data, from id: UUID) -> Bool {
        guard let peer = peers[id] else { return false }
        let lines: [Data]
        do {
            lines = try peer.buffer.append(data)
        } catch {
            dropPeer(id)
            return false
        }
        for line in lines {
            guard let message = try? JamCodec.decode(line) else {
                Logger.jam.warning("Undecodable message from a guest — ignored")
                continue
            }
            handle(message, from: id)
        }
        return peers[id] != nil
    }

    private func handle(_ message: JamMessage, from id: UUID) {
        guard let peer = peers[id] else { return }
        switch message {
        case .hello(let name, let code, let version):
            guard peer.name == nil else { return }
            switch roster.admit(id: id, requestedName: name, code: code, version: version) {
            case .accepted(let assigned):
                peer.name = assigned
                guestNames = roster.guestNames
                send(.welcome(currentSnapshot()), to: peer.connection)
                toastService.show("\(assigned) joined the Jam")
                broadcastIfChanged(force: true)
            case .rejected(let reason):
                send(.rejected(reason: reason), to: peer.connection) { [weak self] in self?.dropPeer(id) }
            }
        case .enqueue(let songIds, let placement):
            guard let name = peer.name else { return }
            enqueue(Array(songIds.prefix(JamWire.maxEnqueueBatch)), placement: placement, from: name, connection: peer.connection)
        case .control(let command):
            guard peer.name != nil, guestsCanControl else { return }
            Task {
                switch command {
                case .togglePlayPause: await playerService.togglePlayPause()
                case .next: try? await playerService.skipToNext()
                case .previous: try? await playerService.skipToPrevious()
                }
            }
        case .welcome, .rejected, .snapshot, .enqueued, .notice:
            break
        }
    }

    private func enqueue(_ songIds: [String], placement: JamPlacement, from name: String, connection: NWConnection) {
        Task {
            // Ids the host's server doesn't know are dropped: that guest is on another server.
            let songs = await resolveSongs(songIds)
            guard role == .hosting else { return }
            guard !songs.isEmpty else {
                send(.notice("Those tracks aren't on \(ownName)'s server."), to: connection)
                send(.enqueued(count: 0), to: connection)
                return
            }
            roster.recordAdded(songIds: songs.map(\.id), by: name)
            switch placement {
            case .next: await playerService.playNext(songs)
            case .end: await playerService.addToQueue(songs)
            }
            let what = songs.count == 1 ? "“\(songs[0].title)”" : "\(songs.count) songs"
            toastService.showConfirmation("\(name) added \(what)", coverArtId: songs.first?.coverArtId)
            send(.enqueued(count: songs.count), to: connection)
            broadcastIfChanged(force: true)
        }
    }

    private var ownName: String { JamRoster.cleanName(displayName) }

    private func currentSnapshot() -> JamSnapshot {
        roster.snapshot(
            hostName: ownName,
            queue: playerState.queue,
            currentIndex: playerState.currentIndex,
            hasCurrentTrack: playerState.currentTrack != nil && !playerState.isLiveStream,
            isPlaying: playerState.playbackState == .playing,
            guestsCanControl: guestsCanControl
        )
    }

    /// Polls the player and pushes a snapshot when it changes. A poll keeps the host side out of
    /// PlayerService entirely; a second's lag on a queue view is fine.
    private func startBroadcasting() {
        broadcastTask?.cancel()
        broadcastTask = Task { [weak self, broadcastInterval] in
            while !Task.isCancelled {
                self?.broadcastIfChanged(force: false)
                try? await Task.sleep(for: broadcastInterval)
            }
        }
    }

    private func broadcastIfChanged(force: Bool) {
        guard role == .hosting else { return }
        let snapshot = currentSnapshot()
        guard force || snapshot != lastBroadcast else { return }
        lastBroadcast = snapshot
        for peer in peers.values where peer.name != nil {
            send(.snapshot(snapshot), to: peer.connection)
        }
    }

    // MARK: - Guest

    func startBrowsing() {
        guard browser == nil, role == .idle else { return }
        lastError = nil
        let browser = NWBrowser(for: .bonjour(type: JamWire.serviceType, domain: nil), using: Self.parameters())
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated {
                self?.discoveredHosts = results.compactMap { result in
                    guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                    return JamHost(name: name, endpoint: result.endpoint)
                }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                if case .failed(let error) = state {
                    self?.lastError = "Couldn't look for Jams: \(error.localizedDescription)"
                    self?.stopBrowsing()
                }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stopBrowsing() {
        browser?.cancel()
        browser = nil
        discoveredHosts = []
    }

    func join(_ host: JamHost, code: String) {
        guard role == .idle else { return }
        lastError = nil
        role = .joining(host.name)
        hostBuffer = JamLineBuffer()
        let connection = NWConnection(to: host.endpoint, using: Self.parameters())
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.hostConnectionChanged(state, code: code) }
        }
        connection.start(queue: .main)
        hostConnection = connection
        receive(on: connection) { [weak self] data in self?.hostReceived(data) ?? false }
    }

    private func hostConnectionChanged(_ state: NWConnection.State, code: String) {
        switch state {
        case .ready:
            send(.hello(name: ownName, code: code, version: JamWire.protocolVersion), to: hostConnection)
        case .failed(let error):
            Logger.jam.error("Host connection failed: \(error, privacy: .public)")
            leaveAfterDisconnect(reason: "Lost the connection to the Jam.")
        case .cancelled:
            leaveAfterDisconnect(reason: nil)
        default:
            break
        }
    }

    private func hostReceived(_ data: Data) -> Bool {
        let lines: [Data]
        do {
            lines = try hostBuffer.append(data)
        } catch {
            leaveAfterDisconnect(reason: "The Jam sent something Cassette couldn't read.")
            return false
        }
        for line in lines {
            guard let message = try? JamCodec.decode(line) else { continue }
            switch message {
            case .welcome(let snapshot):
                self.snapshot = snapshot
                role = .guest
                stopBrowsing()
                toastService.showSuccess("Joined \(snapshot.hostName)'s Jam")
            case .rejected(let reason):
                leaveAfterDisconnect(reason: reason)
                return false
            case .snapshot(let snapshot):
                self.snapshot = snapshot
            case .enqueued(let count):
                if count > 0 {
                    let host = snapshot?.hostName ?? "the host"
                    toastService.showConfirmation(count == 1 ? "Added to \(host)'s Jam" : "\(count) songs added to \(host)'s Jam")
                }
            case .notice(let text):
                toastService.show(text)
            case .hello, .enqueue, .control:
                break
            }
        }
        return hostConnection != nil
    }

    private func leaveAfterDisconnect(reason: String?) {
        guard hostConnection != nil else { return }
        let wasGuest = role == .guest
        hostConnection?.cancel()
        hostConnection = nil
        snapshot = nil
        role = .idle
        if let reason { lastError = reason }
        if wasGuest { toastService.show(reason ?? "You left the Jam") }
    }

    /// Guest: sends tracks to the host instead of the local queue. Returns false when not a guest,
    /// so the caller queues locally as usual.
    func routeEnqueue(_ songs: [DisplayableSong], placement: JamPlacement) -> Bool {
        guard role == .guest, let hostConnection else { return false }
        let ids = songs.map(\.id)
        guard !ids.isEmpty else { return true }
        for start in stride(from: 0, to: ids.count, by: JamWire.maxEnqueueBatch) {
            let batch = Array(ids[start..<min(start + JamWire.maxEnqueueBatch, ids.count)])
            send(.enqueue(songIds: batch, placement: placement), to: hostConnection)
        }
        return true
    }

    func sendControl(_ command: JamCommand) {
        guard role == .guest, snapshot?.guestsCanControl == true else { return }
        send(.control(command), to: hostConnection)
    }

    // MARK: - Both

    /// Host: ends the Jam for everyone. Guest: leaves it.
    func end() {
        switch role {
        case .hosting:
            broadcastTask?.cancel()
            broadcastTask = nil
            listener?.cancel()
            listener = nil
            for peer in peers.values { peer.connection.cancel() }
            peers = [:]
            roster = JamRoster(joinCode: "")
            guestNames = []
            joinCode = ""
            port = nil
            lastBroadcast = nil
            role = .idle
        case .joining, .guest:
            leaveAfterDisconnect(reason: nil)
            role = .idle
        case .idle:
            stopBrowsing()
        }
    }

    // MARK: - Transport

    private func send(_ message: JamMessage, to connection: NWConnection?, then completion: (@MainActor () -> Void)? = nil) {
        guard let connection, let data = try? JamCodec.encode(message) else { return }
        connection.send(content: data, completion: .contentProcessed { error in
            if let error { Logger.jam.debug("Jam send failed: \(error, privacy: .public)") }
            guard let completion else { return }
            MainActor.assumeIsolated { completion() }
        })
    }

    /// Reads until the handler returns false, the peer closes, or an error occurs.
    private func receive(on connection: NWConnection, handler: @escaping @MainActor (Data) -> Bool) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                var keepReading = error == nil && !isComplete
                if let data, !data.isEmpty {
                    keepReading = handler(data) && keepReading
                }
                if keepReading {
                    self?.receive(on: connection, handler: handler)
                } else {
                    connection.cancel()
                }
            }
        }
    }
}

extension JamService {
    /// Resolves guest-sent ids through SwiftSonic against the active server, in order.
    nonisolated static func resolve(_ ids: [String], with server: any ServerServiceProtocol) async -> [DisplayableSong] {
        do {
            let client = try await server.makeSwiftSonicClient()
            var songs: [DisplayableSong] = []
            for id in ids {
                if let song = try? await client.getSong(id: id) {
                    songs.append(DisplayableSong(from: song))
                }
            }
            return songs
        } catch {
            Logger.jam.error("Jam enqueue: no server client: \(error, privacy: .public)")
            return []
        }
    }
}
