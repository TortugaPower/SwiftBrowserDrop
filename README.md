# SwiftBrowserDrop

Let people upload files into your iOS app from any computer's browser on the same network: no cable, no
account, no cloud. Your app runs a small HTTP server while an upload screen is open. The person opens the
address it shows (for example `http://192.168.1.20/`), drops files or whole folders on the page, and the
files wait in a staging folder until your app accepts them.

```swift
import BrowserDrop
```

- **Upload-only.** Nothing on the device can be read, listed or deleted through the server.
- **Only complete files are handed over.** Interrupted uploads never reach your app.
- **Built on Network.framework's structured-concurrency API** (`NetworkListener`), with no dependencies.
  The server is an actor; the listener runs in a task and every connection is a child of it, so stopping
  the session ends every connection before anything else happens.
- **Ships with an upload page** (drag and drop, folders, progress, automatic retries) that you can restyle,
  translate or replace with your own.

Requirements: iOS 26 or macOS 26, Swift 6.2.

## Installation

```swift
.package(url: "https://github.com/TortugaPower/SwiftBrowserDrop.git", from: "2.0.0")
```

Then add the `BrowserDrop` product to your target.

## Quick start

One `BrowserDropServer` is one session: create it when your upload screen appears and end it when the
screen closes.

```swift
let server = BrowserDropServer(configuration: .init(
  allowedExtensions: ["mp3", "m4a", "m4b"],
  pageSettings: .init(title: "My App")
))

// Show the person where to go, for example http://192.168.1.20/
let addresses = try await server.start()
let url = addresses.first?.url

// Follow what arrives (a single consumer).
Task {
  for await event in server.events {
    switch event {
    case .uploadFinished(let file): print("Got \(file.relativePath)")
    case .addressesChanged(let addresses): print("Now at \(addresses.map(\.url))")
    case .interrupted: try? await server.resume()
    default: break
    }
  }
}

// The person is done: take the folder holding everything that arrived, laid out as they sent it.
if let folder = try await server.finish() {
  // It's yours now: move it where your app keeps things, or import from it and delete it.
  try FileManager.default.moveItem(at: folder, to: inbox)
}

// Or they cancelled: delete it all.
await server.cancel()
```

