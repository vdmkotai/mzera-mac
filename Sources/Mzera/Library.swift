import CoreGraphics
import CoreServices
import Foundation

struct MediaEntry: Hashable, Codable {
  let path: String
  let size: Int64
  let modified: Double
  let isVideo: Bool
  var name: String {
    String(
      path.suffix(from: path.lastIndex(of: "/").map { path.index(after: $0) } ?? path.startIndex))
  }
  var folder: String { path.lastIndex(of: "/").map { String(path[..<$0]) } ?? "" }
  static let images: Set<String> = [
    "jpg", "jpeg", "png", "webp", "avif", "gif", "heic", "heif", "jxl", "tif", "tiff", "bmp",
    "apng", "jfif", "jpe", "jp2", "heics",
  ]
  static let videos: Set<String> = [
    "webm", "mp4", "m4v", "mov", "mkv", "avi", "mpg", "mpeg", "3gp", "wmv", "flv", "ts", "ogv",
  ]
}

/// Stable, locale-independent natural order. Numeric runs have no integer-size limit.
struct NaturalKey: Comparable {
  let bytes: [UInt8]
  init(_ text: String) {
    let input = Array(text.precomposedStringWithCanonicalMapping.lowercased().utf8)
    var result: [UInt8] = []
    result.reserveCapacity(input.count * 2)
    var i = 0
    while i < input.count {
      if input[i] >= 48 && input[i] <= 57 {
        var end = i + 1
        while end < input.count && input[end] >= 48 && input[end] <= 57 { end += 1 }
        var start = i
        while start + 1 < end && input[start] == 48 { start += 1 }
        let length = UInt32(end - start)
        result.append(1)
        for shift in [24, 16, 8, 0] { result.append(UInt8(truncatingIfNeeded: length >> shift)) }
        result.append(contentsOf: input[start..<end])
        i = end
      } else {
        result.append(2)
        result.append(input[i])
        i += 1
      }
    }
    bytes = result
  }
  static func < (lhs: Self, rhs: Self) -> Bool { lhs.bytes.lexicographicallyPrecedes(rhs.bytes) }
}

