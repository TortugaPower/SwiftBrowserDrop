import Foundation
import Testing

@testable import BrowserDrop

@Suite("Path rules")
struct PathRulesTests {
  let audio: Set<String> = ["mp3", "m4b"]

  @Test func acceptsNestedPaths() {
    #expect(PathRules.uploadPath("Book/Disc 1/01.mp3", allowedExtensions: audio) == .success("Book/Disc 1/01.mp3"))
  }

  @Test func treatsBackslashesAsSeparators() {
    #expect(PathRules.uploadPath(#"Book\Disc 1\01.mp3"#, allowedExtensions: audio) == .success("Book/Disc 1/01.mp3"))
  }

  @Test func precomposesNames() {
    #expect(PathRules.uploadPath("Cafe\u{301}.mp3", allowedExtensions: audio) == .success("Caf\u{E9}.mp3"))
  }

  @Test func matchesExtensionsCaseInsensitively() {
    #expect(PathRules.uploadPath("BOOK.M4B", allowedExtensions: audio) == .success("BOOK.M4B"))
  }

  @Test(arguments: [
    "", "/a.mp3", "../a.mp3", "a/../b.mp3", "./a.mp3", "a//b.mp3", "a/", ".hidden.mp3", "Book/.git/a.mp3",
    "a\u{0}.mp3", "a\nb.mp3", "\u{7F}.mp3", String(repeating: "a", count: 252) + ".mp3",
    Array(repeating: "d", count: 32).joined(separator: "/") + "/a.mp3",
  ])
  func refusesUnsafePaths(_ path: String) {
    #expect(PathRules.uploadPath(path, allowedExtensions: audio) == .failure(.invalidPath))
  }

  @Test(arguments: ["notes.txt", "noextension", "Book/cover.jpg", "trailingdot."])
  func refusesOtherTypes(_ path: String) {
    #expect(PathRules.uploadPath(path, allowedExtensions: audio) == .failure(.unsupportedType))
  }

  @Test func acceptsAnyTypeWhenUnrestricted() {
    #expect(PathRules.uploadPath("notes.txt", allowedExtensions: nil) == .success("notes.txt"))
    #expect(PathRules.uploadPath("README", allowedExtensions: nil) == .success("README"))
  }
}

@Suite("Request heads")
struct HTTPRequestHeadTests {
  @Test func parsesRequestLineQueryAndHeaders() throws {
    let text = "POST /upload?path=Book%2F01%20One.mp3&path=ignored HTTP/1.1\r\nHost: 192.168.1.5\r\n"
      + "Content-Length: 42\r\nX-Note: a\r\nx-note: b"
    let head = try #require(HTTPRequestHead.parse(Data(text.utf8)))
    #expect(head.method == "POST")
    #expect(head.path == "/upload")
    #expect(head.query["path"] == "Book/01 One.mp3")
    #expect(head.contentLength == 42)
    #expect(head.headers["host"] == "192.168.1.5")
    #expect(head.headers["x-note"] == "a, b")
    #expect(!head.expectsContinue)
  }

  @Test func keepsPlusSigns() throws {
    let head = try #require(HTTPRequestHead.parse(Data("POST /upload?path=a+b.mp3 HTTP/1.1\r\nHost: x".utf8)))
    #expect(head.query["path"] == "a+b.mp3")
  }

  @Test func readsExpectContinue() throws {
    let head = try #require(HTTPRequestHead.parse(Data("POST /upload HTTP/1.1\r\nExpect: 100-Continue".utf8)))
    #expect(head.expectsContinue)
  }

  @Test func acceptsRepeatedEqualLengths() throws {
    let head = try #require(
      HTTPRequestHead.parse(Data("POST /upload HTTP/1.1\r\nContent-Length: 3\r\nContent-Length: 3".utf8))
    )
    #expect(head.contentLength == 3)
  }

  @Test(arguments: [
    "", "GET / HTTP/2.0", "GET  / HTTP/1.1", "get / HTTP/1.1", "GET http://x/ HTTP/1.1", "GET /",
    "POST /upload HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 2",
    "POST /upload HTTP/1.1\r\nContent-Length: -1",
    "POST /upload HTTP/1.1\r\nContent-Length: 1e3",
    "POST /upload HTTP/1.1\r\nContent-Length: ",
    "GET / HTTP/1.1\r\nHost: a\r\n folded",
    "GET / HTTP/1.1\r\nNoColon",
    "GET / HTTP/1.1\r\nBad Name: x",
  ])
  func refusesMalformedHeads(_ text: String) {
    #expect(HTTPRequestHead.parse(Data(text.utf8)) == nil)
  }
}

@Suite("Request rules")
struct RequestRulesTests {
  @Test(arguments: [
    "192.168.1.5", "192.168.1.5:8080", "[fe80::1]:80", "localhost:80", "iphone", "Giannis-iPhone.local",
    "phone.lan", "phone.home.arpa",
  ])
  func acceptsLocalHosts(_ host: String) {
    #expect(RequestRules.isLocalHost(host))
  }

