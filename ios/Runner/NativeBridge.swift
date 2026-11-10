import Flutter
import QuickLookThumbnailing
import UIKit
import UniformTypeIdentifiers

/// iOS side of `lib/services/platform_bridge.dart` (channel `datacast/native`).
///
/// Android reads picked folders through the Storage Access Framework. On iOS
/// the Files picker hands us a security-scoped URL instead. We save it as a
/// bookmark (returned to Dart as an `ios-bookmark:<base64>` URI), and on use we
/// resolve the bookmark, start security-scoped access and give Dart the plain
/// filesystem path so it can read files with `dart:io` directly.
final class NativeBridge: NSObject, FlutterPlugin, UIDocumentPickerDelegate {
  static let bookmarkScheme = "ios-bookmark:"

  private let channel: FlutterMethodChannel
  private let io = DispatchQueue(label: "datacast.io", qos: .userInitiated, attributes: .concurrent)
  private let lock = NSLock()
  /// Bookmark URI -> resolved URL with security-scoped access started.
  private var resolved: [String: URL] = [:]
  private let thumbCache = NSCache<NSString, NSData>()

  private var pendingFolder: FlutterResult?
  private var pendingFiles: FlutterResult?
  private weak var folderPicker: UIDocumentPickerViewController?

  /// True between startService and stopService; gives ongoing downloads a
  /// short grace period when the app goes to the background.
  private var sharing = false
  private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

