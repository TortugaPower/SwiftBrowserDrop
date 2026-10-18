import Foundation
import Network
import os

@testable import BrowserDrop

struct TestFailure: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}

func makeTemporaryDirectory() -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("BrowserDropTests-\(UUID().uuidString)", isDirectory: true)
  try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

/// A server on any free port that accepts mp3 and m4b, staging in its own temporary folder.
func makeServer(_ configure: (inout BrowserDropServer.Configuration) -> Void = { _ in }) -> BrowserDropServer {
  var configuration = BrowserDropServer.Configuration(
    ports: [0],
    allowedExtensions: ["mp3", "m4b"],
    stagingRoot: makeTemporaryDirectory()
  )
  configure(&configuration)
  return BrowserDropServer(configuration: configuration)
}

func runningPort(_ server: BrowserDropServer) async throws -> UInt16 {
  guard case .running(let port) = await server.state else { throw TestFailure("server isn't running") }
  return port
}

let session = URLSession(configuration: .ephemeral)

/// Uploads the way the bundled page does, minus the browser's `Origin`.
func upload(_ data: Data, as path: String, port: UInt16) async throws -> Int {
  let encoded = path.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
  var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/upload?path=\(encoded)")!)
  request.httpMethod = "POST"
  let (_, response) = try await session.upload(for: request, from: data)
  return (response as! HTTPURLResponse).statusCode
}

func get(_ path: String, port: UInt16) async throws -> (status: Int, response: HTTPURLResponse, body: Data) {
  let (body, response) = try await session.data(from: URL(string: "http://127.0.0.1:\(port)\(path)")!)
  let http = response as! HTTPURLResponse
  return (http.statusCode, http, body)
}

/// Polls until `condition` holds.
func eventually(
  timeout: Duration = .seconds(3),
  _ what: String = "condition",
  _ condition: () async throws -> Bool
) async throws {
  let deadline = ContinuousClock.now + timeout
  while ContinuousClock.now < deadline {
    if try await condition() { return }
    try await Task.sleep(for: .milliseconds(20))
  }
  throw TestFailure("\(what) didn't happen within \(timeout)")
}

/// Collects a server's events as they arrive.
final class EventRecorder: Sendable {
  private let storage = OSAllocatedUnfairLock<[BrowserDropServer.Event]>(initialState: [])
  private let task: Task<Void, Never>

  init(_ server: BrowserDropServer) {
    let stream = server.events
    let storage = storage
    task = Task {
      for await event in stream {
        storage.withLock { $0.append(event) }
      }
    }
  }

  deinit { task.cancel() }

  var events: [BrowserDropServer.Event] { storage.withLock { $0 } }

  func contains(_ event: BrowserDropServer.Event) -> Bool { events.contains(event) }
}

/// A bare TCP client for what URLSession won't send: a foreign `Host` or `Origin`, a missing length,
/// a body cut short, `Expect: 100-continue`.
final class RawClient: @unchecked Sendable {
  private let connection: NWConnection
  private let queue = DispatchQueue(label: "RawClient")

  init(port: UInt16) {
    connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
  }

  func open() async throws {
    let resumed = OSAllocatedUnfairLock(initialState: false)
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
      connection.stateUpdateHandler = { state in
        let result: Result<Void, any Error>?
        switch state {
        case .ready: result = .success(())
        case .failed(let error), .waiting(let error): result = .failure(error)
        default: result = nil
        }
        guard let result, !resumed.withLock({ defer { $0 = true }; return $0 }) else { return }
        continuation.resume(with: result)
      }
      connection.start(queue: queue)
    }
  }

  func send(_ text: String) async throws {
    try await send(Data(text.utf8))
  }

  func send(_ data: Data) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
      connection.send(content: data, completion: .contentProcessed { error in
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
      })
    }
  }

  /// Reads until the text contains `marker` or the server closes.
  func receive(until marker: String, timeout: Duration = .seconds(3)) async throws -> String {
    var text = ""
    let deadline = ContinuousClock.now + timeout
    while !text.contains(marker), ContinuousClock.now < deadline {
      let (chunk, closed) = try await receiveChunk(timeout: deadline - ContinuousClock.now)
      text += String(decoding: chunk, as: UTF8.self)
      if closed { break }
    }
    return text
  }

  /// Reads until the server closes the connection; gives up after `timeout`.
  func receiveAll(timeout: Duration = .seconds(3)) async throws -> (text: String, closedByServer: Bool) {
    var data = Data()
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
      let (chunk, closed) = try await receiveChunk(timeout: deadline - ContinuousClock.now)
      data.append(chunk)
      if closed { return (String(decoding: data, as: UTF8.self), true) }
    }
    return (String(decoding: data, as: UTF8.self), false)
  }

  private func receiveChunk(timeout: Duration) async throws -> (Data, closed: Bool) {
    let resumed = OSAllocatedUnfairLock(initialState: false)
    return await withCheckedContinuation { (continuation: CheckedContinuation<(Data, closed: Bool), Never>) in
      let finish: @Sendable ((Data, closed: Bool)) -> Void = { result in
        guard !resumed.withLock({ defer { $0 = true }; return $0 }) else { return }
        continuation.resume(returning: result)
      }
      connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
        // A reset counts as closed, too.
        finish((data ?? Data(), isComplete || error != nil))
      }
      queue.asyncAfter(deadline: .now() + max(timeout.timeInterval, 0)) {
        finish((Data(), false))
      }
    }
  }

  func close() {
    connection.cancel()
  }

  static func status(of response: String) -> Int? {
    // Skip a `100 Continue` interim response.
    let finalResponse = response.components(separatedBy: "\r\n\r\n").first { !$0.hasPrefix("HTTP/1.1 100") } ?? ""
    let parts = finalResponse.split(separator: " ", maxSplits: 2)
    return parts.count >= 2 ? Int(parts[1]) : nil
  }
}