enum SortOrder: Int, CaseIterable {
  case path, name, newest, largest
  var title: String { ["Folder / name", "Name", "Newest first", "Largest first"][rawValue] }
  func sorted(_ entries: [MediaEntry], grouped: Bool) -> [MediaEntry] {
    var folderKeys: [(String, NaturalKey)] =
      grouped ? Set(entries.map(\.folder)).map { ($0, NaturalKey($0)) } : []
    folderKeys.sort {
      $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 < $1.1
    }
    let ranks: [String: Int] = Dictionary(
      uniqueKeysWithValues: folderKeys.enumerated().map { ($0.element.0, $0.offset) })
    let keys = entries.map { entry in
      (
        path: NaturalKey(entry.path), name: self == .name ? NaturalKey(entry.name) : NaturalKey(""),
        folder: grouped ? ranks[entry.folder, default: 0] : 0
      )
    }
    return entries.indices.sorted { ai, bi in
      let a = entries[ai]
      let b = entries[bi]
      let ak = keys[ai]
      let bk = keys[bi]
      if ak.folder != bk.folder { return ak.folder < bk.folder }
      switch self {
      case .path: break
      case .name:
        if ak.name != bk.name { return ak.name < bk.name }
      case .newest: if a.modified != b.modified { return a.modified > b.modified }
      case .largest: if a.size != b.size { return a.size > b.size }
      }
      return ak.path == bk.path ? a.path < b.path : ak.path < bk.path
    }.map { entries[$0] }
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
  static func sameContents(_ a: [MediaEntry], _ b: [MediaEntry]) -> Bool {
    a.count == b.count && Set(a) == Set(b)
  }
  static func scan(
    root: URL, cancellation: Cancellation, recursive: Bool = true, batch: ([MediaEntry]) -> Void
  ) -> (
    count: Int, errors: Int
  ) {
    let keys: [URLResourceKey] = [
      .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
    ]
    let keySet = Set(keys)
    var errors = 0
    var count = 0
    var pending: [MediaEntry] = []
    let enumerator = FileManager.default.enumerator(
      at: root, includingPropertiesForKeys: keys,
      options: recursive ? [] : [.skipsSubdirectoryDescendants],
      errorHandler: { _, _ in
        errors += 1
        return !cancellation.cancelled
      })
    while !cancellation.cancelled, let url = enumerator?.nextObject() as? URL {
      guard !url.lastPathComponent.hasPrefix("._") else { continue }
      let ext = url.pathExtension.lowercased()
      guard MediaEntry.images.contains(ext) || MediaEntry.videos.contains(ext) else { continue }
      do {
        let v = try url.resourceValues(forKeys: keySet)
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
  private final class Item {
    let key: Key
    let value: Value
    let cost: Int
    weak var previous: Item?
    var next: Item?
    init(_ key: Key, _ value: Value, _ cost: Int) {
      self.key = key
      self.value = value
      self.cost = cost
    }
  }
  private var items: [Key: Item] = [:]
  private var oldest: Item?
  private var newest: Item?
  private(set) var cost = 0
  var limit: Int { didSet { trim() } }
  init(limit: Int) { self.limit = limit }
  var count: Int { items.count }
  func get(_ key: Key) -> Value? {
    guard let item = items[key] else { return nil }
    if item !== newest {
      unlink(item)
      append(item)
    }
    return item.value
  }
  func peek(_ key: Key) -> Value? { items[key]?.value }
  private func unlink(_ item: Item) {
    if let previous = item.previous { previous.next = item.next } else { oldest = item.next }
    if let next = item.next { next.previous = item.previous } else { newest = item.previous }
    item.previous = nil
    item.next = nil
  }
  private func append(_ item: Item) {
    item.previous = newest
    newest?.next = item
    if oldest == nil { oldest = item }
    newest = item
  }
  func put(_ key: Key, _ value: Value, cost bytes: Int) {
    if let old = items.removeValue(forKey: key) {
      cost -= old.cost
      unlink(old)
    }
    guard bytes >= 0 && bytes <= limit else { return }
    let item = Item(key, value, bytes)
    items[key] = item
    append(item)
    cost += bytes
    trim()
  }
  func clear() {
    // Break links iteratively: a huge cache must not recursively release a long chain.
    while let item = oldest { unlink(item) }
    items.removeAll()
    cost = 0
  }
  private func trim() {
    while cost > max(0, limit), let item = oldest {
      cost -= item.cost
      unlink(item)
      items.removeValue(forKey: item.key)
    }
  }
  deinit { clear() }
}

final class FolderWatcher {
  struct Change: Hashable {
    let path: String
    let recursive: Bool
  }
  private var stream: FSEventStreamRef?
  private let changed: (Set<Change>?) -> Void
  init(path: String, changed: @escaping (Set<Change>?) -> Void) {
    self.changed = changed
    var context = FSEventStreamContext(
      version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil,
      copyDescription: nil)
    stream = FSEventStreamCreate(
      nil,
      { _, info, count, rawPaths, flags, _ in
        guard let info else { return }
        let owner = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
        let paths = unsafeBitCast(rawPaths, to: CFArray.self) as! [String]
        var changes = Set<Change>()
        let full = FSEventStreamEventFlags(
          kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
            | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged
            | kFSEventStreamEventFlagEventIdsWrapped)
        for i in 0..<count {
          if flags[i] & full != 0 {
            owner.changed(nil)
            return
          }
          let directory = flags[i] & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0
          let structural =
            flags[i]
            & FSEventStreamEventFlags(
              kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved
                | kFSEventStreamEventFlagItemRenamed) != 0
          let url = URL(fileURLWithPath: paths[i]).standardizedFileURL
          changes.insert(
            Change(
              path: directory ? url.path : url.deletingLastPathComponent().path,
              recursive: directory && structural))
        }
        if !changes.isEmpty { owner.changed(changes) }
      }, &context, [path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.5,
      FSEventStreamCreateFlags(
        kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagFileEvents
          | kFSEventStreamCreateFlagUseCFTypes))
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
