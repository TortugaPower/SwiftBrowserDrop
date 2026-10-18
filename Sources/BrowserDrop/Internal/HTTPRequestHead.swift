import Foundation

/// The request line and headers of one HTTP/1.x request.
///
/// Only what the server needs is supported: origin-form targets, `Content-Length` bodies and
/// `Expect: 100-continue`. Anything ambiguous (folded headers, conflicting lengths) is refused.
struct HTTPRequestHead: Equatable {
  /// Requests whose head is larger than this are refused with 431.
  static let maximumSize = 16 * 1024

  var method: String
  /// Percent-decoded path, for example `/upload`.
  var path: String
  /// Percent-decoded query items; the first value wins.
  var query: [String: String]
  /// Header values keyed by lowercased name. Repeated headers are joined with ", ".
  var headers: [String: String]
  var contentLength: Int64?

  var expectsContinue: Bool {
    headers["expect"]?.lowercased() == "100-continue"
  }

  /// Parses the bytes before the blank line that ends the head.
  static func parse(_ data: Data) -> HTTPRequestHead? {
    guard let text = String(data: data, encoding: .utf8) else { return nil }
    let lines = text.components(separatedBy: "\r\n")

    let requestLine = lines[0].split(separator: " ", omittingEmptySubsequences: false)
    guard requestLine.count == 3 else { return nil }
    let method = String(requestLine[0])
    let target = String(requestLine[1])
    guard !method.isEmpty, method.allSatisfy({ $0.isASCII && $0.isUppercase }),
      requestLine[2] == "HTTP/1.1" || requestLine[2] == "HTTP/1.0",
      target.hasPrefix("/"),
      let components = URLComponents(string: target)
    else { return nil }

    var query: [String: String] = [:]
    for item in components.queryItems ?? [] where query[item.name] == nil {
      query[item.name] = item.value ?? ""
    }

    var headers: [String: String] = [:]
    var contentLength: Int64?
    for line in lines.dropFirst() {
      // Obsolete line folding is a classic smuggling vector; nothing legitimate sends it.
      guard let colon = line.firstIndex(of: ":"), line.first != " ", line.first != "\t" else { return nil }
      let name = line[..<colon].lowercased()
      let value = line[line.index(after: colon)...].trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
      guard !name.isEmpty, !name.contains(" "), !name.contains("\t") else { return nil }

      if name == "content-length" {
        guard !value.isEmpty, value.allSatisfy(\.isASCIIDigit), let length = Int64(value) else { return nil }
        guard contentLength == nil || contentLength == length else { return nil }
        contentLength = length
      }
      headers[name] = headers[name].map { "\($0), \(value)" } ?? value
    }

    return HTTPRequestHead(
      method: method,
      path: components.path,
      query: query,
      headers: headers,
      contentLength: contentLength
    )
  }
}

extension Character {
  fileprivate var isASCIIDigit: Bool { isASCII && isNumber }
}