`receivedFiles` always lists what's complete. Uploading exactly the same relative path again replaces that
file, so retries never create duplicates. Anything else that would take a name already used in the session
is refused (see [Security model](#security-model)).

`finish()` returns `nil` when nothing arrived. Otherwise the folder it returns belongs to your app: the
server never touches it again, and naming, moving and handling errors are up to you. It sits inside
`stagingRoot`, so `removeLeftovers()` at the next launch deletes it if your app didn't.

`events` brings a couple of events per upload (started, then finished or failed) and network changes.
Nothing is dropped, so read it for the whole session. For a progress bar, read `progress` too: each element
lists the uploads in flight and how much of each has arrived, and only the newest list is kept, so a reader
that falls behind skips straight to the current one.

```swift
Task {
  for await uploads in server.progress {
    for item in uploads { print(item.upload.relativePath, item.receivedBytes, "of", item.upload.size) }
  }
}
```

To drop something the person changed their mind about, call `removeReceivedItem(at:)` with a file's
relative path, or with a folder (`Book`) to drop it and everything in it. It won't be handed over.

### On iOS

- **Keep the screen awake** while the upload screen is open (`UIApplication.shared.isIdleTimerDisabled`).
  Save the previous value and restore it afterwards: other parts of your app may set it too.
- **Suspend in the background and resume in the foreground.** iOS suspends apps in the background, so the
  server can't keep listening there. `suspend()` keeps the files that already arrived; `resume()` listens
  again on the same port, so an open browser tab carries on and the bundled page retries what was cut off.
- **Clean up at launch.** If the app was killed mid-session, its staging is still in `tmp`, and so is a
  folder `finish()` handed over that the app never moved or deleted. Call
  `BrowserDropServer.removeLeftovers()` at launch, before creating a server.
- **No local network permission is needed.** Accepting incoming TCP connections isn't a local network
  operation ([TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)),
  so the server doesn't trigger the permission prompt or need `NSLocalNetworkUsageDescription`.
- **Port 80 works on iOS**, so the address needs no port. The server falls back to 8080 if 80 is taken.
- **Addresses are labelled** Wi‑Fi, wired, hotspot or other. Cellular, VPN, link-local and peer-to-peer
  interfaces are left out, and `en0` isn't assumed to be Wi‑Fi. With Personal Hotspot on, a computer joined
  to the hotspot uses the `hotspot` address.

## Security model

The server only exists while your upload screen is open, it can only receive files, and every file waits for
the person to accept it in your app. So it has **no password or pairing code by design**. What it does check:

- **Origin and Host.** Uploads must come from the server's own page. A different `Origin` (another website
  posting in the background) or a public `Host` name (DNS rebinding) gets 403. `Host` must be an IP address,
  `localhost`, a single-label name or a private-use name such as `.local`, `.lan`, `.home` or `.home.arpa`.
- **Paths.** Relative paths only. `..`, absolute paths, empty or hidden segments (`.git`, `.DS_Store`) and
  control characters are refused, and so are file types not in `allowedExtensions`.
- **Size and space.** Files over `maximumFileSize` get 413. An upload that would leave less than
  `reservedFreeSpace` on the device gets 507, counting what in-flight uploads still have to write.
- **Quiet connections.** A connection that sends nothing for `idleTimeout`, or takes longer than that to
  send its request head, is closed. Slow uploads are left alone, however slow: on bad Wi‑Fi they still finish.
- **Connections** are capped at `maximumConnections` (64 by default); more are closed right away, so other
  devices can't exhaust the app's file descriptors.
- **Names.** Only exactly the same path replaces an earlier upload, which is what a retry sends. An upload
  that would take a name the session already uses in another form gets 409 and changes nothing: a folder
  where the file goes, a file where one of its folders goes (`x/y.mp3` after `x`), or the same name in
  another case on a case-insensitive volume (`A.mp3` after `a.mp3` on a Mac). It's checked before the body
  is read, and again when the file is stored, in case another upload took the name meanwhile.
- **Nothing else.** Only `GET` (the page and `config.json`) and `POST /upload` exist. No directory listings,
  and page files can't be served from outside the page folder, symlinks included.

## Protocol (version 1)

The bundled page uses this protocol, and a custom page must too. Every connection carries one request and is
closed after the response.

| Request | Response |
| --- | --- |
| `GET /` and `GET /<file>` | The page's `index.html` and its other files. |
| `GET /config.json` | The page settings, below. |
| `POST /upload?path=<relative path>` | Stores the body as that file. |

**`config.json`**

```json
{
  "protocolVersion": 1,
  "title": "My App",
  "language": "es",
  "accentColor": "#FF8800",
  "allowedExtensions": ["m4a", "m4b", "mp3"],
  "maximumFileSize": 8589934592,
  "maximumConcurrentUploads": 3,
  "strings": { "title": "Subir archivos" }
}
```

`title`, `language`, `accentColor` and `allowedExtensions` are left out when not set; `allowedExtensions` is
missing when any type is accepted.

**Uploads.** The body is the raw file (what `XMLHttpRequest.send(file)` sends). `Content-Length` is required
and chunked bodies aren't accepted. Percent-encode the path with `encodeURIComponent`; `/` separates folders.
`Expect: 100-continue` is honoured.

A successful upload answers `201` with `{"path": "<cleaned path>"}`. Errors answer
`{"error": "<code>", "message": "<text>"}`:

| Status | Code | Meaning |
| --- | --- | --- |
| 400 | `bad_request` | The request couldn't be read. |
| 400 | `invalid_path` | The path is missing or unsafe. |
| 400 | `unsupported_type` | The file type isn't accepted. |
| 403 | `forbidden` | Not from the server's own page. |
| 404 | `not_found` | No such page file. |
| 405 | `method_not_allowed` | Anything but the requests above. |
| 409 | `path_conflict` | Another file or folder in the session already has that name. |
| 411 | `length_required` | No `Content-Length`, or a chunked body. |
| 413 | `too_large` | Over `maximumFileSize`. |
| 431 | `headers_too_large` | The request head is over 16 KiB. |
| 500 | `write_failed` | The file couldn't be written. |
| 500 | `page_missing` | The bundled page isn't in the app (a packaging problem). |
| 507 | `insufficient_storage` | Not enough free space on the device. |

A connection that drops is just a failed upload: retry it. Changing any of this is a major version bump.

## Customizing the page

`pageSettings` changes the bundled page's title, language, accent color and text. Every key below can be
replaced through `strings`; `{done}`, `{total}` and `{count}` are filled in by the page.

| Key | English |
| --- | --- |
| `title` | Upload files |
| `subtitle` | Send files from this computer to your device. |
| `dropTitle` | Drop files or folders here |
| `dropHint` | Folders keep their structure. |
| `chooseFiles` | Choose files |
| `chooseFolder` | Choose folder |
| `summaryEmpty` | No files yet. |
| `summary` | {done} of {total} uploaded |
| `queued` | Waiting |
| `uploading` | Uploading |
| `uploaded` | Uploaded |
| `failed` | Failed |
| `waitingForDevice` | Waiting for the device… |
| `deviceUnreachable` | Can't reach the device. Keep the upload screen open on it; uploads resume on their own. |
| `notEnoughSpace` | Not enough space on the device |
| `tooLarge` | Too large |
| `unsupported` | File type not supported |
| `pathConflict` | Another file or folder you sent has this name |
| `skipped` | Skipped because the type isn't supported: {count} |
| `retry` | Retry failed |
| `doneHint` | When you're done, confirm on your device to import the files. |
| `loadError` | Can't reach the device. Check that its upload screen is still open. |

To replace the page entirely, use `.custom(directory:contentSecurityPolicy:)`. The server serves `index.html`
for `/` and any other file in that folder by its relative path. Your page reads `/config.json` and uploads
with `POST /upload` as described above.

## Migrating from 1.x

- **`finish(movingInto:)` is now `finish()`,** which returns the folder holding what arrived (or `nil`)
  instead of moving it. Moving, naming and what to do when a move fails are your app's to decide, so
  `BrowserDropError.couldNotMove` is gone. To keep 1.x's behavior, move the folder's items where you want
  them.
- **Progress left `events`:** `.uploadProgress` is replaced by the `progress` stream. `events` no longer
  drops anything, however far behind its reader is.
- **Name conflicts are refused** with 409 and `FailureReason.pathConflict`, where 1.x replaced a folder
  with a file (keeping it in `receivedFiles`) or failed with 500. The bundled page shows the new
  `pathConflict` string. The protocol stays at version 1: a page that doesn't know `path_conflict` shows
  it as a failure.
- **New:** `Configuration.maximumConnections` (64), and the request head must arrive within `idleTimeout`.

## Development

```sh
swift test
xcodebuild test -scheme SwiftBrowserDrop -destination 'platform=iOS Simulator,name=<a simulator>'
```

Run both: the Simulator behaves differently from macOS in places that matter here (an app's file lookups
there are case-sensitive while the Mac's volume underneath isn't).

The tests run the real server on 127.0.0.1 and cover uploads, `finish`, suspend and resume (including quick
restarts), aborted and stalled uploads, the request checks, and serving the page.

## Credits

The idea and the first implementation are by [Pavel Kuzmin (@s00d)](https://github.com/s00d), in
[TortugaPower/BookPlayer#1631](https://github.com/TortugaPower/BookPlayer/pull/1631). This package rebuilds
it as a standalone library.

## License

MIT. See [LICENSE](LICENSE).