  @Test(arguments: [nil, "", ":80", "evil.example", "evil.example:80", "phone.local.evil.com"] as [String?])
  func refusesPublicHosts(_ host: String?) {
    #expect(!RequestRules.isLocalHost(host))
  }

  @Test func matchesOrigins() {
    #expect(RequestRules.isSameOrigin(origin: nil, host: "192.168.1.5"))
    #expect(RequestRules.isSameOrigin(origin: "http://192.168.1.5", host: "192.168.1.5"))
    #expect(RequestRules.isSameOrigin(origin: "HTTP://192.168.1.5:8080", host: "192.168.1.5:8080"))
    #expect(!RequestRules.isSameOrigin(origin: "http://evil.example", host: "192.168.1.5"))
    #expect(!RequestRules.isSameOrigin(origin: "null", host: "192.168.1.5"))
    #expect(!RequestRules.isSameOrigin(origin: "http://192.168.1.5", host: nil))
  }
}

@Suite("Addresses")
struct InterfaceAddressesTests {
  typealias Entry = InterfaceAddresses.Entry

  /// What an iPhone sharing its hotspot reported in a real test: no `en0`, and cellular first.
  @Test func keepsOnlyTheHotspotOnAPhoneSharingItsConnection() {
    let entries = [
      Entry(name: "pdp_ip0", ipv4: "100.96.154.46"),
      Entry(name: "en2", ipv4: "169.254.183.37"),
      Entry(name: "bridge100", ipv4: "172.20.10.1"),
      Entry(name: "utun3", ipv4: "100.101.1.2"),
    ]
    let addresses = InterfaceAddresses.addresses(entries: entries, pathKinds: [:], port: 80)
    #expect(addresses.map(\.host) == ["172.20.10.1"])
    #expect(addresses.first?.kind == .hotspot)
  }

  @Test func letsThePathMonitorNameInterfaces() {
    let entries = [
      Entry(name: "en9", ipv4: "10.0.0.9"),
      Entry(name: "bridge100", ipv4: "172.20.10.1"),
      Entry(name: "en5", ipv4: "10.0.0.5"),
      Entry(name: "en0", ipv4: "192.168.1.5"),
      Entry(name: "en7", ipv4: "10.0.0.7"),
    ]
    let kinds: [String: InterfaceAddresses.PathKind] = ["en0": .wifi, "en5": .wired, "en7": .cellular]
    let addresses = InterfaceAddresses.addresses(entries: entries, pathKinds: kinds, port: 8080)
    #expect(addresses.map(\.host) == ["192.168.1.5", "10.0.0.5", "172.20.10.1", "10.0.0.9"])
    #expect(addresses.map(\.kind) == [.wifi, .wired, .hotspot, .other])
  }

  @Test func leavesPort80OutOfTheURL() {
    let address = BrowserDropServer.Address(kind: .wifi, interfaceName: "en0", host: "192.168.1.5", port: 80)
    #expect(address.url.absoluteString == "http://192.168.1.5/")
    let other = BrowserDropServer.Address(kind: .wifi, interfaceName: "en0", host: "192.168.1.5", port: 8080)
    #expect(other.url.absoluteString == "http://192.168.1.5:8080/")
  }
}

@Suite("Staging")
struct StagingTests {
  /// Stores `text` at `path` the way a finished upload is.
  private func store(_ text: String, at path: String, in staging: Staging) throws {
    let (url, handle) = try staging.makeIncomingFile()
    try handle.write(contentsOf: Data(text.utf8))
    try handle.close()
    do {
      try staging.commit(url, to: path)
    } catch {
      try? FileManager.default.removeItem(at: url)
      throw error
    }
  }

  @Test func readsFreeSpaceAfreshEachTime() throws {
    // The server checks free space with the same URL all session, and URLs cache resource values: every
    // check after the first must still see what's free now.
    let folder = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let before = try #require(BrowserDropServer.volumeAvailableCapacity(folder))
    try Data(count: 128 << 20).write(to: folder.appendingPathComponent("filler"))
    let after = try #require(BrowserDropServer.volumeAvailableCapacity(folder))
    #expect(before - after >= 64 << 20, "read \(before) bytes free, then \(after) after writing 128 MB")
  }

  @Test func keepsIncomingUploadsBesideTheSessionFolder() throws {
    let root = makeTemporaryDirectory()
    let staging = try Staging.create(in: root)
    #expect(staging.files.deletingLastPathComponent() == staging.incoming.deletingLastPathComponent())
    #expect(staging.incoming.lastPathComponent == staging.files.lastPathComponent + ".incoming")
    staging.remove()
    #expect(try names(in: root).isEmpty)
  }

