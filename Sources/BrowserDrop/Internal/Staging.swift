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

  /// Moves a finished upload to its relative path, replacing an earlier upload of the same path.
  func commit(_ incomingFile: URL, to relativePath: String) throws {
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

    let base = isDirectory ? name : (name as NSString).deletingPathExtension
    let fileExtension = isDirectory ? "" : (name as NSString).pathExtension
    var index = 1
    while true {
      let candidateName = fileExtension.isEmpty ? "\(base) (\(index))" : "\(base) (\(index)).\(fileExtension)"
      let candidate = directory.appendingPathComponent(candidateName, isDirectory: isDirectory)
      if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
      index += 1
    }
  }
}
