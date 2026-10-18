import Foundation

/// A complete response. Every connection serves one request, so responses always close it.
struct HTTPResponse {
  var status: Int
  var headers: [(name: String, value: String)]
  var body: Data

  init(status: Int, contentType: String, body: Data, cacheControl: String = "no-store") {
    self.status = status
    self.body = body
    self.headers = [
      ("Content-Type", contentType),
      ("Cache-Control", cacheControl),
      ("X-Content-Type-Options", "nosniff"),
      ("Referrer-Policy", "no-referrer"),
      ("X-Frame-Options", "DENY"),
    ]
  }

  static func json(_ status: Int, _ value: some Encodable) -> HTTPResponse {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let body = (try? encoder.encode(value)) ?? Data("{}".utf8)
    return HTTPResponse(status: status, contentType: "application/json; charset=utf-8", body: body)
  }

  /// The error body the protocol documents: `{"error": "<code>", "message": "<text>"}`.
  static func error(_ status: Int, _ code: String, _ message: String) -> HTTPResponse {
    json(status, ["error": code, "message": message])
  }

  static let continueInterim = Data("HTTP/1.1 100 Continue\r\n\r\n".utf8)

  func serialized() -> Data {
    var head = "HTTP/1.1 \(status) \(Self.reasonPhrase(status))\r\n"
    for header in headers {
      head += "\(header.name): \(header.value)\r\n"
    }
    head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
    var data = Data(head.utf8)
    data.append(body)
    return data
  }

  static func reasonPhrase(_ status: Int) -> String {
    switch status {
    case 200: "OK"
    case 201: "Created"
    case 400: "Bad Request"
    case 403: "Forbidden"
    case 404: "Not Found"
    case 405: "Method Not Allowed"
    case 408: "Request Timeout"
    case 411: "Length Required"
    case 413: "Content Too Large"
    case 431: "Request Header Fields Too Large"
    case 500: "Internal Server Error"
    case 507: "Insufficient Storage"
    default: "Unknown"
    }
  }
}

enum ContentType {
  static func forExtension(_ fileExtension: String) -> String {
    switch fileExtension.lowercased() {
    case "html", "htm": "text/html; charset=utf-8"
    case "js", "mjs": "text/javascript; charset=utf-8"
    case "css": "text/css; charset=utf-8"
    case "json": "application/json; charset=utf-8"
    case "svg": "image/svg+xml"
    case "png": "image/png"
    case "jpg", "jpeg": "image/jpeg"
    case "ico": "image/x-icon"
    case "webp": "image/webp"
    case "woff2": "font/woff2"
    case "txt": "text/plain; charset=utf-8"
    case "webmanifest": "application/manifest+json"
    default: "application/octet-stream"
    }
  }
}
