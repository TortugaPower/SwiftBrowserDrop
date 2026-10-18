import Foundation
import Network
import os

/// A small HTTP server that lets a browser on the same network upload files into your app.
///
/// One server is one session: ``start()`` it when your upload screen appears, ``suspend()`` and ``resume()``
/// it around the app going to the background, then either ``finish(movingInto:)`` to keep what arrived or
/// ``cancel()`` to throw it away. Uploads wait in a staging folder until then, and only complete files are
/// ever handed over.
///
/// The listener runs in a task, and each connection is a child of it: cancelling that task stops listening
/// and ends every connection, and the task only finishes once they all have.
public actor BrowserDropServer {
  /// The session's events, for a single consumer. The stream finishes when the session closes.
  public nonisolated let events: AsyncStream<Event>
  public nonisolated let configuration: Configuration

  public private(set) var state: State = .idle
  /// Complete uploads, in the order they finished. Uploading the same path again replaces its entry.
  public internal(set) var receivedFiles: [ReceivedFile] = []
  /// Where the page can be opened, best first. Empty unless running.
  public private(set) var addresses: [Address] = []

  let logger = Logger(subsystem: "com.tortugapower.BrowserDrop", category: "server")
  private let eventSink: AsyncStream<Event>.Continuation

  var staging: Staging?
  /// Uploads in progress, for the free-space check: what each still has to write.
  var inFlight: [Int: (size: Int64, received: Int64)] = [:]
  var nextUploadID = 0

  /// Runs `NetworkListener.run`. When it finishes, every connection has ended and the port is free.
  private var listenerTask: Task<Void, Never>?
  private var boundPort: UInt16?
  private var pathTask: Task<Void, Never>?
  private var pathKinds: [String: InterfaceAddresses.PathKind] = [:]

  public init(configuration: Configuration = Configuration()) {
    self.configuration = configuration
    (events, eventSink) = AsyncStream.makeStream(of: Event.self, bufferingPolicy: .bufferingNewest(1_000))
  }

  deinit {
    listenerTask?.cancel()
    pathTask?.cancel()
    staging?.remove()
    eventSink.finish()
  }

  // MARK: - Session

  /// Creates the staging folder and starts listening on the first port in ``Configuration/ports`` that binds.
  /// Returns the addresses to show the user.
  @discardableResult
  public func start() async throws -> [Address] {
    switch state {
    case .idle: break
    case .closed: throw BrowserDropError.sessionClosed
    default: throw BrowserDropError.alreadyStarted
    }
    state = .starting

    if staging == nil {
      do {
        staging = try Staging.create(in: configuration.stagingRoot)
      } catch {
        state = .idle
        throw BrowserDropError.stagingUnavailable
      }
    }
    if pathTask == nil { await watchPaths() }

    let port: UInt16
    do {
      port = try await listen(on: configuration.ports)
    } catch {
      if state == .starting { state = .idle }
      throw error
    }
    return becameRunning(on: port)
  }

  /// Stops listening and drops in-flight uploads, keeping the files that already arrived.
  /// Call it when the app goes to the background.
  public func suspend() {
    guard case .running = state else { return }
    listenerTask?.cancel()
    addresses = []
    state = .suspended
  }

  /// Listens again, on the same port when it's still free so open browser tabs keep working.
  @discardableResult
  public func resume() async throws -> [Address] {
    switch state {
    case .suspended: break
    case .closed: throw BrowserDropError.sessionClosed
    case .running: return addresses
    default: throw BrowserDropError.notSuspended
    }
    state = .starting

    // Once the old listener's task finishes, its connections are gone and the port is free.
    await listenerTask?.value
    listenerTask = nil
    guard state == .starting else { throw BrowserDropError.sessionClosed }

    var ports = boundPort.map { [$0] } ?? []
    ports += configuration.ports.filter { !ports.contains($0) }
    let port: UInt16
    do {
      port = try await listen(on: ports)
    } catch {
      if state == .starting { state = .suspended }
      throw error
    }
    return becameRunning(on: port)
  }

  /// Ends the session and moves every complete upload into `destination`, keeping folder structure.
  /// In-flight uploads are dropped. Names already taken in `destination` get ` (1)`, ` (2)`…
  ///
  /// Returns the moved top-level files and folders. Staging is wiped either way.
  @discardableResult
  public func finish(movingInto destination: URL) async throws -> [URL] {
    guard state != .closed else { throw BrowserDropError.sessionClosed }
    await close()
    guard let staging else { return [] }
    defer {
      staging.remove()
      self.staging = nil
      receivedFiles = []
    }

    var moved: [URL] = []
    var failed: [String] = []
    for item in staging.topLevelItems() {
      let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
      let target = Staging.uniqueDestination(for: item.lastPathComponent, isDirectory: isDirectory, in: destination)
      do {
        try FileManager.default.moveItem(at: item, to: target)
        moved.append(target)
      } catch {
        logger.error("Couldn't move \(item.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        failed.append(item.lastPathComponent)
      }
    }
    if !failed.isEmpty { throw BrowserDropError.couldNotMove(moved: moved, failed: failed) }
    return moved
  }

  /// Deletes a received file, or a folder and every file in it, so ``finish(movingInto:)`` won't hand it
  /// over. `relativePath` is a ``ReceivedFile/relativePath`` or one of its folders, for example `Book`.
  /// An upload still arriving at that path is added when it finishes.
  public func removeReceivedItem(at relativePath: String) throws {
    guard let staging, let segments = PathRules.segments(relativePath) else { return }
    let path = segments.joined(separator: "/")
    try staging.removeItem(at: path)
    receivedFiles.removeAll { $0.relativePath == path || $0.relativePath.hasPrefix(path + "/") }
  }

  /// Ends the session and deletes everything that was uploaded.
  public func cancel() async {
    guard state != .closed else { return }
    await close()
    staging?.remove()
    staging = nil
    receivedFiles = []
  }

  /// Stops listening and waits for every connection to end, so nothing writes to staging afterwards.
  private func close() async {
    state = .closed
    addresses = []
    listenerTask?.cancel()
    pathTask?.cancel()
    pathTask = nil
    await listenerTask?.value
    listenerTask = nil
    eventSink.finish()
  }

  private func becameRunning(on port: UInt16) -> [Address] {
    boundPort = port
    state = .running(port: port)
    addresses = InterfaceAddresses.addresses(entries: InterfaceAddresses.current(), pathKinds: pathKinds, port: port)
    logger.info("Listening on port \(port, privacy: .public)")
    return addresses
  }

  func emit(_ event: Event) {
    eventSink.yield(event)
  }

  // MARK: - Listener

  /// Binds the first port that's free. The first one gets up to a second: a listener that was just stopped
  /// (this session's, or the previous session's) still holds its port for a few milliseconds after its task
  /// returns, and binding it then fails with "address in use".
  private func listen(on ports: [UInt16]) async throws -> UInt16 {
    for (index, port) in ports.enumerated() {
      let deadline = ContinuousClock.now + (index == 0 ? .seconds(1) : .zero)
      while true {
        do {
          return try await bind(port)
        } catch BrowserDropError.sessionClosed {
          throw BrowserDropError.sessionClosed
        } catch NWError.posix(.EADDRINUSE) where port != 0 && ContinuousClock.now < deadline {
          try? await Task.sleep(for: .milliseconds(20))
          guard state == .starting else { throw BrowserDropError.sessionClosed }
        } catch {
          logger.notice("Port \(port, privacy: .public) unavailable: \(error.localizedDescription, privacy: .public)")
          break
        }
      }
    }
    throw BrowserDropError.couldNotListen(ports: ports)
  }

  /// Starts a listener on `port` (`0` for any) and returns the bound port once it's ready.
  private func bind(_ port: UInt16) async throws -> UInt16 {
    var parameters: NWParametersBuilder<TCP> = .parameters { TCP() }
    parameters = parameters.localEndpointReuseAllowed(true)
    if port != 0, let endpointPort = NWEndpoint.Port(rawValue: port) {
      parameters = parameters.localPort(endpointPort)
    }
    let listener = try NetworkListener(using: parameters)

    let (states, stateSink) = AsyncStream.makeStream(of: NetworkListener<TCP>.State.self)
    listener.onStateUpdate { _, state in stateSink.yield(state) }

    let task = Task { [weak self] in
      defer { stateSink.finish() }
      do {
        try await listener.run { [weak self] connection in
          await self?.serve(connection)
        }
      } catch {
        self?.logger.notice("Listener stopped: \(error.localizedDescription, privacy: .public)")
      }
      if !Task.isCancelled { await self?.listenerStoppedOnItsOwn() }
    }
    // A listener normally reports `.ready` or `.failed` within milliseconds; don't hang if it doesn't.
    let timeout = Task {
      try? await Task.sleep(for: .seconds(5))
      stateSink.yield(.failed(.posix(.ETIMEDOUT)))
    }
    defer { timeout.cancel() }

    for await listenerState in states {
      switch listenerState {
      case .ready:
        guard state == .starting else {
          task.cancel()
          await task.value
          throw BrowserDropError.sessionClosed
        }
        listenerTask = task
        return listener.port?.rawValue ?? port
      case .failed(let error):
        task.cancel()
        await task.value
        throw error
      default:
        continue
      }
    }
    task.cancel()
    await task.value
    throw BrowserDropError.couldNotListen(ports: [port])
  }

  /// The listener ended without being cancelled, for example after the system reclaimed its socket.
  private func listenerStoppedOnItsOwn() {
    guard case .running = state else { return }
    listenerTask = nil
    addresses = []
    state = .suspended
    emit(.interrupted)
  }

  // MARK: - Addresses

  /// Follows network changes for the session. Waits (briefly) for the first path, so the addresses
  /// ``start()`` returns are already labelled Wi‑Fi or wired.
  private func watchPaths() async {
    let (firstPath, firstPathSink) = AsyncStream.makeStream(of: Void.self)
    pathTask = Task { [weak self] in
      for await path in NWPathMonitor() {
        var kinds: [String: InterfaceAddresses.PathKind] = [:]
        for interface in path.availableInterfaces {
          kinds[interface.name] = InterfaceAddresses.PathKind(interface.type)
        }
        await self?.pathChanged(kinds)
        firstPathSink.finish()
      }
    }
    let timeout = Task {
      try? await Task.sleep(for: .milliseconds(500))
      firstPathSink.finish()
    }
    for await _ in firstPath {}
    timeout.cancel()
  }

  private func pathChanged(_ kinds: [String: InterfaceAddresses.PathKind]) {
    pathKinds = kinds
    guard case .running(let port) = state else { return }
    let current = InterfaceAddresses.addresses(entries: InterfaceAddresses.current(), pathKinds: kinds, port: port)
    if current != addresses {
      addresses = current
      emit(.addressesChanged(current))
    }
  }
}

extension Duration {
  var timeInterval: TimeInterval {
    let (seconds, attoseconds) = components
    return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
  }
}
