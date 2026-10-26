import Foundation
import Testing

@testable import BrowserDrop

/// Audit probes. Each test asserts the safe behavior; a failure confirms a defect.
@Suite("Audit", .serialized)
struct AuditTests {
  /// Every entry in `receivedFiles` must exist as a regular file in staging.
  func ghostEntries(_ server: BrowserDropServer) async -> [String] {
    guard let files = await server.staging?.files else { return [] }
    var ghosts: [String] = []
    for file in await server.receivedFiles {
      var isDirectory: ObjCBool = false
      let path = files.appendingPathComponent(file.relativePath).path
      if !FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) || isDirectory.boolValue {
        ghosts.append(file.relativePath)
      }
    }
    return ghosts
  }

  // A1: a file uploaded where a folder of earlier uploads is would replace the folder's files. It's
  // refused instead, and nothing already received changes.
  @Test func aFileWhereAFolderIsIsRefused() async throws {
    let server = makeServer()
    let recorder = EventRecorder(server)
    try await server.start()
    let port = try await runningPort(server)
    #expect(try await upload(Data("chapter".utf8), as: "Book.mp3/01.mp3", port: port) == 201)
    #expect(try await upload(Data("x".utf8), as: "Book.mp3", port: port) == 409)

    let files = try #require(await server.staging?.files)
    #expect(try String(contentsOf: files.appendingPathComponent("Book.mp3/01.mp3"), encoding: .utf8) == "chapter")
    #expect(await server.receivedFiles.map(\.relativePath) == ["Book.mp3/01.mp3"])
    #expect(await ghostEntries(server) == [])
    try await eventually("conflict reported") {
      recorder.contains(.uploadFailed(relativePath: "Book.mp3", reason: .pathConflict))
    }
    await server.cancel()
  }

  // A1b: the reverse: an upload into a folder whose name an earlier file has.
  @Test func aFolderWhereAFileIsIsRefused() async throws {
    let server = makeServer()
    try await server.start()
    let port = try await runningPort(server)
    #expect(try await upload(Data("x".utf8), as: "Book.mp3", port: port) == 201)
    #expect(try await upload(Data("chapter".utf8), as: "Book.mp3/Disc 1/01.mp3", port: port) == 409)

    let staging = try #require(await server.staging)
    #expect(try String(contentsOf: staging.files.appendingPathComponent("Book.mp3"), encoding: .utf8) == "x")
    #expect(await server.receivedFiles.map(\.relativePath) == ["Book.mp3"])
    #expect(try FileManager.default.contentsOfDirectory(atPath: staging.incoming.path).isEmpty)
    await server.cancel()
  }

  // A1c: the name is free when the upload starts, but another one takes it before this one is stored.
  // The check when storing catches it.
  @Test func aNameTakenWhileUploadingIsRefusedWhenStored() async throws {
    let server = makeServer()
    try await server.start()
    let port = try await runningPort(server)

    let client = RawClient(port: port)
    try await client.open()
    try await client.send("POST /upload?path=Book.mp3/01.mp3 HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Length: 10\r\n\r\n")
    try await client.send(Data(count: 5))
    try await eventually("upload in flight") { await !server.inFlight.isEmpty }

    #expect(try await upload(Data("x".utf8), as: "Book.mp3", port: port) == 201)
    try await client.send(Data(count: 5))
    #expect(RawClient.status(of: try await client.receive(until: "\r\n\r\n")) == 409)
    client.close()

    #expect(await server.receivedFiles.map(\.relativePath) == ["Book.mp3"])
    let incoming = try #require(await server.staging?.incoming)
    #expect(try FileManager.default.contentsOfDirectory(atPath: incoming.path).isEmpty)
    await server.cancel()
  }

  // A4: on a case-insensitive volume (macOS default) two paths differing only in case are one name. The
  // second is refused, for a file and for a folder, instead of replacing the first behind its back.
  @Test(.enabled(if: temporaryVolumeIsCaseInsensitive))
  func aNameInAnotherCaseIsRefusedOnACaseInsensitiveVolume() async throws {
    let server = makeServer()
    try await server.start()
    let port = try await runningPort(server)

    #expect(try await upload(Data("one".utf8), as: "a.mp3", port: port) == 201)
    #expect(try await upload(Data("two".utf8), as: "A.mp3", port: port) == 409)
    #expect(try await upload(Data("three".utf8), as: "Book/01.mp3", port: port) == 201)
    #expect(try await upload(Data("four".utf8), as: "book/02.mp3", port: port) == 409)

    #expect(await server.receivedFiles.map(\.relativePath) == ["a.mp3", "Book/01.mp3"])
    let folder = try #require(try await server.finish())
    #expect(try names(in: folder) == ["Book", "a.mp3"])
    #expect(try String(contentsOf: folder.appendingPathComponent("a.mp3"), encoding: .utf8) == "one")
  }

  // A6: header slowloris: one byte per (idleTimeout - ε) keeps a connection that never sent a request.
  @Test func aHeadThatNeverEndsIsClosed() async throws {
    let server = makeServer { $0.idleTimeout = .milliseconds(300) }
    try await server.start()
    let port = try await runningPort(server)
    let client = RawClient(port: port)
    try await client.open()
    try await client.send("GET / HTTP/1.1\r\n")
    var closedEarly = false
    for _ in 0..<20 {  // 3 s, 10× the idle timeout
      do { try await client.send("X-A: b\r\n") } catch { closedEarly = true; break }
      let (_, closed) = try await client.receiveAll(timeout: .milliseconds(150))
      if closed { closedEarly = true; break }
    }
    client.close()
    #expect(closedEarly, "connection kept open 10× idleTimeout without ever completing a request")
    await server.cancel()
  }

  // A7: no cap on connections. Each one holds a descriptor and an iOS app has 256 by default, so idle
  // connections from another machine could exhaust the app's descriptors.
  // Counts the process's descriptors instead of lowering RLIMIT_NOFILE: that limit is process-wide and
  // would starve the suites running in parallel.
  @Test func idleConnectionsCannotExhaustFileDescriptors() async throws {
    func openDescriptors() -> Int { (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? 0 }
    let server = makeServer { $0.idleTimeout = .seconds(30) }
    try await server.start()
    let port = try await runningPort(server)
    let cap = BrowserDropServer.Configuration().maximumConnections
    let before = openDescriptors()

    // The clients live in this process too: each holds one descriptor of its own, the server one more
    // for each connection it keeps.
    var clients: [RawClient] = []
    for _ in 0..<200 {
      let client = RawClient(port: port)
      try await client.open()
      clients.append(client)
    }
    try await Task.sleep(for: .milliseconds(500))
    let held = openDescriptors() - before - clients.count
    for client in clients { client.close() }

    // Slack for descriptors the suites running in parallel open meanwhile.
    #expect(held <= cap + 40, "server holds \(held) descriptors for \(clients.count) idle connections (cap \(cap))")
    await server.cancel()
  }

  // A8: the event buffer kept only the newest 1000; a consumer that fell behind lost uploadFinished
  // events. Emitted directly: this is about the buffer, and 400 real uploads only add connection churn.
  @Test func uploadFinishedEventsAreNotDropped() async throws {
    let server = makeServer()
    for index in 0..<1_000 {
      let upload = BrowserDropServer.Upload(id: index, relativePath: "f\(index).mp3", size: 1)
      await server.emit(.uploadStarted(upload))
      await server.emit(.uploadFinished(.init(relativePath: upload.relativePath, size: 1)))
    }
    let recorder = EventRecorder(server)  // consumer attaches late, as a busy main actor would catch up
    await server.cancel()  // finishes the stream
    try await eventually { recorder.events.count >= 2_000 }
    let finished = recorder.events.filter { if case .uploadFinished = $0 { true } else { false } }.count
    #expect(finished == 1_000, "consumer saw \(finished) of 1000 uploadFinished events")
  }

  // A9: a refused upload with Expect: 100-continue holds the connection for the whole idleTimeout.
  @Test func refusedExpectContinueUploadIsClosedPromptly() async throws {
    let server = makeServer { $0.idleTimeout = .seconds(5) }
    try await server.start()
    let port = try await runningPort(server)
    let client = RawClient(port: port)
    try await client.open()
    try await client.send(
      "POST /upload?path=a.txt HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Length: 1000\r\nExpect: 100-continue\r\n\r\n")
    let start = ContinuousClock.now
    let (text, closed) = try await client.receiveAll(timeout: .seconds(4))
    client.close()
    #expect(RawClient.status(of: text) == 400)
    #expect(closed, "connection still held \(ContinuousClock.now - start) after the 400")
    await server.cancel()
  }

  // A10: one slow connection must not block others (are connections served concurrently?).
  @Test func anIdleConnectionDoesNotBlockOthers() async throws {
    let server = makeServer()
    try await server.start()
    let port = try await runningPort(server)
    let idle = RawClient(port: port)
    try await idle.open()
    try await idle.send("POST /upload?path=a.mp3 HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Length: 100000\r\n\r\n")
    let start = ContinuousClock.now
    let (status, _, _) = try await get("/config.json", port: port)
    #expect(status == 200)
    #expect(ContinuousClock.now - start < .seconds(1))
    idle.close()
    await server.cancel()
  }

  // A11: a valid-by-rules deep path whose absolute staging path exceeds PATH_MAX.
  @Test func pathsTheRulesAcceptCanBeStored() async throws {
    let server = makeServer()
    try await server.start()
    let port = try await runningPort(server)
    let segment = String(repeating: "d", count: 200)
    let path = Array(repeating: segment, count: 4).joined(separator: "/") + "/f.mp3"  // ~810 bytes < 1024
    #expect(PathRules.segments(path) != nil)
    let status = try await upload(Data("x".utf8), as: path, port: port)
    #expect(status == 201, "rules accept the path but storing it answers \(status)")
    await server.cancel()
  }
}
