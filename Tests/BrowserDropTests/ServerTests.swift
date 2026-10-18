import Foundation
import Testing

@testable import BrowserDrop

/// These run the real server on 127.0.0.1 and talk to it over TCP.
@Suite("Server")
struct ServerTests {
  // MARK: - Session

  @Test func keepsUploadsInStagingUntilFinish() async throws {
    let server = makeServer()
    try await server.start()
    let port = try await runningPort(server)

    #expect(try await upload(Data("one".utf8), as: "Book/Disc 1/01.mp3", port: port) == 201)
    #expect(try await upload(Data("two".utf8), as: "Book/02.mp3", port: port) == 201)
    #expect(try await upload(Data("loose".utf8), as: "loose.m4b", port: port) == 201)
    #expect(await server.receivedFiles.map(\.relativePath).sorted() == ["Book/02.mp3", "Book/Disc 1/01.mp3", "loose.m4b"])

    let destination = makeTemporaryDirectory()
    #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
    let moved = try await server.finish(movingInto: destination)

    #expect(moved.map(\.lastPathComponent) == ["Book", "loose.m4b"])
    let first = try String(contentsOf: destination.appendingPathComponent("Book/Disc 1/01.mp3"), encoding: .utf8)
    #expect(first == "one")
    #expect(await server.state == .closed)
    #expect(await server.receivedFiles.isEmpty)
  }

  @Test func finishNumbersNamesTakenInTheDestination() async throws {
    let server = makeServer()
    try await server.start()
    let port = try await runningPort(server)
    _ = try await upload(Data("a".utf8), as: "Book/01.mp3", port: port)
    _ = try await upload(Data("b".utf8), as: "loose.m4b", port: port)

    let destination = makeTemporaryDirectory()
    try FileManager.default.createDirectory(at: destination.appendingPathComponent("Book"), withIntermediateDirectories: true)
    try Data().write(to: destination.appendingPathComponent("loose.m4b"))

    let moved = try await server.finish(movingInto: destination)
    #expect(moved.map(\.lastPathComponent) == ["Book (1)", "loose (1).m4b"])
  }

  @Test func uploadingAPathAgainReplacesTheFile() async throws {
    let server = makeServer()
    try await server.start()
    let port = try await runningPort(server)

    #expect(try await upload(Data("first".utf8), as: "a.mp3", port: port) == 201)
    #expect(try await upload(Data("second!".utf8), as: "a.mp3", port: port) == 201)
    #expect(await server.receivedFiles == [BrowserDropServer.ReceivedFile(relativePath: "a.mp3", size: 7)])

    let destination = makeTemporaryDirectory()
    try await server.finish(movingInto: destination)
    #expect(try String(contentsOf: destination.appendingPathComponent("a.mp3"), encoding: .utf8) == "second!")
  }

  @Test func suspendAndResumeKeepThePortAndTheFiles() async throws {
    let server = makeServer()
    try await server.start()
    let port = try await runningPort(server)
    _ = try await upload(Data("a".utf8), as: "a.mp3", port: port)

    await server.suspend()
    #expect(await server.state == .suspended)
    await #expect(throws: (any Error).self) {
      _ = try await upload(Data("b".utf8), as: "b.mp3", port: port)
    }

