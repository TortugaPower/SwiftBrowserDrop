import Foundation
import Network

/// Checks that an upload comes from the server's own page.
enum RequestRules {
  /// Private-use names a phone can be reached at on a home network.
  private static let localSuffixes = [".local", ".lan", ".home", ".home.arpa", ".internal", ".localdomain"]

  /// Whether the `Host` header names this device the way a local client would: an IP literal,
  /// `localhost`, a single-label name or a private-use suffix such as `.local`.
  ///
  /// A public name means DNS rebinding: a website resolved its own domain to the phone's address so its
  /// script can talk to the server as if it were same-origin. The browser still sends the website's name.
  static func isLocalHost(_ host: String?) -> Bool {
    guard let host, let name = hostName(host), !name.isEmpty else { return false }
    if IPv4Address(name) != nil || IPv6Address(name) != nil { return true }
    let lowercased = name.lowercased()
    if lowercased == "localhost" || !lowercased.contains(".") { return true }
    return localSuffixes.contains { lowercased.hasSuffix($0) }
  }

  /// Whether a browser's `Origin` matches the `Host` it sent. No `Origin` means a non-browser client.
  static func isSameOrigin(origin: String?, host: String?) -> Bool {
    guard let origin else { return true }
    guard let host else { return false }
    return origin.lowercased() == "http://\(host.lowercased())"
  }

  /// The `Host` header without its port; IPv6 literals lose their brackets.
  static func hostName(_ host: String) -> String? {
    if host.hasPrefix("[") {
      guard let close = host.firstIndex(of: "]") else { return nil }
      return String(host[host.index(after: host.startIndex)..<close])
    }
    return host.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)
  }
}
