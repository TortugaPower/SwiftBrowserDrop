import Foundation

/// Rules for the relative paths a browser sends (`Book/Disc 1/01.mp3`) and for the page files it asks for.
enum PathRules {
  static let maximumPathBytes = 1024
  static let maximumSegmentBytes = 255
  static let maximumDepth = 32

  enum Rejection: Error, Equatable {
    case invalidPath
    case unsupportedType
  }

  /// A cleaned upload path, or why it was refused.
  ///
  /// `allowedExtensions` holds lowercased extensions without the dot; `nil` allows any file type.
  static func uploadPath(_ raw: String, allowedExtensions: Set<String>?) -> Result<String, Rejection> {
    guard let segments = segments(raw) else { return .failure(.invalidPath) }
    if let allowedExtensions {
      let fileExtension = (segments[segments.count - 1] as NSString).pathExtension.lowercased()
      guard !fileExtension.isEmpty, allowedExtensions.contains(fileExtension) else {
        return .failure(.unsupportedType)
      }
    }
    return .success(segments.joined(separator: "/"))
  }

  /// The segments of a relative path, or `nil` if any of them could step outside the folder it's resolved in.
  ///
  /// Backslashes count as separators (Windows), names are precomposed (NFC) so the same name always maps to
  /// the same key, and hidden segments (`.git`, `.DS_Store`, `..`) are refused.
  static func segments(_ raw: String) -> [String]? {
    let path = raw.precomposedStringWithCanonicalMapping.replacingOccurrences(of: "\\", with: "/")
    guard !path.isEmpty, !path.hasPrefix("/"), path.utf8.count <= maximumPathBytes else { return nil }

    let segments = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    guard segments.count <= maximumDepth else { return nil }
    for segment in segments {
      guard !segment.isEmpty,
        !segment.hasPrefix("."),
        segment.utf8.count <= maximumSegmentBytes,
        !segment.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
      else { return nil }
    }
    return segments
  }
}