    try await server.resume()
    #expect(try await runningPort(server) == port)
    #expect(try await upload(Data("b".utf8), as: "b.mp3", port: port) == 201)
    #expect(await server.receivedFiles.map(\.relativePath) == ["a.mp3", "b.mp3"])
    await server.cancel()
  }

  /// The PR this package replaces lost its state here: a replaced listener's late `.cancelled` reset it.
  /// Back-to-back restarts also catch the few milliseconds a stopped listener still holds its port.
  @Test func quickRestartsKeepThePort() async throws {
    let server = makeServer()
    try await server.start()
    let port = try await runningPort(server)

    for _ in 0..<25 {
      await server.suspend()
      try await server.resume()
      #expect(try await runningPort(server) == port)
    }
    // Give any late listener events time to arrive.
    try await Task.sleep(for: .milliseconds(300))

    #expect(await server.state == .running(port: port))
    #expect(try await upload(Data("a".utf8), as: "a.mp3", port: port) == 201)
    await server.cancel()
  }

  /// Closing the upload screen and opening it again straight away must give the same address.
  @Test func aNewSessionGetsThePortTheLastOneJustReleased() async throws {
    let first = makeServer()
    try await first.start()
    let port = try await runningPort(first)
    await first.cancel()

    let second = makeServer { $0.ports = [port, 0] }
    try await second.start()
    #expect(try await runningPort(second) == port)
    await second.cancel()
  }

  @Test func removedItemsAreNotHandedOver() async throws {
    let server = makeServer()
    try await server.start()
    let port = try await runningPort(server)
    _ = try await upload(Data("a".utf8), as: "loose.mp3", port: port)
    _ = try await upload(Data("b".utf8), as: "Book/01.mp3", port: port)
    _ = try await upload(Data("c".utf8), as: "Book/02.mp3", port: port)
    _ = try await upload(Data("d".utf8), as: "Other/Disc 1/01.mp3", port: port)

    try await server.removeReceivedItem(at: "Book")
    try await server.removeReceivedItem(at: "Other/Disc 1/01.mp3")
    #expect(await server.receivedFiles.map(\.relativePath) == ["loose.mp3"])

    // The emptied "Other" folder is gone too, so it isn't handed over as an empty item.
    let destination = makeTemporaryDirectory()
    let moved = try await server.finish(movingInto: destination)
    #expect(moved.map(\.lastPathComponent) == ["loose.mp3"])
  }

  @Test func aRemovedPathCanBeUploadedAgain() async throws {
    let server = makeServer()
    try await server.start()
    let port = try await runningPort(server)
    _ = try await upload(Data("a".utf8), as: "a.mp3", port: port)
    try await server.removeReceivedItem(at: "a.mp3")
    #expect(await server.receivedFiles.isEmpty)

    #expect(try await upload(Data("again".utf8), as: "a.mp3", port: port) == 201)
    #expect(await server.receivedFiles == [BrowserDropServer.ReceivedFile(relativePath: "a.mp3", size: 5)])
    await server.cancel()
  }

  @Test func cancelDeletesEverything() async throws {
    let server = makeServer()
    try await server.start()
    let port = try await runningPort(server)
    _ = try await upload(Data("a".utf8), as: "a.mp3", port: port)
    let stagingFolder = try #require(await server.staging?.root)
    #expect(FileManager.default.fileExists(atPath: stagingFolder.path))

    await server.cancel()
    #expect(await server.state == .closed)
    #expect(!FileManager.default.fileExists(atPath: stagingFolder.path))
    await #expect(throws: BrowserDropError.sessionClosed) {
      try await server.start()
    }
  }

  @Test func removeLeftoversEmptiesTheStagingRoot() throws {
    let root = makeTemporaryDirectory()
    _ = try Staging.create(in: root)
    BrowserDropServer.removeLeftovers(in: root)
    #expect(!FileManager.default.fileExists(atPath: root.path))
  }

  // MARK: - Uploads

  @Test func reportsAnUploadFromStartToFinish() async throws {
    let server = makeServer()
    let recorder = EventRecorder(server)
    try await server.start()
    let port = try await runningPort(server)

    let size = 3 << 20
    #expect(try await upload(Data(count: size), as: "Book/big.mp3", port: port) == 201)
    let file = BrowserDropServer.ReceivedFile(relativePath: "Book/big.mp3", size: Int64(size))
    try await eventually("finished event") { recorder.contains(.uploadFinished(file)) }

    let events = recorder.events
    guard case .uploadStarted(let started) = events.first else {
      Issue.record("First event was \(String(describing: events.first))")
      return
    }
    #expect(started.relativePath == "Book/big.mp3")
    #expect(started.size == Int64(size))
    #expect(events.contains(.uploadProgress(started, receivedBytes: Int64(size))))
    #expect(events.last == .uploadFinished(file))
    await server.cancel()
  }

  @Test func anAbortedUploadLeavesNothingBehind() async throws {
    let server = makeServer()
    let recorder = EventRecorder(server)
    try await server.start()
    let port = try await runningPort(server)

    let client = RawClient(port: port)
    try await client.open()
    try await client.send("POST /upload?path=a.mp3 HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Length: 1000\r\n\r\n")
    try await client.send(Data(count: 100))
    try await eventually("upload started") { recorder.events.contains { if case .uploadStarted = $0 { true } else { false } } }
    client.close()

    try await eventually("failure reported") {
      recorder.contains(.uploadFailed(relativePath: "a.mp3", reason: .disconnected))
    }
    #expect(await server.receivedFiles.isEmpty)
    let incoming = try #require(await server.staging?.incoming)
    #expect(try FileManager.default.contentsOfDirectory(atPath: incoming.path).isEmpty)
    await server.cancel()
  }

  @Test func closesConnectionsThatGoQuiet() async throws {
    let server = makeServer { $0.idleTimeout = .milliseconds(200) }
    let recorder = EventRecorder(server)
    try await server.start()
    let port = try await runningPort(server)

    let client = RawClient(port: port)
    try await client.open()
    try await client.send("POST /upload?path=a.mp3 HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Length: 10\r\n\r\nabc")
    let (_, closed) = try await client.receiveAll(timeout: .seconds(3))

    #expect(closed)
    try await eventually("timeout reported") { recorder.contains(.uploadFailed(relativePath: "a.mp3", reason: .timedOut)) }
    await server.cancel()
  }

  @Test(arguments: ["../x.mp3", "/abs.mp3", "a/../b.mp3", ".hidden/x.mp3", "a//b.mp3", "a\u{0}.mp3"])
  func refusesPathsThatCouldEscape(_ path: String) async throws {
    let server = makeServer()
    try await server.start()
    #expect(try await upload(Data("x".utf8), as: path, port: try await runningPort(server)) == 400)
    #expect(await server.receivedFiles.isEmpty)
    await server.cancel()
  }

  @Test func refusesTypesThatArentAllowed() async throws {
    let server = makeServer()
    try await server.start()
    #expect(try await upload(Data("x".utf8), as: "notes.txt", port: try await runningPort(server)) == 400)
    await server.cancel()
  }

  @Test func refusesFilesOverTheSizeLimit() async throws {
    let server = makeServer { $0.maximumFileSize = 10 }
    let recorder = EventRecorder(server)
    try await server.start()
    let port = try await runningPort(server)

    #expect(try await upload(Data(count: 11), as: "a.mp3", port: port) == 413)
    #expect(try await upload(Data(count: 10), as: "b.mp3", port: port) == 201)
    try await eventually("too large reported") { recorder.contains(.uploadFailed(relativePath: "a.mp3", reason: .tooLarge)) }
    await server.cancel()
  }

  @Test func refusesUploadsThatWouldFillTheDevice() async throws {
    let server = makeServer {
      $0.availableCapacity = { _ in 1_000 }
      $0.reservedFreeSpace = 500
    }
    let recorder = EventRecorder(server)
    try await server.start()
    let port = try await runningPort(server)

    #expect(try await upload(Data(count: 600), as: "a.mp3", port: port) == 507)
    #expect(try await upload(Data(count: 400), as: "b.mp3", port: port) == 201)
    try await eventually("no space reported") {
      recorder.contains(.uploadFailed(relativePath: "a.mp3", reason: .insufficientStorage))
    }
    await server.cancel()
  }

  // MARK: - Request checks

  @Test func refusesUploadsFromOtherOrigins() async throws {
    let server = makeServer()
    try await server.start()
    let port = try await runningPort(server)

    let foreign = try await rawUpload(port: port, headers: ["Host: 127.0.0.1:\(port)", "Origin: http://evil.example"])
    #expect(RawClient.status(of: foreign) == 403)
    let own = try await rawUpload(port: port, headers: ["Host: 127.0.0.1:\(port)", "Origin: http://127.0.0.1:\(port)"])
    #expect(RawClient.status(of: own) == 201)
    await server.cancel()
  }

  /// DNS rebinding: a website points its own domain at the device, and the browser sends that domain as `Host`.
  @Test func refusesPublicHostNames() async throws {
    let server = makeServer()
    try await server.start()
    let port = try await runningPort(server)

    let response = try await rawUpload(port: port, headers: ["Host: evil.example:\(port)", "Origin: http://evil.example:\(port)"])
    #expect(RawClient.status(of: response) == 403)
    await server.cancel()
  }

  @Test func requiresAContentLength() async throws {
    let server = makeServer()
    try await server.start()
    let port = try await runningPort(server)

    let missing = try await rawRequest(port: port, "POST /upload?path=a.mp3 HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
    #expect(RawClient.status(of: missing) == 411)
    let chunked = try await rawRequest(
      port: port,
      "POST /upload?path=a.mp3 HTTP/1.1\r\nHost: 127.0.0.1\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n0\r\n\r\n"
    )
    #expect(RawClient.status(of: chunked) == 411)
    await server.cancel()
  }

  @Test func honorsExpectContinue() async throws {
    let server = makeServer()
    try await server.start()
    let port = try await runningPort(server)

    let client = RawClient(port: port)
    try await client.open()
    try await client.send(
      "POST /upload?path=a.mp3 HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 5\r\nExpect: 100-continue\r\n\r\n"
    )
    let interim = try await client.receive(until: "\r\n\r\n")
    #expect(interim.hasPrefix("HTTP/1.1 100 Continue"))
    try await client.send("hello")
    let (response, _) = try await client.receiveAll()
    #expect(RawClient.status(of: interim + response) == 201)
    #expect(await server.receivedFiles.map(\.relativePath) == ["a.mp3"])
    await server.cancel()
  }

  @Test func refusesMalformedRequests() async throws {
    let server = makeServer()
    try await server.start()
    let port = try await runningPort(server)
    #expect(RawClient.status(of: try await rawRequest(port: port, "BREW /pot HTTP/1.1\r\nHost: x\r\n\r\n")) == 405)
    #expect(RawClient.status(of: try await rawRequest(port: port, "GET / HTTP/9.9\r\n\r\n")) == 400)
    await server.cancel()
  }

  // MARK: - Page

  @Test func servesTheBundledPage() async throws {
    let server = makeServer()
    try await server.start()
    let port = try await runningPort(server)

    let (status, response, body) = try await get("/", port: port)
    #expect(status == 200)
    #expect(response.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("text/html") == true)
    #expect(response.value(forHTTPHeaderField: "Content-Security-Policy")?.contains("script-src 'self'") == true)
    #expect(String(decoding: body, as: UTF8.self).contains("/app.js"))
    #expect(try await get("/app.js", port: port).status == 200)
    #expect(try await get("/app.css", port: port).status == 200)
    #expect(try await get("/missing.js", port: port).status == 404)
    await server.cancel()
  }

  @Test func describesItselfInConfigJSON() async throws {
    let server = makeServer {
      $0.maximumFileSize = 1_234
      $0.pageSettings = .init(title: "My App", language: "es", accentColor: "#FF8800", strings: ["title": "Subir"])
    }
    try await server.start()
    let (status, _, body) = try await get("/config.json", port: try await runningPort(server))
    #expect(status == 200)

    let config = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(config["protocolVersion"] as? Int == 1)
    #expect(config["title"] as? String == "My App")
    #expect(config["language"] as? String == "es")
    #expect(config["accentColor"] as? String == "#FF8800")
    #expect(config["allowedExtensions"] as? [String] == ["m4b", "mp3"])
    #expect(config["maximumFileSize"] as? Int == 1_234)
    #expect(config["maximumConcurrentUploads"] as? Int == 3)
    #expect(config["strings"] as? [String: String] == ["title": "Subir"])
    await server.cancel()
  }

  @Test func dropsAccentColorsThatArentHex() async throws {
    let server = makeServer { $0.pageSettings.accentColor = "red; background: url(x)" }
    try await server.start()
    let (_, _, body) = try await get("/config.json", port: try await runningPort(server))
    let config = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(config["accentColor"] == nil)
    await server.cancel()
  }

  @Test func customPageFilesStayInsideTheirFolder() async throws {
    let root = makeTemporaryDirectory()
    let page = root.appendingPathComponent("page", isDirectory: true)
    try FileManager.default.createDirectory(at: page, withIntermediateDirectories: true)
    try Data("custom".utf8).write(to: page.appendingPathComponent("index.html"))
    try Data("secret".utf8).write(to: root.appendingPathComponent("secret.txt"))
    try FileManager.default.createSymbolicLink(
      at: page.appendingPathComponent("link.txt"),
      withDestinationURL: root.appendingPathComponent("secret.txt")
    )

    let server = makeServer { $0.page = .custom(directory: page) }
    try await server.start()
    let port = try await runningPort(server)

    let (status, _, body) = try await get("/", port: port)
    #expect(status == 200)
    #expect(String(decoding: body, as: UTF8.self) == "custom")
    for path in ["/../secret.txt", "/%2e%2e/secret.txt", "/link.txt", "/page/../../secret.txt"] {
      let response = try await rawRequest(port: port, "GET \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
      #expect(RawClient.status(of: response) == 404, "\(path)")
      #expect(!response.contains("secret"), "\(path)")
    }
    await server.cancel()
  }

  // MARK: - Helpers

  private func rawRequest(port: UInt16, _ request: String) async throws -> String {
    let client = RawClient(port: port)
    try await client.open()
    try await client.send(request)
    defer { client.close() }
    return try await client.receiveAll().text
  }

  private func rawUpload(port: UInt16, headers: [String]) async throws -> String {
    let head = (["POST /upload?path=a.mp3 HTTP/1.1"] + headers + ["Content-Length: 3"]).joined(separator: "\r\n")
    return try await rawRequest(port: port, head + "\r\n\r\nabc")
  }
}
