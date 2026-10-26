import Foundation

extension BrowserDropServer {
  /// Where the session is in its life. A server is one session: once ``closed``, make a new one.
  public enum State: Sendable, Equatable {
    /// Created, ``BrowserDropServer/start()`` not called yet.
    case idle
    /// Binding a port.
    case starting
    /// Accepting uploads on `port`.
    case running(port: UInt16)
    /// Not listening, session kept. ``BrowserDropServer/resume()`` listens again on the same port.
    case suspended
    /// Finished or cancelled. The server holds nothing any more.
    case closed
  }

  /// A file being uploaded. `id` tells two uploads of the same path apart.
  public struct Upload: Sendable, Hashable, Identifiable {
    public let id: Int
    /// The cleaned relative path, for example `Book/Disc 1/01.mp3`.
    public let relativePath: String
    /// The size the browser announced.
    public let size: Int64
  }

  /// A finished upload waiting in staging until ``BrowserDropServer/finish()``.
  public struct ReceivedFile: Sendable, Hashable, Identifiable {
    public let relativePath: String
    public let size: Int64

    public var id: String { relativePath }

    /// The last path component, for example `01.mp3`.
    public var name: String {
      relativePath.split(separator: "/").last.map(String.init) ?? relativePath
    }
  }

  /// How much of an upload has arrived. ``BrowserDropServer/progress`` lists one per upload in flight, sent
  /// whenever one of them starts, ends or advances about 1% of its size (at least 512 KiB); each shows what
  /// had arrived by then.
  public struct UploadProgress: Sendable, Hashable {
    public let upload: Upload
    public let receivedBytes: Int64
  }

  public enum Event: Sendable, Equatable {
    /// The request was accepted and the body is arriving. ``BrowserDropServer/progress`` follows it.
    case uploadStarted(Upload)
    /// The file is complete and in ``BrowserDropServer/receivedFiles``. An earlier upload of exactly the
    /// same path was replaced.
    case uploadFinished(ReceivedFile)
    /// The upload ended without a file. It can come without `uploadStarted` when the file was refused
    /// up front: for a name that's taken, its size, or lack of space.
    case uploadFailed(relativePath: String, reason: FailureReason)
    /// The device's addresses changed while running, for example after joining another Wi‑Fi network.
    case addressesChanged([Address])
    /// The listener stopped on its own. The session is kept and the state is ``State/suspended``:
    /// call ``BrowserDropServer/resume()`` to listen again on the same port.
    case interrupted
  }

  public enum FailureReason: Sendable, Equatable {
    /// The browser went away before sending the whole file.
    case disconnected
    /// The server stopped it: ``BrowserDropServer/suspend()``, ``BrowserDropServer/finish()`` or
    /// ``BrowserDropServer/cancel()``.
    case cancelled
    /// Nothing arrived for ``Configuration/idleTimeout``.
    case timedOut
    /// Larger than ``Configuration/maximumFileSize``.
    case tooLarge
    /// Accepting it would leave less than ``Configuration/reservedFreeSpace`` on the device.
    case insufficientStorage
    /// The file couldn't be written to staging.
    case writeFailed
    /// Something else this session received already has that name: a folder where the file goes, a file
    /// where one of its folders goes, or the same name in another case on a case-insensitive volume. Only
    /// an earlier upload of exactly the same path is replaced.
    case pathConflict
  }

  /// An address the page can be opened at from a computer on the same network.
  public struct Address: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
      case wifi
      case wired
      /// Personal Hotspot. Computers joined to the device's hotspot use this address.
      case hotspot
      case other
    }

    public let kind: Kind
    /// The BSD interface name, for example `en0` or `bridge100`. Shown for diagnostics only.
    public let interfaceName: String
    /// IPv4 address, for example `192.168.1.20`.
    public let host: String
    public let port: UInt16

    /// `http://192.168.1.20/`, with the port only when it isn't 80.
    public var url: URL {
      URL(string: port == 80 ? "http://\(host)/" : "http://\(host):\(port)/")!
    }
  }
}

public enum BrowserDropError: Error, Sendable, Equatable {
  /// The session was finished or cancelled. Create a new server.
  case sessionClosed
  /// ``BrowserDropServer/start()`` was already called.
  case alreadyStarted
  /// ``BrowserDropServer/resume()`` needs a suspended session.
  case notSuspended
  /// None of the ports could be bound.
  case couldNotListen(ports: [UInt16])
  /// The staging folder couldn't be created.
  case stagingUnavailable
}