  init(channel: FlutterMethodChannel) {
    self.channel = channel
    super.init()
    thumbCache.totalCostLimit = 32 * 1024 * 1024
    let nc = NotificationCenter.default
    nc.addObserver(self, selector: #selector(didEnterBackground),
                   name: UIApplication.didEnterBackgroundNotification, object: nil)
    nc.addObserver(self, selector: #selector(willEnterForeground),
                   name: UIApplication.willEnterForegroundNotification, object: nil)
  }

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "datacast/native", binaryMessenger: registrar.messenger())
    let instance = NativeBridge(channel: channel)
    registrar.addMethodCallDelegate(instance, channel: channel)
    registrar.publish(instance)
  }

  // MARK: - Method calls

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    let uri = args["uri"] as? String
    let path = args["path"] as? String ?? "/"
    let size = args["size"] as? Int ?? 256

    switch call.method {
    case "pickFolder": pick(folder: true, result: result)
    case "pickFiles": pick(folder: false, result: result)

    case "resolveBookmark":
      background(result) { [self] in url(for: uri)?.path }

    case "hasFolderAccess", "hasDocAccess":
      background(result) { [self] in
        guard let u = url(for: uri) else { return false }
        return FileManager.default.fileExists(atPath: u.path)
      }

    case "docStat":
      background(result) { [self] in url(for: uri).flatMap(Self.stat) }

    case "thumbnail":
      guard let base = url(for: uri) else { return result(nil) }
      thumbnail(of: Self.child(of: base, path: path), size: size, result: result)

    case "docThumbnail":
      guard let u = url(for: uri) else { return result(nil) }
      thumbnail(of: u, size: size, result: result)

    case "deviceName":
      result(UIDevice.current.name)

    case "setKeepScreenOn":
      UIApplication.shared.isIdleTimerDisabled = args["on"] as? Bool ?? false
      result(nil)

    case "startService":
      sharing = true
      result(nil)

    case "stopService":
      sharing = false
      endBackgroundTask()
      result(nil)

    case "openWifiSettings":
      // iOS has no public link to the Wi-Fi page; open Settings instead.
      if let u = URL(string: UIApplication.openSettingsURLString) {
        UIApplication.shared.open(u)
      }
      result(nil)

    default:
      // list/stat/openFd/readChunk are Android-only: iOS reads via dart:io.
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Bookmarks

  /// Resolves an `ios-bookmark:` URI and starts security-scoped access once
  /// per URI for the life of the process.
  private func url(for uri: String?) -> URL? {
    guard let uri, uri.hasPrefix(Self.bookmarkScheme) else { return nil }
    lock.lock()
    defer { lock.unlock() }
    if let u = resolved[uri] { return u }
    guard let data = Data(base64Encoded: String(uri.dropFirst(Self.bookmarkScheme.count))) else { return nil }
    var stale = false
    guard let u = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
    else { return nil }
    _ = u.startAccessingSecurityScopedResource()
    resolved[uri] = u
    return u
  }

  private func bookmarkURI(for url: URL) throws -> String {
    let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    let uri = Self.bookmarkScheme + data.base64EncodedString()
    lock.lock()
    if resolved[uri] == nil { resolved[uri] = url } else { url.stopAccessingSecurityScopedResource() }
    lock.unlock()
    return uri
  }

  private static func child(of base: URL, path: String) -> URL {
    var u = base
    for part in path.split(separator: "/") where !part.isEmpty && part != "." && part != ".." {
      u.appendPathComponent(String(part))
    }
    return u
  }

  private static func stat(_ url: URL) -> [String: Any]? {
    guard let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .nameKey])
    else { return nil }
    let name = v.name ?? url.lastPathComponent
    var out: [String: Any] = ["name": name, "size": v.fileSize ?? 0]
    if let d = v.contentModificationDate { out["modified"] = Int(d.timeIntervalSince1970 * 1000) }
    if let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType { out["mime"] = mime }
    return out
  }

  // MARK: - Pickers

  private func pick(folder: Bool, result: @escaping FlutterResult) {
    guard let top = Self.topViewController() else {
      return result(FlutterError(code: "no_activity", message: "App is not in the foreground", details: nil))
    }
    if folder { pendingFolder?(nil); pendingFolder = result } else { pendingFiles?(nil); pendingFiles = result }
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: folder ? [.folder] : [.item], asCopy: false)
    picker.allowsMultipleSelection = !folder
    picker.delegate = self
    if folder { folderPicker = picker }
    top.present(picker, animated: true)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    let isFolder = controller === folderPicker
    let result = isFolder ? pendingFolder : pendingFiles
    if isFolder { pendingFolder = nil } else { pendingFiles = nil }
    guard let result else { return }
    io.async { [self] in
      do {
        if isFolder {
          guard let u = urls.first else { return DispatchQueue.main.async { result(nil) } }
          _ = u.startAccessingSecurityScopedResource()
          let uri = try bookmarkURI(for: u)
          let name = u.lastPathComponent
          DispatchQueue.main.async { result(["uri": uri, "name": name]) }
        } else {
          var files: [[String: Any]] = []
          for u in urls {
            _ = u.startAccessingSecurityScopedResource()
            guard var m = Self.stat(u) else { continue }
            m["uri"] = try bookmarkURI(for: u)
            files.append(m)
          }
          DispatchQueue.main.async { result(files.isEmpty ? nil : files) }
        }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(code: "pick_failed", message: error.localizedDescription, details: nil))
        }
      }
    }
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    if controller === folderPicker { pendingFolder?(nil); pendingFolder = nil } else { pendingFiles?(nil); pendingFiles = nil }
  }

  private static func topViewController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.first?.windows.first
    var vc = window?.rootViewController
    while let presented = vc?.presentedViewController { vc = presented }
    return vc
  }

  // MARK: - Thumbnails

  private func thumbnail(of url: URL, size: Int, result: @escaping FlutterResult) {
    let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    let key = "\(url.path)|\(size)|\(mtime?.timeIntervalSince1970 ?? 0)" as NSString
    if let hit = thumbCache.object(forKey: key) { return result(FlutterStandardTypedData(bytes: hit as Data)) }
    let request = QLThumbnailGenerator.Request(
      fileAt: url, size: CGSize(width: size, height: size), scale: 1, representationTypes: .thumbnail)
    QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [thumbCache = self.thumbCache] rep, _ in
      let jpeg = rep?.uiImage.jpegData(compressionQuality: 0.8)
      if let jpeg { thumbCache.setObject(jpeg as NSData, forKey: key, cost: jpeg.count) }
      DispatchQueue.main.async { result(jpeg.map { FlutterStandardTypedData(bytes: $0) }) }
    }
  }

  // MARK: - Background grace

  @objc private func didEnterBackground() {
    guard sharing, backgroundTask == .invalid else { return }
    // iOS suspends the app shortly after this. Ask for the usual ~30 s so a
    // quick app switch doesn't cut off a download mid-way.
    backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "DataCast sharing") { [weak self] in
      self?.endBackgroundTask()
    }
  }

  @objc private func willEnterForeground() { endBackgroundTask() }

  private func endBackgroundTask() {
    guard backgroundTask != .invalid else { return }
    UIApplication.shared.endBackgroundTask(backgroundTask)
    backgroundTask = .invalid
  }

  // MARK: - Helpers

  private func background(_ result: @escaping FlutterResult, _ block: @escaping () -> Any?) {
    io.async {
      let value = block()
      DispatchQueue.main.async { result(value) }
    }
  }
}
