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
  @Test func numbersTakenNames() throws {
    let directory = makeTemporaryDirectory()
    try FileManager.default.createDirectory(at: directory.appendingPathComponent("Book"), withIntermediateDirectories: true)
    try Data().write(to: directory.appendingPathComponent("a.mp3"))
    try Data().write(to: directory.appendingPathComponent("a (1).mp3"))

    #expect(Staging.uniqueDestination(for: "Book", isDirectory: true, in: directory).lastPathComponent == "Book (1)")
    #expect(Staging.uniqueDestination(for: "a.mp3", isDirectory: false, in: directory).lastPathComponent == "a (2).mp3")
    #expect(Staging.uniqueDestination(for: "new.mp3", isDirectory: false, in: directory).lastPathComponent == "new.mp3")
  }

  @Test func commitReplacesAnEarlierUpload() throws {
    let staging = try Staging.create(in: makeTemporaryDirectory())
    defer { staging.remove() }
    for text in ["first", "second"] {
      let (url, handle) = try staging.makeIncomingFile()
      try handle.write(contentsOf: Data(text.utf8))
      try handle.close()
      try staging.commit(url, to: "Book/01.mp3")
    }
    let stored = try String(contentsOf: staging.files.appendingPathComponent("Book/01.mp3"), encoding: .utf8)
    #expect(stored == "second")
    #expect(try FileManager.default.contentsOfDirectory(atPath: staging.incoming.path).isEmpty)
  }
}
