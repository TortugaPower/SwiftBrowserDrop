import Foundation

/// One session's staging.
///
/// `files` (`<root>/<uuid>`) holds the complete uploads at their relative paths, and its sibling `incoming`
/// (`<root>/<uuid>.incoming`) the uploads still arriving, one file each. An upload only moves into `files`
/// once complete, so `files` never holds a partial file, whatever happened to the connection, and
/// ``BrowserDropServer/finish()`` can hand it over as it is.
struct Staging: Sendable {
  /// The session folder: every complete upload, at its relative path.
  let files: URL
  /// Uploads still arriving.
  let incoming: URL
  /// Whether the volume treats `Book` and `book` as one name (a Mac's, the Simulator's), so names that differ
  /// only in case conflict. Assumed when the volume doesn't say.
  let namesIgnoreCase: Bool

  /// Storing the path would replace something other than an earlier upload of exactly that path.
  struct PathConflict: Error {}

  static func create(in parent: URL) throws -> Staging {
    let name = UUID().uuidString
    let files = parent.appendingPathComponent(name, isDirectory: true)
    let incoming = parent.appendingPathComponent(name + ".incoming", isDirectory: true)
    try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
    let caseSensitive = (try? files.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?
      .volumeSupportsCaseSensitiveNames
    return Staging(files: files, incoming: incoming, namesIgnoreCase: caseSensitive != true)
  }

  func makeIncomingFile() throws -> (url: URL, handle: FileHandle) {
    let url = incoming.appendingPathComponent(UUID().uuidString, isDirectory: false)
    guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
      throw CocoaError(.fileWriteUnknown)
    }
    return (url, try FileHandle(forWritingTo: url))
  }

  /// Moves a finished upload to its relative path. An earlier upload of exactly that path is replaced, so a
  /// retry never makes a duplicate; anything else already there under that name throws ``PathConflict``.
  func commit(_ incomingFile: URL, to relativePath: String) throws {
    guard !conflicts(at: relativePath) else { throw PathConflict() }
    // The volume has the last word on which names are the same: some it equates (Osage capital and small
    // letters, for one) compare as different in ``conflicts(at:)``. So nothing here relies on a name being
    // free: each folder and the file must end up stored under exactly their own names, or it's refused
    // rather than land in, or replace, something else.
    let segments = relativePath.split(separator: "/").map(String.init)
    var folder = files
    for segment in segments.dropLast() {
      folder = folder.appendingPathComponent(segment, isDirectory: true)
      do {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
      } catch CocoaError.fileWriteFileExists {
        guard try storedNames(in: folder.deletingLastPathComponent()).contains(segment) else { throw PathConflict() }
      }
    }
    let name = segments[segments.count - 1]
    let destination = folder.appendingPathComponent(name, isDirectory: false)
    if try storedNames(in: folder).contains(name) {
      _ = try FileManager.default.replaceItemAt(destination, withItemAt: incomingFile)
    } else {
      do {
        try FileManager.default.moveItem(at: incomingFile, to: destination)
      } catch CocoaError.fileWriteFileExists {
        throw PathConflict()
      }
    }
  }

  /// The names in `folder` as stored. String equality ignores Unicode normalization, so a name stored
  /// decomposed still matches.
  private func storedNames(in folder: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: folder.path)
  }

  /// Whether storing `relativePath` would replace something other than an earlier upload of exactly that
  /// path. Each part of the path already on disk must have exactly that name, and be a folder for the parents
  /// and a file for the last part.
  ///
  /// The disk decides what "the same name" means. On a case-insensitive volume (a Mac, the Simulator) `Book`
  /// and `book` are one name, so a different case conflicts; on a case-sensitive one (an iPhone) they're two
  /// names and both can be stored.
  func conflicts(at relativePath: String) -> Bool {
    let segments = relativePath.split(separator: "/").map(String.init)
    var parent = files
    for (index, segment) in segments.enumerated() {
      // The names as stored, rather than a lookup by name: in the Simulator an app's lookups are
      // case-sensitive (`A.mp3` isn't found) while the Mac's volume underneath still holds `a.mp3` and `A.mp3`
      // as one name, so storing the second would fail.
      let names: [String]
      do {
        names = try storedNames(in: parent)
      } catch CocoaError.fileReadNoSuchFile {
        return false  // No folder yet, so nothing in it either.
      } catch {
        return true  // Can't tell what's there (out of descriptors, say): refuse rather than risk replacing it.
      }
      guard names.contains(segment) else {
        // Not there; or there under another name the volume treats as the same (`Book` for `book`).
        return namesIgnoreCase && names.contains { $0.caseInsensitiveCompare(segment) == .orderedSame }
      }
      let item = parent.appendingPathComponent(segment)
      var isDirectory: ObjCBool = false
      _ = FileManager.default.fileExists(atPath: item.path, isDirectory: &isDirectory)
      // A folder where the file goes, or a file where a folder goes.
      if isDirectory.boolValue == (index == segments.count - 1) { return true }
      parent = item
    }
    return false
  }

  func containsFile(at relativePath: String) -> Bool {
    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: files.appendingPathComponent(relativePath).path, isDirectory: &isDirectory)
    return exists && !isDirectory.boolValue
  }

  /// Whether `files` is known to hold nothing. A folder that can't be listed doesn't count as empty.
  var isEmpty: Bool {
    (try? FileManager.default.contentsOfDirectory(atPath: files.path))?.isEmpty == true
  }

  func remove() {
    try? FileManager.default.removeItem(at: files)
    removeIncoming()
  }

  func removeIncoming() {
    try? FileManager.default.removeItem(at: incoming)
  }

  /// Deletes a file, or a folder with everything in it, then the folders that leaves empty, so an emptied
  /// folder isn't handed over by ``BrowserDropServer/finish()`` as an item of its own.
  func removeItem(at relativePath: String) throws {
    let base = files.standardizedFileURL.path
    let item = files.appendingPathComponent(relativePath)
    if FileManager.default.fileExists(atPath: item.path) {
      try FileManager.default.removeItem(at: item)
    }
    var parent = item.deletingLastPathComponent()
    while parent.standardizedFileURL.path.hasPrefix(base + "/"),
      (try? FileManager.default.contentsOfDirectory(atPath: parent.path))?.isEmpty == true
    {
      try FileManager.default.removeItem(at: parent)
      parent = parent.deletingLastPathComponent()
    }
  }
}
