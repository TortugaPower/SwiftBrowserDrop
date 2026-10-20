import Foundation

/// One session's staging folder.
///
/// Uploads are written to `incoming/<uuid>` and only moved into `files/<relative path>` once complete,
/// so `files` never holds a partial file, whatever happened to the connection.
struct Staging: Sendable {
  let root: URL
  var incoming: URL { root.appendingPathComponent("incoming", isDirectory: true) }
  var files: URL { root.appendingPathComponent("files", isDirectory: true) }

  static func create(in parent: URL) throws -> Staging {
    let staging = Staging(root: parent.appendingPathComponent(UUID().uuidString, isDirectory: true))
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

  /// Moves a finished upload to its relative path, replacing whatever is in the way, so the last upload
  /// wins: an earlier upload of the same path, a folder of earlier uploads at that path, or an earlier file
  /// where one of its folders goes (`x` for `x/y.mp3`). Returns whether it replaced anything but a file
  /// at the same path.
  @discardableResult
  func commit(_ incomingFile: URL, to relativePath: String) throws -> Bool {
    let destination = files.appendingPathComponent(relativePath, isDirectory: false)

    // A file where a folder of this path goes: set it aside, and put it back if the commit fails.
    var blocking: (file: URL, backup: URL)?
    var ancestor = files
    for segment in relativePath.split(separator: "/").dropLast() {
      ancestor = ancestor.appendingPathComponent(String(segment), isDirectory: true)
      var isDirectory: ObjCBool = false
      if FileManager.default.fileExists(atPath: ancestor.path, isDirectory: &isDirectory), !isDirectory.boolValue {
        let backup = incoming.appendingPathComponent(UUID().uuidString, isDirectory: false)
        try FileManager.default.moveItem(at: ancestor, to: backup)
        blocking = (ancestor, backup)
        break
      }
    }

    do {
      try FileManager.default.createDirectory(
        at: destination.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      var replacedFolder = false
      var isDirectory: ObjCBool = false
      if FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory) {
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: incomingFile)
        replacedFolder = isDirectory.boolValue
      } else {
        try FileManager.default.moveItem(at: incomingFile, to: destination)
      }
      if let blocking { try? FileManager.default.removeItem(at: blocking.backup) }
      return replacedFolder || blocking != nil
    } catch {
      if let blocking {
        try? FileManager.default.removeItem(at: blocking.file)  // the folder this commit may have created
        try? FileManager.default.moveItem(at: blocking.backup, to: blocking.file)
      }
      throw error
    }
  }

  func containsFile(at relativePath: String) -> Bool {
    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: files.appendingPathComponent(relativePath).path, isDirectory: &isDirectory)
    return exists && !isDirectory.boolValue
  }

  /// Whether two relative paths name the same file. On a case-insensitive volume `a.mp3` and `A.mp3` do.
  func isSameFile(_ lhs: String, _ rhs: String) -> Bool {
    if lhs == rhs { return true }
    guard lhs.caseInsensitiveCompare(rhs) == .orderedSame else { return false }
    func identifier(_ path: String) -> (any NSCopying & NSSecureCoding & NSObjectProtocol)? {
      try? files.appendingPathComponent(path).resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
    }
    guard let left = identifier(lhs), let right = identifier(rhs) else { return false }
    return left.isEqual(right)
  }

  /// The top-level files and folders under `files`, in Finder order.
  func topLevelItems() -> [URL] {
    let items = (try? FileManager.default.contentsOfDirectory(at: files, includingPropertiesForKeys: nil)) ?? []
    return items.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }

  /// Deletes a file, or a folder with everything in it, then the folders that leaves empty, so an emptied
  /// folder doesn't reach ``BrowserDropServer/finish(movingInto:)`` as an item of its own.
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

  /// `name` in `directory`, or `name (1)`, `name (2)`… when it's taken. Extensions stay at the end.
  static func uniqueDestination(for name: String, isDirectory: Bool, in directory: URL) -> URL {
    let first = directory.appendingPathComponent(name, isDirectory: isDirectory)
    guard FileManager.default.fileExists(atPath: first.path) else { return first }

    var base = isDirectory ? name : (name as NSString).deletingPathExtension
    let fileExtension = isDirectory ? "" : (name as NSString).pathExtension
    var index = 1
    while true {
      let suffix = fileExtension.isEmpty ? " (\(index))" : " (\(index)).\(fileExtension)"
      // Names are limited to 255 bytes: shorten the base so the suffix still fits.
      while !base.isEmpty, base.utf8.count + suffix.utf8.count > PathRules.maximumSegmentBytes { base.removeLast() }
      let candidateName = base + suffix
      let candidate = directory.appendingPathComponent(candidateName, isDirectory: isDirectory)
      if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
      index += 1
    }
  }
}
