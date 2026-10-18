import Foundation
import Network

extension BrowserDropServer {
  /// Bodies of refused requests are read and discarded up to this size, so the browser sees the response
  /// instead of a reset.
  static let drainLimit: Int64 = 8 << 20
  static let receiveChunk = 256 * 1024

  /// What one read from the browser gave.
  enum Chunk: Sendable {
    case data(Data)
    /// The browser closed the connection.
    case closed
    /// The session stopped: ``suspend()``, ``finish(movingInto:)`` or ``cancel()``.
    case cancelled
    /// Nothing arrived for ``Configuration/idleTimeout``.
    case timedOut
  }

  // MARK: - One request per connection

  /// Serves one request, then returns, which closes the connection.
  func serve(_ connection: NetworkConnection<TCP>) async {
    var buffer = Data()
    while true {
      if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
        let headData = buffer.subdata(in: buffer.startIndex..<end.lowerBound)
        let body = buffer.subdata(in: end.upperBound..<buffer.endIndex)
        guard headData.count <= HTTPRequestHead.maximumSize else {
          await send(.error(431, "headers_too_large", "Request headers are too large."), on: connection)
          return
        }
        guard let head = HTTPRequestHead.parse(headData) else {
          await send(.error(400, "bad_request", "The request couldn't be read."), on: connection)
          return
        }
        await route(head, body: body, on: connection)
        return
      }
      guard buffer.count <= HTTPRequestHead.maximumSize else {
        await send(.error(431, "headers_too_large", "Request headers are too large."), on: connection)
        return
      }
      guard case .data(let data) = await receive(from: connection) else { return }
      buffer.append(data)
    }
  }

  private func route(_ head: HTTPRequestHead, body: Data, on connection: NetworkConnection<TCP>) async {
    let unread = max(0, (head.contentLength ?? 0) - Int64(body.count))
    switch (head.method, head.path) {
    case ("POST", "/upload"):
      await receiveUpload(head, body: body, from: connection)
    case ("GET", "/config.json"):
      await send(configResponse(), on: connection)
    case ("GET", _):
      await send(pageFileResponse(for: head.path), on: connection)
    default:
      await refuse(.error(405, "method_not_allowed", "Only GET and POST /upload are supported."), unread: unread, on: connection)
    }
  }

  // MARK: - Uploads

  private func receiveUpload(_ head: HTTPRequestHead, body: Data, from connection: NetworkConnection<TCP>) async {
    let unread = max(0, (head.contentLength ?? 0) - Int64(body.count))
    let host = head.headers["host"]

    guard RequestRules.isLocalHost(host),
      RequestRules.isSameOrigin(origin: head.headers["origin"], host: host)
    else {
      await refuse(.error(403, "forbidden", "Uploads must come from this device's own page."), unread: unread, on: connection)
      return
    }
    guard head.headers["transfer-encoding"] == nil, let size = head.contentLength else {
      await send(.error(411, "length_required", "Send the file with a Content-Length."), on: connection)
      return
    }
    guard let rawPath = head.query["path"] else {
      await refuse(.error(400, "invalid_path", "The path query parameter is missing."), unread: unread, on: connection)
      return
    }

    let relativePath: String
    switch PathRules.uploadPath(rawPath, allowedExtensions: configuration.allowedExtensions) {
    case .success(let path):
      relativePath = path
    case .failure(.unsupportedType):
      await refuse(.error(400, "unsupported_type", "This file type isn't accepted."), unread: unread, on: connection)
      return
    case .failure(.invalidPath):
      await refuse(.error(400, "invalid_path", "The path isn't a valid relative path."), unread: unread, on: connection)
      return
    }

    guard size <= configuration.maximumFileSize else {
      emit(.uploadFailed(relativePath: relativePath, reason: .tooLarge))
      await refuse(.error(413, "too_large", "The file is larger than this device accepts."), unread: unread, on: connection)
      return
    }
    guard let staging, hasRoom(for: size, in: staging) else {
      emit(.uploadFailed(relativePath: relativePath, reason: .insufficientStorage))
      await refuse(.error(507, "insufficient_storage", "There isn't enough free space on this device."), unread: unread, on: connection)
      return
    }
    guard let (incomingFile, handle) = try? staging.makeIncomingFile() else {
      emit(.uploadFailed(relativePath: relativePath, reason: .writeFailed))
      await refuse(.error(500, "write_failed", "The file couldn't be written."), unread: unread, on: connection)
      return
    }

    nextUploadID += 1
    let upload = Upload(id: nextUploadID, relativePath: relativePath, size: size)
    inFlight[upload.id] = (size, 0)
    defer { inFlight[upload.id] = nil }
    emit(.uploadStarted(upload))

    if head.expectsContinue, body.isEmpty, size > 0 {
      try? await connection.send(HTTPResponse.continueInterim)
    }

    // Stream the body into the incoming file. Every way out of this loop but a complete file is a failure.
    let progressStep = max(512 << 10, size / 100)
    var received: Int64 = 0
    var reported: Int64 = 0
    var pending = body
    var failure: FailureReason?
    while received < size {
      if pending.isEmpty {
        switch await receive(from: connection) {
        case .data(let data): pending = data
        case .closed: failure = .disconnected
        case .cancelled: failure = .cancelled
        case .timedOut: failure = .timedOut
        }
        if failure != nil { break }
      }
      let chunk = pending.prefix(Int(min(Int64(pending.count), size - received)))
      pending = Data()
      do {
        try handle.write(contentsOf: chunk)
      } catch {
        failure = Self.isOutOfSpace(error) ? .insufficientStorage : .writeFailed
        break
      }
      received += Int64(chunk.count)
      inFlight[upload.id] = (size, received)
      if received < size, received - reported >= progressStep {
        reported = received
        emit(.uploadProgress(upload, receivedBytes: received))
      }
    }
    try? handle.close()

    if failure == nil {
      do {
        try staging.commit(incomingFile, to: relativePath)
      } catch {
        failure = .writeFailed
      }
    }
    if let failure {
      try? FileManager.default.removeItem(at: incomingFile)
      emit(.uploadFailed(relativePath: relativePath, reason: failure))
      switch failure {
      case .insufficientStorage:
        await send(.error(507, "insufficient_storage", "There isn't enough free space on this device."), on: connection)
      case .writeFailed:
        await send(.error(500, "write_failed", "The file couldn't be written."), on: connection)
      default:
        break  // The connection is gone or the session stopped: nobody to answer.
      }
      return
    }

    let file = ReceivedFile(relativePath: relativePath, size: size)
    if let index = receivedFiles.firstIndex(where: { $0.relativePath == relativePath }) {
      receivedFiles[index] = file
    } else {
      receivedFiles.append(file)
    }
    emit(.uploadProgress(upload, receivedBytes: size))
    emit(.uploadFinished(file))
    await send(.json(201, ["path": relativePath]), on: connection)
  }

  /// Whether `size` more bytes leave ``Configuration/reservedFreeSpace`` free, counting what the uploads
  /// already in flight still have to write.
  private func hasRoom(for size: Int64, in staging: Staging) -> Bool {
    guard let available = configuration.availableCapacity(staging.root) else { return true }
    let pending = inFlight.values.reduce(Int64(0)) { $0 + $1.size - $1.received }
    return available - pending - size >= configuration.reservedFreeSpace
  }

  private static func isOutOfSpace(_ error: any Error) -> Bool {
    let error = error as NSError
    return error.code == NSFileWriteOutOfSpaceError || (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOSPC))
  }

  // MARK: - Reading and answering

  /// The next chunk the browser sends, or why there isn't one.
  ///
  /// `receive` returns empty data both when the browser closes the connection and when the session cancels
  /// this task; `Task.isCancelled` tells them apart.
  nonisolated func receive(from connection: NetworkConnection<TCP>) async -> Chunk {
    let timeout = configuration.idleTimeout
    return await withTaskGroup(of: Chunk.self) { group in
      group.addTask {
        let content = (try? await connection.receive(atLeast: 1, atMost: Self.receiveChunk).content) ?? Data()
        if !content.isEmpty { return .data(content) }
        return Task.isCancelled ? .cancelled : .closed
      }
      group.addTask {
        do {
          try await Task.sleep(for: timeout)
          return .timedOut
        } catch {
          return .cancelled
        }
      }
      let first = await group.next() ?? .cancelled
      group.cancelAll()
      return Task.isCancelled ? .cancelled : first
    }
  }

  /// Sends a final response and closes our side of the connection.
  private func send(_ response: HTTPResponse, on connection: NetworkConnection<TCP>) async {
    try? await connection.send(response.serialized(), endOfStream: true)
  }

  /// Answers a request we won't serve, then reads and discards the rest of its body (up to ``drainLimit``):
  /// closing with unread data makes the browser see a reset instead of our answer.
  private func refuse(_ response: HTTPResponse, unread: Int64, on connection: NetworkConnection<TCP>) async {
    await send(response, on: connection)
    guard unread > 0, unread <= Self.drainLimit else { return }
    var left = unread
    while left > 0, case .data(let data) = await receive(from: connection) {
      left -= Int64(data.count)
    }
  }

  // MARK: - Page

  private struct PageConfig: Encodable {
    let protocolVersion = 1
    let title: String?
    let language: String?
    let accentColor: String?
    let allowedExtensions: [String]?
    let maximumFileSize: Int64
    let maximumConcurrentUploads: Int
    let strings: [String: String]
  }

  private func configResponse() -> HTTPResponse {
    let settings = configuration.pageSettings
    // Only `#RRGGBB` reaches the page, so the value can't smuggle anything into its CSS.
    let accent = settings.accentColor.flatMap { color in
      color.count == 7 && color.first == "#" && color.dropFirst().allSatisfy { $0.isASCII && $0.isHexDigit } ? color : nil
    }
    return .json(
      200,
      PageConfig(
        title: settings.title,
        language: settings.language,
        accentColor: accent,
        allowedExtensions: configuration.allowedExtensions?.sorted(),
        maximumFileSize: configuration.maximumFileSize,
        maximumConcurrentUploads: max(1, configuration.maximumConcurrentUploads),
        strings: settings.strings
      )
    )
  }

  private static let bundledPolicy = [
    "default-src 'none'", "script-src 'self'", "style-src 'self'", "img-src 'self' data:",
    "connect-src 'self'", "base-uri 'none'", "form-action 'none'", "frame-ancestors 'none'",
  ].joined(separator: "; ")

  private func pageFileResponse(for path: String) -> HTTPResponse {
    let directory: URL
    let policy: String?
    switch configuration.page {
    case .bundled:
      guard let bundled = Bundle.module.url(forResource: "Page", withExtension: nil) else {
        return .error(500, "page_missing", "The upload page is missing from the package.")
      }
      directory = bundled
      policy = Self.bundledPolicy
    case .custom(let custom, let customPolicy):
      directory = custom
      policy = customPolicy
    }

    let notFound = HTTPResponse.error(404, "not_found", "There's nothing here.")
    let relative = path == "/" ? "index.html" : String(path.dropFirst())
    guard let segments = PathRules.segments(relative) else { return notFound }
    let file = segments.reduce(directory) { $0.appendingPathComponent($1) }

    // Resolve symlinks on both sides: the file has to really be inside the page folder.
    let base = directory.resolvingSymlinksInPath().standardizedFileURL.path
    let resolved = file.resolvingSymlinksInPath().standardizedFileURL
    var isDirectory: ObjCBool = false
    guard resolved.path.hasPrefix(base + "/"),
      FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory), !isDirectory.boolValue,
      let data = try? Data(contentsOf: resolved)
    else { return notFound }

    var response = HTTPResponse(
      status: 200,
      contentType: ContentType.forExtension(resolved.pathExtension),
      body: data,
      cacheControl: "no-cache"
    )
    if let policy { response.headers.append(("Content-Security-Policy", policy)) }
    return response
  }
}
