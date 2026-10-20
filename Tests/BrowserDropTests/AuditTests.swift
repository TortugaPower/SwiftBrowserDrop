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

  // A1: a file uploaded where a folder of earlier uploads is replaces it (last upload wins), and
  // receivedFiles must not keep listing the folder's files.
  @Test func fileUploadReplacingAFolderKeepsReceivedFilesTrue() async throws {
    let server = makeServer()
    try await server.start()
    let port = try await runningPort(server)
    #expect(try await upload(Data("chapter".utf8), as: "Book.mp3/01.mp3", port: port) == 201)
    #expect(try await upload(Data("other".utf8), as: "Other/02.mp3", port: port) == 201)
    #expect(try await upload(Data("x".utf8), as: "Book.mp3", port: port) == 201)

    let files = try #require(await server.staging?.files)
    #expect(try String(contentsOf: files.appendingPathComponent("Book.mp3"), encoding: .utf8) == "x")
    #expect(await ghostEntries(server) == [], "receivedFiles lists files that no longer exist")
    #expect(await server.receivedFiles.map(\.relativePath).sorted() == ["Book.mp3", "Other/02.mp3"])
    await server.cancel()
  }

  // A1b: the reverse: an upload into a folder whose name an earlier file has replaces that file.
  @Test func folderUploadReplacingAFileKeepsReceivedFilesTrue() async throws {
    let server = makeServer()
    try await server.start()
    let port = try await runningPort(server)
    #expect(try await upload(Data("x".utf8), as: "Book.mp3", port: port) == 201)
    #expect(try await upload(Data("other".utf8), as: "Other.mp3", port: port) == 201)
    #expect(try await upload(Data("chapter".utf8), as: "Book.mp3/Disc 1/01.mp3", port: port) == 201)

    let files = try #require(await server.staging?.files)
    #expect(try String(contentsOf: files.appendingPathComponent("Book.mp3/Disc 1/01.mp3"), encoding: .utf8) == "chapter")
    #expect(await ghostEntries(server) == [], "receivedFiles lists files that no longer exist")
    #expect(await server.receivedFiles.map(\.relativePath).sorted() == ["Book.mp3/Disc 1/01.mp3", "Other.mp3"])
    #expect(try FileManager.default.contentsOfDirectory(atPath: await server.staging!.incoming.path).isEmpty)
    await server.cancel()
  }

  // A2: a failed move in finish() must not delete the uploads.
  @Test func finishIntoAMissingFolderKeepsTheUploads() async throws {
    let server = makeServer()
    try await server.start()
    let port = try await runningPort(server)
    #expect(try await upload(Data("precious".utf8), as: "a.mp3", port: port) == 201)
    let stagingRoot = try #require(await server.staging?.root)

    let missing = makeTemporaryDirectory().appendingPathComponent("does-not-exist")
    await #expect(throws: BrowserDropError.self) { try await server.finish(movingInto: missing) }

    let survived = FileManager.default.fileExists(atPath: stagingRoot.appendingPathComponent("files/a.mp3").path)
    #expect(survived, "upload deleted after finish() failed to move it; nothing can recover it")
    #expect(await server.unmovedItems.map(\.lastPathComponent) == ["a.mp3"])
  }

  // A3: a 255-byte name that is taken in the destination gets " (1)" appended: 259 bytes, move fails,
  // and the file is deleted with staging.
  @Test func finishWithALongTakenNameKeepsTheFile() async throws {
    let server = makeServer()
    try await server.start()
    let port = try await runningPort(server)
    let name = String(repeating: "a", count: 251) + ".mp3"
    #expect(try await upload(Data("long".utf8), as: name, port: port) == 201)

    let destination = makeTemporaryDirectory()
    try Data().write(to: destination.appendingPathComponent(name))
    let moved = try? await server.finish(movingInto: destination)
    #expect(moved?.count == 1, "long-named upload was not delivered (and staging is wiped)")
  }

  // A4: on a case-insensitive volume (macOS default) two paths differing only in case are one file,
  // yet receivedFiles lists two.
  @Test func caseOnlyDifferencesDoNotDuplicateReceivedFiles() async throws {
    let server = makeServer()
    try await server.start()
    let port = try await runningPort(server)
    let root = try #require(await server.staging?.root)
    let caseSensitive = (try root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])).volumeSupportsCaseSensitiveNames ?? true
    try #require(!caseSensitive, "volume is case-sensitive; probe not applicable")

    #expect(try await upload(Data("one".utf8), as: "a.mp3", port: port) == 201)
    #expect(try await upload(Data("two".utf8), as: "A.mp3", port: port) == 201)
    let received = await server.receivedFiles.count
    let destination = makeTemporaryDirectory()
    let moved = try await server.finish(movingInto: destination)
    #expect(received == moved.count, "receivedFiles reported \(received) files, finish delivered \(moved.count)")
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
    for index in 0..<400 {
      let upload = BrowserDropServer.Upload(id: index, relativePath: "f\(index).mp3", size: 1)
      await server.emit(.uploadStarted(upload))
      await server.emit(.uploadProgress(upload, receivedBytes: 1))
      await server.emit(.uploadFinished(.init(relativePath: upload.relativePath, size: 1)))
    }
    let recorder = EventRecorder(server)  // consumer attaches late, as a busy main actor would catch up
    await server.cancel()  // finishes the stream
    try await eventually { recorder.events.count >= 1200 || recorder.events.count == 1000 }
    try await Task.sleep(for: .milliseconds(100))
    let finished = recorder.events.filter { if case .uploadFinished = $0 { true } else { false } }.count
    #expect(finished == 400, "consumer saw \(finished) of 400 uploadFinished events")
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
