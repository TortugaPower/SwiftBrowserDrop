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

  /// Storing the path would replace something other than an earlier upload of exactly that path.
  struct PathConflict: Error {}

  static func create(in parent: URL) throws -> Staging {
    let name = UUID().uuidString
    let staging = Staging(
      files: parent.appendingPathComponent(name, isDirectory: true),
      incoming: parent.appendingPathComponent(name + ".incoming", isDirectory: true)
    )
    try FileManager.default.createDirectory(at: staging.incoming, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: staging.files, withIntermediateDirectories: true)
    return staging
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
    let destination = files.appendingPathComponent(relativePath, isDirectory: false)
    try FileManager.default.createDirectory(
      at: destination.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    if FileManager.default.fileExists(atPath: destination.path) {
      _ = try FileManager.default.replaceItemAt(destination, withItemAt: incomingFile)
    } else {
      try FileManager.default.moveItem(at: incomingFile, to: destination)
    }
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
    var item = files
    for (index, segment) in segments.enumerated() {
      item = item.appendingPathComponent(segment)
      // Fails when nothing is there. The name is the one on disk, whatever the spelling asked for.
      guard let values = try? item.resourceValues(forKeys: [.nameKey, .isDirectoryKey]) else { return false }
      // A folder where the file goes, or a file where a folder goes.
      if (values.isDirectory ?? false) == (index == segments.count - 1) { return true }
      // There, but under another name the volume treats as the same (`Book` for `book`). String equality
      // ignores Unicode normalization, so a name stored decomposed still matches.
      if values.name != segment { return true }
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
