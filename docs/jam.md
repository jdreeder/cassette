# Jam

A Jam lets friends add songs to one shared queue. One device, the **host**, plays. Guests nearby
use Cassette on their own phones and add songs to the host's queue with the usual **Add to Queue**
and **Play Next** actions. Spotify Jam works the same way.

Nothing changes on the server. Each guest browses with their own sign-in to the same server, so
song ids are the same on every device.

## Using it

- **Host:** open the queue, tap the Jam button (two people with sound waves), then tap
  **Start a Jam**. Share the four-digit code that appears.
- **Guest:** open **Settings › Jam** (or the queue's Jam button), choose the host from the
  list and type the code. Add to Queue and Play Next now send songs to the host until you leave.
- **Always open to guests:** adding songs, and reordering (drag) or removing (swipe) what's up
  next in the Jam sheet. Every guest sees the host's queue with the name of whoever added each song.
- **Host switch "Guests can skip and play now"** (off by default): when on, guests can skip,
  play and pause, tap an Up Next row to jump to it, and tap any song in Cassette to play it right
  away. When off, tapping a song adds it to the end of the queue instead.

Guests find the host with Bonjour (`_cassette-jam._tcp`), either on shared Wi-Fi or over
peer-to-peer Wi-Fi when there's no shared network. That covers a party on home Wi-Fi, a hotspot
or a travel router in a car.

## Protocol (version 1)

The protocol is small on purpose, so other Subsonic apps can join the same Jam.

- **Transport:** TCP, advertised as Bonjour `_cassette-jam._tcp`. The service name is the host's
  display name. Each message is a JSON object followed by `\n`.
- **Encoding:** Swift's synthesized `Codable` for enums with associated values, i.e.
  `{"<case>": {<labelled values>}}`. Examples:

```json
{"hello":{"name":"Alex","code":"4821","version":1}}
{"enqueue":{"songIds":["tr-1","tr-2"],"placement":"end"}}
{"control":{"_0":"togglePlayPause"}}
{"rejected":{"reason":"Wrong join code."}}
{"snapshot":{"_0":{"hostName":"Car","nowPlaying":{…},"upNext":[…],"isPlaying":true,"guests":["Alex"],"guestsCanControl":false}}}
```

| Direction | Message | Meaning |
|---|---|---|
| guest → host | `hello(name, code, version)` | First message. Wrong code, a full Jam (8 guests) or another version gets `rejected` and the connection is closed. |
| host → guest | `welcome(snapshot)` | Accepted. |
| host → guest | `snapshot(snapshot)` | Sent when the queue, the current track, play state or the guest list changes. |
| guest → host | `enqueue(songIds, placement)` | `placement` is `next` or `end`. Up to 100 ids per message. |
| host → guest | `enqueued(count)` | How many ids were queued. |
| guest → host | `move(from, to, songId)` | Reorder Up Next. `from`/`to` are `Array.move` offsets within the Up Next the guest was shown. Always allowed. |
| guest → host | `remove(index, songId)` | Remove an Up Next row. Always allowed. |
| guest → host | `playNow(songIds)` | Insert next and skip to it (just start playing if the host is idle). Needs permission. |
| guest → host | `jump(index, songId)` | Jump to an Up Next row. Needs permission. |
| guest → host | `control(command)` | `togglePlayPause`, `next`, `previous`. Needs permission. |
| host → guest | `notice(text)` | A short message to show, e.g. when no ids could be found. |

A snapshot item is `{"song": <DisplayableSong>, "addedBy": "Alex" | null}`, and `upNext` is cut
off at 50 items.

Row edits carry the `songId` the guest saw at that row. If the host's queue has moved on and the
row holds a different song, the host does nothing, sends `notice("The queue changed. Try again.")`
and a fresh snapshot. A message that needs permission while it's off gets a notice too.

**Trust:** guests send ids only. The host looks every id up on its own server (`getSong`) and drops
any it can't find. A guest can't add tracks that aren't in the host's library or change their
metadata. The join code stops other people in Bluetooth or Wi-Fi range from joining.

## Limits and next steps

- Guests need their own sign-in to the host's server. A later version could pass browsing through
  the host, so a guest needs no account, like Spotify's.
- Only the host plays audio. Synchronised listening on several devices is out of scope.
  OpenSubsonic discussion #277 and the Segue proposal (#283) cover it.
- When a guest taps a song inside an album or playlist, only that song goes to the host, not the
  rest of the list.
