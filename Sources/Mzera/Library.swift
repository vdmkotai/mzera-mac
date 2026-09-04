import CoreServices
import Foundation

struct MediaEntry: Hashable, Codable {
  let path: String
  let size: Int64
  let modified: Double
  let isVideo: Bool
  var name: String { (path as NSString).lastPathComponent }
  var folder: String { (path as NSString).deletingLastPathComponent }
  static let images: Set<String> = [
    "jpg", "jpeg", "png", "webp", "avif", "gif", "heic", "heif", "jxl", "tif", "tiff", "bmp",
    "apng",
  ]
  static let videos: Set<String> = ["webm", "mp4", "m4v", "mov", "mkv", "avi"]
}

enum SortOrder: Int, CaseIterable {
  case path, name, newest, largest
  var title: String { ["Folder / name", "Name", "Newest first", "Largest first"][rawValue] }
  func sorted(_ entries: [MediaEntry], grouped: Bool) -> [MediaEntry] {
    entries.sorted { a, b in
      if grouped && a.folder != b.folder {
        return a.folder.localizedStandardCompare(b.folder) == .orderedAscending
      }
      switch self {
      case .path: break
      case .name:
        let c = a.name.localizedStandardCompare(b.name)
        if c != .orderedSame { return c == .orderedAscending }
      case .newest: if a.modified != b.modified { return a.modified > b.modified }
      case .largest: if a.size != b.size { return a.size > b.size }
      }
      return a.path.localizedStandardCompare(b.path) == .orderedAscending
    }
  }
}

final class Cancellation {
  private let lock = NSLock()
  private var value = false
  var cancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
  func cancel() {
    lock.lock()
    value = true
    lock.unlock()
  }
}

enum Scanner {
  static func scan(root: URL, cancellation: Cancellation, batch: ([MediaEntry]) -> Void) -> (
    count: Int, errors: Int
  ) {
    let keys: [URLResourceKey] = [
      .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
    ]
    var errors = 0
    var count = 0
    var pending: [MediaEntry] = []
    let enumerator = FileManager.default.enumerator(
      at: root, includingPropertiesForKeys: keys,
      options: [],
      errorHandler: { _, _ in
        errors += 1
        return !cancellation.cancelled
      })
    while !cancellation.cancelled, let url = enumerator?.nextObject() as? URL {
      let ext = url.pathExtension.lowercased()
      guard MediaEntry.images.contains(ext) || MediaEntry.videos.contains(ext) else { continue }
      do {
        let v = try url.resourceValues(forKeys: Set(keys))
        guard v.isRegularFile == true, v.isSymbolicLink != true else { continue }
        pending.append(
          MediaEntry(
            path: url.path, size: Int64(v.fileSize ?? 0),
            modified: v.contentModificationDate?.timeIntervalSince1970 ?? 0,
            isVideo: MediaEntry.videos.contains(ext)))
        count += 1
        if pending.count >= 256 {
          batch(pending)
          pending.removeAll(keepingCapacity: true)
        }
      } catch { errors += 1 }
    }
    if !pending.isEmpty && !cancellation.cancelled { batch(pending) }
    return (count, errors)
  }
}

struct GridSection {
  let title: String
  let start: Int
  let count: Int
  var y: Double = 0
  var bottom: Double = 0
}

