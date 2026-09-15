import Darwin
import Foundation

struct LeaseMarker: Codable {
  let sessionIdentifier: String
  let createdAt: Date
}

enum LeaseStoreError: LocalizedError {
  case invalidDirectory
  case posix(operation: String, code: Int32)

  var errorDescription: String? {
    switch self {
    case .invalidDirectory:
      "The recovery-marker directory is not owned by root or has unsafe permissions."
    case .posix(let operation, let code):
      "\(operation) failed: \(String(cString: strerror(code)))"
    }
  }
}

final class LeaseStore {
  private let directoryURL = URL(fileURLWithPath: "/var/db/com.example.Awake", isDirectory: true)
  private var markerURL: URL { directoryURL.appendingPathComponent("active-lease.json") }

  var markerExists: Bool {
    FileManager.default.fileExists(atPath: markerURL.path)
  }

  func load() -> LeaseMarker? {
    guard let data = try? Data(contentsOf: markerURL) else { return nil }
    return try? JSONDecoder().decode(LeaseMarker.self, from: data)
  }

  func save(_ marker: LeaseMarker) throws {
    try ensureSafeDirectory()
    let data = try JSONEncoder().encode(marker)
    let temporaryURL = directoryURL.appendingPathComponent(".active-lease.\(getpid()).tmp")

    let descriptor = open(
      temporaryURL.path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else {
      throw LeaseStoreError.posix(operation: "open marker", code: errno)
    }

    var writeError: Error?
    data.withUnsafeBytes { bytes in
      guard let baseAddress = bytes.baseAddress else { return }
      var written = 0
      while written < bytes.count {
        let result = Darwin.write(
          descriptor, baseAddress.advanced(by: written), bytes.count - written)
        if result < 0 {
          writeError = LeaseStoreError.posix(operation: "write marker", code: errno)
          break
        }
        written += result
      }
    }

    if writeError == nil, fsync(descriptor) != 0 {
      writeError = LeaseStoreError.posix(operation: "fsync marker", code: errno)
    }
    close(descriptor)

    if let writeError {
      unlink(temporaryURL.path)
      throw writeError
    }

    guard rename(temporaryURL.path, markerURL.path) == 0 else {
      let code = errno
      unlink(temporaryURL.path)
      throw LeaseStoreError.posix(operation: "rename marker", code: code)
    }
    try syncDirectory()
  }

  func clear() throws {
    guard markerExists else { return }
    guard unlink(markerURL.path) == 0 else {
      throw LeaseStoreError.posix(operation: "remove marker", code: errno)
    }
    try syncDirectory()
  }

  private func ensureSafeDirectory() throws {
    var metadata = stat()
    if lstat(directoryURL.path, &metadata) == 0 {
      let isDirectory = metadata.st_mode & S_IFMT == S_IFDIR
      let safePermissions = metadata.st_mode & 0o077 == 0
      guard isDirectory, metadata.st_uid == 0, safePermissions else {
        throw LeaseStoreError.invalidDirectory
      }
      return
    }

    guard errno == ENOENT else {
      throw LeaseStoreError.posix(operation: "inspect marker directory", code: errno)
    }
    guard mkdir(directoryURL.path, S_IRWXU) == 0 else {
      throw LeaseStoreError.posix(operation: "create marker directory", code: errno)
    }
    try syncParentDirectory()
  }

  private func syncDirectory() throws {
    let descriptor = open(directoryURL.path, O_RDONLY)
    guard descriptor >= 0 else {
      throw LeaseStoreError.posix(operation: "open marker directory", code: errno)
    }
    defer { close(descriptor) }
    guard fsync(descriptor) == 0 else {
      throw LeaseStoreError.posix(operation: "fsync marker directory", code: errno)
    }
  }

  private func syncParentDirectory() throws {
    let descriptor = open(directoryURL.deletingLastPathComponent().path, O_RDONLY)
    guard descriptor >= 0 else {
      throw LeaseStoreError.posix(operation: "open marker parent", code: errno)
    }
    defer { close(descriptor) }
    guard fsync(descriptor) == 0 else {
      throw LeaseStoreError.posix(operation: "fsync marker parent", code: errno)
    }
  }
}
