// Cassette — Music client for Subsonic/OpenSubsonic servers
// Copyright (C) 2026 Mathieu Dubart
// Licensed under the Mozilla Public License 2.0.
// See LICENSE file in the project root for full license information.

import SwiftUI

/// Start, join and run a Listening Jam.
struct JamSheet: View {
    @Environment(\.appContainer) private var container
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let jam = container?.jamService {
                    JamSheetContent(jam: jam)
                }
            }
            .navigationTitle("Jam")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 480)
        #endif
    }
}

private struct JamSheetContent: View {
    @Bindable var jam: JamService
    @State private var hostToJoin: JamHost?
    @State private var code = ""

    var body: some View {
        Form {
            switch jam.role {
            case .idle: idleSections
            case .joining(let name): joiningSection(name)
            case .hosting: hostSections
            case .guest: guestSections
            }
            if let error = jam.lastError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.cassetteCaption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { if jam.role == .idle { jam.startBrowsing() } }
        .onDisappear { if jam.role == .idle { jam.stopBrowsing() } }
        .alert("Join \(hostToJoin?.name ?? "Jam")", isPresented: Binding(
            get: { hostToJoin != nil },
            set: { if !$0 { hostToJoin = nil } }
        )) {
            TextField("Code", text: $code)
                #if os(iOS)
                .keyboardType(.numberPad)
                #endif
            Button("Join") {
                if let host = hostToJoin { jam.join(host, code: code) }
                hostToJoin = nil
            }
            Button("Cancel", role: .cancel) { hostToJoin = nil }
        } message: {
            Text("Enter the code shown on the host's screen.")
        }
    }

    // MARK: - Idle

    @ViewBuilder
    private var idleSections: some View {
        Section {
            TextField("Your name", text: $jam.displayName)
        } footer: {
            Text("Everyone in the Jam sees this name next to the songs you add.")
        }

        Section {
            Button {
                jam.stopBrowsing()
                jam.startHosting()
            } label: {
                Label("Start a Jam", systemImage: "person.2.wave.2")
            }
        } footer: {
            Text("Music plays on this device. Friends nearby add to your queue from Cassette on their phones.")
        }

        Section {
            if jam.discoveredHosts.isEmpty {
                HStack(spacing: CassetteSpacing.s) {
                    ProgressView()
                    Text("Looking for Jams nearby…")
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(jam.discoveredHosts) { host in
                    Button {
                        code = ""
                        hostToJoin = host
                    } label: {
                        Label(host.name, systemImage: "hifispeaker")
                    }
                }
            }
        } header: {
            Text("Join")
        } footer: {
            Text("You need to be signed in to the same server as the host, on the same Wi-Fi or close by.")
        }
    }

    private func joiningSection(_ name: String) -> some View {
        Section {
            HStack(spacing: CassetteSpacing.s) {
                ProgressView()
                Text("Joining \(name)…")
            }
            Button("Cancel", role: .destructive) { jam.end() }
        }
    }

    // MARK: - Host

    @ViewBuilder
    private var hostSections: some View {
        Section {
            VStack(spacing: CassetteSpacing.s) {
                Text("Join code")
                    .font(.cassetteCaption)
                    .foregroundStyle(.secondary)
                Text(jam.joinCode)
                    .font(.system(.largeTitle, design: .monospaced, weight: .bold))
                    .kerning(CassetteSpacing.s)
                    .textSelection(.enabled)
                    .accessibilityLabel("Join code \(jam.joinCode.map(String.init).joined(separator: " "))")
                Text("Friends open Jam in Cassette, pick “\(jam.displayName)” and enter this code.")
                    .font(.cassetteCaption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, CassetteSpacing.s)
        }

        Section {
            Toggle("Guests can skip and play now", isOn: $jam.guestsCanControl)
        } footer: {
            Text(jam.guestsCanControl
                 ? "Guests can skip, play and pause, and start a song right away."
                 : "Guests can add songs and reorder or remove what's up next. Skipping and playing now stay with you.")
        }

        Section("In this Jam") {
            if jam.guestNames.isEmpty {
                Text("No one has joined yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(jam.guestNames, id: \.self) { name in
                    Label(name, systemImage: "person.crop.circle")
                }
            }
        }

        Section {
            Button("End Jam", role: .destructive) { jam.end() }
        }
    }

    // MARK: - Guest

    @ViewBuilder
    private var guestSections: some View {
        if let snapshot = jam.snapshot {
            Section {
                if let item = snapshot.nowPlaying {
                    JamItemRow(item: item)
                } else {
                    Text("Nothing playing")
                        .foregroundStyle(.secondary)
                }
                if snapshot.guestsCanControl {
                    HStack {
                        Spacer()
                        controlButton("backward.fill", "Previous", .previous)
                        Spacer()
                        controlButton(snapshot.isPlaying ? "pause.fill" : "play.fill",
                                      snapshot.isPlaying ? "Pause" : "Play", .togglePlayPause)
                        Spacer()
                        controlButton("forward.fill", "Next", .next)
                        Spacer()
                    }
                }
            } header: {
                Text("Playing on \(snapshot.hostName)")
            } footer: {
                Text(snapshot.guestsCanControl
                     ? "Tap a song anywhere in Cassette to play it now, or use Add to Queue and Play Next."
                     : "Add to Queue, Play Next or tap a song anywhere in Cassette to add it to this Jam.")
            }

            Section {
                if snapshot.upNext.isEmpty {
                    Text("Nothing queued yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(snapshot.upNext.enumerated()), id: \.offset) { offset, item in
                        JamItemRow(item: item)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                guard jam.canControl else { return }
                                HapticFeedback.medium.trigger()
                                jam.jumpToUpNext(offset)
                            }
                    }
                    .onMove { source, destination in
                        guard let first = source.first else { return }
                        HapticFeedback.light.trigger()
                        jam.moveUpNext(from: first, to: destination)
                    }
                    .onDelete { offsets in
                        guard let first = offsets.first else { return }
                        jam.removeUpNext(at: first)
                    }
                }
            } header: {
                Text("Up Next")
            } footer: {
                Text(snapshot.guestsCanControl
                     ? "Drag to reorder, swipe to remove, tap to play now."
                     : "Drag to reorder, swipe to remove.")
            }

            if !snapshot.guests.isEmpty {
                Section("In this Jam") {
                    Label(snapshot.hostName, systemImage: "hifispeaker")
                    ForEach(snapshot.guests, id: \.self) { name in
                        Label(name, systemImage: "person.crop.circle")
                    }
                }
            }
        }

        Section {
            Button("Leave Jam", role: .destructive) { jam.end() }
        }
    }

    private func controlButton(_ systemImage: String, _ label: LocalizedStringKey, _ command: JamCommand) -> some View {
        Button {
            HapticFeedback.light.trigger()
            jam.sendControl(command)
        } label: {
            Image(systemName: systemImage)
                .font(.title2)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(label)
    }
}

private struct JamItemRow: View {
    let item: JamItem

    var body: some View {
        HStack(spacing: CassetteSpacing.m) {
            CoverArtCard(id: item.song.coverArtId ?? item.song.id, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.song.title)
                    .font(.cassetteCellTitle)
                    .lineLimit(1)
                if let artist = item.song.artist {
                    Text(artist)
                        .font(.cassetteCellSubtitle)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if let addedBy = item.addedBy {
                Text(addedBy)
                    .font(.cassetteCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}