struct GridLayout {
  var width: Double = 1000
  var tile: Double = 160
  var gap: Double = 8
  var columns = 1
  var height: Double = 1
  var sections: [GridSection] = []
  var grouped = false
  var count = 0
  var stride: Double { tile + gap }
  var header: Double { grouped ? 30 : 0 }
  mutating func rebuild(entries: [MediaEntry], width: Double, tile: Double, grouped: Bool) {
    self.width = width
    self.tile = tile
    self.grouped = grouped
    count = entries.count
    columns = max(1, Int((max(width, 1) - gap) / stride))
    sections = []
    if grouped {
      var start = 0
      while start < entries.count {
        let folder = entries[start].folder
        var end = start + 1
        while end < entries.count && entries[end].folder == folder { end += 1 }
        sections.append(GridSection(title: folder, start: start, count: end - start))
        start = end
      }
    } else if !entries.isEmpty {
      sections = [GridSection(title: "", start: 0, count: entries.count)]
    }
    reflow(width: width, tile: tile)
  }
  mutating func reflow(width: Double, tile: Double) {
    self.width = width
    self.tile = tile
    columns = max(1, Int((max(width, 1) - gap) / stride))
    var y = gap
    for i in sections.indices {
      sections[i].y = y
      y += header + Double((sections[i].count + columns - 1) / columns) * stride
      sections[i].bottom = y
    }
    height = max(1, y)
  }
  func section(at y: Double) -> Int {
    var lo = 0
    var hi = sections.count
    while lo < hi {
      let mid = (lo + hi) / 2
      if sections[mid].bottom <= y { lo = mid + 1 } else { hi = mid }
    }
    return lo
  }
  func visible(offset: Double, height: Double, overscan: Double = 0) -> [Int] {
    guard count > 0 else { return [] }
    let top = max(0, offset - overscan)
    let bottom = offset + height + overscan
    var si = section(at: top)
    var result: [Int] = []
    while si < sections.count && sections[si].y < bottom {
      let s = sections[si]
      var firstRow = max(0, Int(floor((top - s.y - header) / stride)))
      if s.y + header + Double(firstRow) * stride + tile <= top { firstRow += 1 }
      let first = firstRow * columns
      let last = min(s.count, max(0, Int(ceil((bottom - s.y - header) / stride))) * columns)
      if first < last { result.append(contentsOf: (s.start + first)..<(s.start + last)) }
      si += 1
    }
    return result
  }
  func rect(at index: Int) -> CGRect {
    guard index >= 0 && index < count else { return .zero }
    var lo = 0
    var hi = sections.count
    while lo < hi {
      let m = (lo + hi) / 2
      if sections[m].start <= index { lo = m + 1 } else { hi = m }
    }
    let s = sections[max(0, lo - 1)]
    let local = index - s.start
    return CGRect(
      x: gap + Double(local % columns) * stride, y: s.y + header + Double(local / columns) * stride,
      width: tile, height: tile)
  }
  func hit(x: Double, y: Double) -> Int? {
    let si = section(at: y)
    guard si < sections.count else { return nil }
    let s = sections[si]
    let localY = y - s.y - header
    guard localY >= 0, x >= gap else { return nil }
    let col = Int((x - gap) / stride)
    let row = Int(localY / stride)
    let index = s.start + row * columns + col
    guard col < columns, index < s.start + s.count, rect(at: index).contains(CGPoint(x: x, y: y))
    else { return nil }
    return index
  }
}

final class ByteLRU<Key: Hashable, Value> {
  private struct Item {
    var value: Value
    var cost: Int
    var stamp: UInt64
  }
  private var items: [Key: Item] = [:]
  private var clock: UInt64 = 0
  private(set) var cost = 0
  var limit: Int { didSet { trim() } }
  init(limit: Int) { self.limit = limit }
  var count: Int { items.count }
  func get(_ key: Key) -> Value? {
    guard var item = items[key] else { return nil }
    clock &+= 1
    item.stamp = clock
    items[key] = item
    return item.value
  }
  func put(_ key: Key, _ value: Value, cost bytes: Int) {
    if let old = items.removeValue(forKey: key) { cost -= old.cost }
    guard bytes <= limit else { return }
    clock &+= 1
    items[key] = Item(value: value, cost: bytes, stamp: clock)
    cost += bytes
    trim()
  }
  func clear() {
    items.removeAll()
    cost = 0
  }
  private func trim() {
    while cost > limit, let oldest = items.min(by: { $0.value.stamp < $1.value.stamp }) {
      cost -= oldest.value.cost
      items.removeValue(forKey: oldest.key)
    }
  }
}

final class FolderWatcher {
  private var stream: FSEventStreamRef?
  private let changed: () -> Void
  init(path: String, changed: @escaping () -> Void) {
    self.changed = changed
    var context = FSEventStreamContext(
      version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil,
      copyDescription: nil)
    stream = FSEventStreamCreate(
      nil,
      { _, info, _, _, _, _ in
        guard let info else { return }
        Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue().changed()
      }, &context, [path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.5,
      FSEventStreamCreateFlags(
        kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagFileEvents))
    if let stream {
      FSEventStreamSetDispatchQueue(stream, .main)
      FSEventStreamStart(stream)
    }
  }
  deinit {
    if let stream {
      FSEventStreamStop(stream)
      FSEventStreamInvalidate(stream)
      FSEventStreamRelease(stream)
    }
  }
}
