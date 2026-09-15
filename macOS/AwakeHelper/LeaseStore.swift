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
      "復旧マーカーのディレクトリがroot所有ではないか、安全でない権限が設定されています。"
    case .posix(let operation, let code):
      "\(operation)に失敗しました。\(String(cString: strerror(code)))"
    }
  }
}

final class LeaseStore {
  private let directoryURL = URL(fileURLWithPath: "/var/db/jp.co.seeds-std.Awake", isDirectory: true)
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
      throw LeaseStoreError.posix(operation: "復旧マーカーを開く処理", code: errno)
    }

    var writeError: Error?
    data.withUnsafeBytes { bytes in
      guard let baseAddress = bytes.baseAddress else { return }
      var written = 0
      while written < bytes.count {
        let result = Darwin.write(
          descriptor, baseAddress.advanced(by: written), bytes.count - written)
        if result < 0 {
          writeError = LeaseStoreError.posix(operation: "復旧マーカーの書き込み", code: errno)
          break
        }
        written += result
      }
    }

    if writeError == nil, fsync(descriptor) != 0 {
      writeError = LeaseStoreError.posix(operation: "復旧マーカーの同期", code: errno)
    }
    close(descriptor)

    if let writeError {
      unlink(temporaryURL.path)
      throw writeError
    }

    guard rename(temporaryURL.path, markerURL.path) == 0 else {
      let code = errno
      unlink(temporaryURL.path)
      throw LeaseStoreError.posix(operation: "復旧マーカーの確定", code: code)
    }
    try syncDirectory()
  }

  func clear() throws {
    guard markerExists else { return }
    guard unlink(markerURL.path) == 0 else {
      throw LeaseStoreError.posix(operation: "復旧マーカーの削除", code: errno)
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
      throw LeaseStoreError.posix(operation: "復旧マーカーディレクトリの確認", code: errno)
    }
    guard mkdir(directoryURL.path, S_IRWXU) == 0 else {
      throw LeaseStoreError.posix(operation: "復旧マーカーディレクトリの作成", code: errno)
    }
    try syncParentDirectory()
  }

  private func syncDirectory() throws {
    let descriptor = open(directoryURL.path, O_RDONLY)
    guard descriptor >= 0 else {
      throw LeaseStoreError.posix(operation: "復旧マーカーディレクトリを開く処理", code: errno)
    }
    defer { close(descriptor) }
    guard fsync(descriptor) == 0 else {
      throw LeaseStoreError.posix(operation: "復旧マーカーディレクトリの同期", code: errno)
    }
  }

  private func syncParentDirectory() throws {
    let descriptor = open(directoryURL.deletingLastPathComponent().path, O_RDONLY)
    guard descriptor >= 0 else {
      throw LeaseStoreError.posix(operation: "復旧マーカーの親ディレクトリを開く処理", code: errno)
    }
    defer { close(descriptor) }
    guard fsync(descriptor) == 0 else {
      throw LeaseStoreError.posix(operation: "復旧マーカーの親ディレクトリの同期", code: errno)
    }
  }
}
