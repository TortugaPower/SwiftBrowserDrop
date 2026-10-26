import Foundation

extension BrowserDropServer {
  public struct Configuration: Sendable {
    /// Ports tried in order until one binds. `0` means any free port, which is handy in tests.
    public var ports: [UInt16]
    /// Accepted file extensions, lowercased and without the dot. `nil` accepts any type.
    public var allowedExtensions: Set<String>?
    public var maximumFileSize: Int64
    /// Free space that must remain on the device after an upload is accepted.
    public var reservedFreeSpace: Int64
    /// How many uploads the bundled page runs at once. Sent to the page in `config.json`.
    public var maximumConcurrentUploads: Int
    /// A connection that sends nothing for this long is closed, and so is one that takes this long to send
    /// its request head. A stalled upload fails as ``FailureReason/timedOut``.
    public var idleTimeout: Duration
    /// Connections served at once; more are closed right away. Each holds a file descriptor, and an iOS app
    /// has only 256 by default, so this keeps other devices on the network from exhausting the app's.
    public var maximumConnections: Int
    public var page: Page
    public var pageSettings: PageSettings
    /// The folder that holds each session's staging, and what ``BrowserDropServer/finish()`` handed over
    /// until the app moves or deletes it. ``BrowserDropServer/removeLeftovers(in:)`` empties it.
    public var stagingRoot: URL
    /// Free bytes on the volume of a URL. Replace it in tests.
    public var availableCapacity: @Sendable (URL) -> Int64?

    public init(
      ports: [UInt16] = [80, 8080],
      allowedExtensions: Set<String>? = nil,
      maximumFileSize: Int64 = 8 << 30,
      reservedFreeSpace: Int64 = 256 << 20,
      maximumConcurrentUploads: Int = 3,
      idleTimeout: Duration = .seconds(60),
      maximumConnections: Int = 64,
      page: Page = .bundled,
      pageSettings: PageSettings = PageSettings(),
      stagingRoot: URL = BrowserDropServer.defaultStagingRoot,
      availableCapacity: @escaping @Sendable (URL) -> Int64? = BrowserDropServer.volumeAvailableCapacity
    ) {
      self.ports = ports
      self.allowedExtensions = allowedExtensions.map { Set($0.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) }) }
      self.maximumFileSize = maximumFileSize
      self.reservedFreeSpace = reservedFreeSpace
      self.maximumConcurrentUploads = maximumConcurrentUploads
      self.idleTimeout = idleTimeout
      self.maximumConnections = maximumConnections
      self.page = page
      self.pageSettings = pageSettings
      self.stagingRoot = stagingRoot
      self.availableCapacity = availableCapacity
    }
  }

  /// The page served at `/`.
  public enum Page: Sendable, Equatable {
    /// The page that ships with the package. Customize its text and color with ``PageSettings``.
    case bundled
    /// Your own `index.html` and assets, served as static files from `directory`. The page must speak
    /// the protocol in the README. `contentSecurityPolicy`, when set, is sent with every page file.
    case custom(directory: URL, contentSecurityPolicy: String? = nil)
  }

  /// What `config.json` tells the page. Custom pages get the same values.
  public struct PageSettings: Sendable, Equatable {
    /// Page and window title, for example your app's name.
    public var title: String?
    /// BCP 47 language of `strings`, for example `es`. Sets the page's `lang`.
    public var language: String?
    /// `#RRGGBB`. Anything else is ignored.
    public var accentColor: String?
    /// Replacements for the bundled page's English text, keyed as in the README.
    public var strings: [String: String]

    public init(
      title: String? = nil,
      language: String? = nil,
      accentColor: String? = nil,
      strings: [String: String] = [:]
    ) {
      self.title = title
      self.language = language
      self.accentColor = accentColor
      self.strings = strings
    }
  }

  /// `tmp/BrowserDrop`.
  public static let defaultStagingRoot = FileManager.default.temporaryDirectory
    .appendingPathComponent("BrowserDrop", isDirectory: true)

  @Sendable
  public static func volumeAvailableCapacity(_ url: URL) -> Int64? {
    // A URL caches resource values, and the server passes the same one for the whole session: without
    // this, every check would see the free space measured by the first.
    var url = url
    url.removeAllCachedResourceValues()
    let values = try? url.resourceValues(forKeys: [
      .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
    ])
    if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
    return values?.volumeAvailableCapacity.map(Int64.init)
  }

  /// Removes staging left by a session the app never finished or cancelled (after a crash, for example),
  /// and any handed-over folder the app didn't move or delete. Call it at launch, before creating any server.
  public static func removeLeftovers(in stagingRoot: URL = defaultStagingRoot) {
    try? FileManager.default.removeItem(at: stagingRoot)
  }
}