  @Test func commitReplacesAnEarlierUpload() throws {
    let staging = try Staging.create(in: makeTemporaryDirectory())
    defer { staging.remove() }
    try store("first", at: "Book/01.mp3", in: staging)
    try store("second", at: "Book/01.mp3", in: staging)
    let stored = try String(contentsOf: staging.files.appendingPathComponent("Book/01.mp3"), encoding: .utf8)
    #expect(stored == "second")
    #expect(try FileManager.default.contentsOfDirectory(atPath: staging.incoming.path).isEmpty)
  }

  @Test func refusesAFileWhereAFolderIs() throws {
    let staging = try Staging.create(in: makeTemporaryDirectory())
    defer { staging.remove() }
    try store("chapter", at: "Book.mp3/01.mp3", in: staging)

    #expect(staging.conflicts(at: "Book.mp3"))
    #expect(throws: Staging.PathConflict.self) { try store("x", at: "Book.mp3", in: staging) }
    #expect(staging.containsFile(at: "Book.mp3/01.mp3"))
  }

  @Test func refusesAFolderWhereAFileIs() throws {
    let staging = try Staging.create(in: makeTemporaryDirectory())
    defer { staging.remove() }
    try store("x", at: "Book.mp3", in: staging)

    #expect(staging.conflicts(at: "Book.mp3/01.mp3"))
    #expect(staging.conflicts(at: "Book.mp3/Disc 1/01.mp3"))
    #expect(throws: Staging.PathConflict.self) { try store("chapter", at: "Book.mp3/01.mp3", in: staging) }
    #expect(staging.containsFile(at: "Book.mp3"))
  }

  @Test func acceptsSiblingsDeeperFoldersAndTheSamePathAgain() throws {
    let staging = try Staging.create(in: makeTemporaryDirectory())
    defer { staging.remove() }
    try store("a", at: "Book/01.mp3", in: staging)
    try store("b", at: "Café/01.mp3", in: staging)

    #expect(!staging.conflicts(at: "Book/01.mp3"))
    #expect(!staging.conflicts(at: "Book/02.mp3"))
    #expect(!staging.conflicts(at: "Book/Disc 2/01.mp3"))
    #expect(!staging.conflicts(at: "Café/02.mp3"))
    #expect(!staging.conflicts(at: "Other.mp3"))
  }

  @Test func refusesWhenAFolderCantBeListed() throws {
    let staging = try Staging.create(in: makeTemporaryDirectory())
    defer { staging.remove() }
    try store("a", at: "Book/01.mp3", in: staging)
    let book = staging.files.appendingPathComponent("Book")
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: book.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: book.path) }

    // Out of descriptors would look the same: what's there can't be known, so nothing is let through.
    #expect(staging.conflicts(at: "Book/02.mp3"))
  }

  @Test func aMissingSessionFolderHidesNothing() throws {
    let staging = try Staging.create(in: makeTemporaryDirectory())
    defer { staging.remove() }
    try FileManager.default.removeItem(at: staging.files)
    #expect(!staging.conflicts(at: "a.mp3"))
  }

  /// Osage capital and small letters are one name to APFS, but Foundation compares them as different: the
  /// check misses them, and storing refuses them instead of replacing or merging.
  @Test(.enabled(if: temporaryVolumeIsCaseInsensitive))
  func refusesNamesTheVolumeEquatesThatCompareAsDifferent() throws {
    let staging = try Staging.create(in: makeTemporaryDirectory())
    defer { staging.remove() }
    let capital = "\u{104B0}"
    let small = "\u{104D8}"
    try store("file", at: "\(capital).mp3", in: staging)
    try store("chapter", at: "\(capital)/01.mp3", in: staging)

    #expect(throws: Staging.PathConflict.self) { try store("x", at: "\(small).mp3", in: staging) }
    #expect(throws: Staging.PathConflict.self) { try store("x", at: "\(small)/01.mp3", in: staging) }
    #expect(throws: Staging.PathConflict.self) { try store("x", at: "\(small)/02.mp3", in: staging) }
    #expect(try String(contentsOf: staging.files.appendingPathComponent("\(capital).mp3"), encoding: .utf8) == "file")
    #expect(try String(contentsOf: staging.files.appendingPathComponent("\(capital)/01.mp3"), encoding: .utf8) == "chapter")
    #expect(try names(in: staging.files.appendingPathComponent(capital)) == ["01.mp3"])
    #expect(try FileManager.default.contentsOfDirectory(atPath: staging.incoming.path).isEmpty)
  }

  @Test(.enabled(if: temporaryVolumeIsCaseInsensitive))
  func refusesANameInAnotherCaseOnACaseInsensitiveVolume() throws {
    let staging = try Staging.create(in: makeTemporaryDirectory())
    defer { staging.remove() }
    try store("one", at: "Book/a.mp3", in: staging)

    #expect(staging.conflicts(at: "Book/A.mp3"))
    #expect(staging.conflicts(at: "book/b.mp3"))
    #expect(throws: Staging.PathConflict.self) { try store("two", at: "Book/A.mp3", in: staging) }
    #expect(try String(contentsOf: staging.files.appendingPathComponent("Book/a.mp3"), encoding: .utf8) == "one")
  }
}
