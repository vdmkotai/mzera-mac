import CMedia
import Foundation

final class Catalog {
  let base: URL
  let queue = DispatchQueue(label: "mzera.catalog", qos: .utility)
  private var db: OpaquePointer?
  private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
  private(set) var lastError: String?
  private(set) var saveCount = 0
  private(set) var lastSaveChangedRows = 0
  private var pendingCache: [String: (bytes: Int?, time: Double)] = [:]
  private var pendingFlush: DispatchWorkItem?
  private var pendingDurations: [MediaEntry: Double] = [:]
  private var cacheBytes: Int64 = 0

  private struct Failure: Error { let message: String }
  init(base: URL? = nil) {
    self.base =
      base
      ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("local.mzera.mac")
    do {
      try FileManager.default.createDirectory(at: self.base, withIntermediateDirectories: true)
      try check(
        sqlite3_open_v2(
          self.base.appendingPathComponent("catalog.sqlite").path, &db,
          SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil))
      try check(sqlite3_busy_timeout(db, 3000))
      try execute(
        "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; CREATE TABLE IF NOT EXISTS media(root TEXT,path TEXT,size INTEGER,modified REAL,video INTEGER,PRIMARY KEY(root,path)); CREATE TABLE IF NOT EXISTS roots(path TEXT PRIMARY KEY); CREATE TABLE IF NOT EXISTS cache(key TEXT PRIMARY KEY,bytes INTEGER,touched REAL); CREATE TABLE IF NOT EXISTS durations(path TEXT PRIMARY KEY,size INTEGER,modified REAL,seconds REAL);"
      )
      if try !columns("media").contains("position") {
        try execute("ALTER TABLE media ADD COLUMN position INTEGER NOT NULL DEFAULT 0")
      }
      if try !columns("roots").contains("order_key") {
        try execute("ALTER TABLE roots ADD COLUMN order_key TEXT NOT NULL DEFAULT ''")
      }
      try execute(
        "CREATE INDEX IF NOT EXISTS media_order ON media(root,position); CREATE INDEX IF NOT EXISTS cache_age ON cache(touched)"
      )
      cacheBytes = try statement("SELECT COALESCE(SUM(bytes),0) FROM cache") { s in
        _ = try step(s)
        return sqlite3_column_int64(s, 0)
      }
    } catch {
      report(error)
      sqlite3_close(db)
      db = nil  // Originals remain viewable without a working cache database.
    }
  }
  deinit {
    pendingFlush?.cancel()
    sqlite3_close(db)
  }
  private func check(_ code: Int32) throws {
    guard code == SQLITE_OK else {
      throw Failure(message: db.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite unavailable")
    }
  }
  private func report(_ error: Error) {
    lastError = (error as? Failure)?.message ?? error.localizedDescription
    NSLog("Mzera catalog: %@", lastError!)
  }
  private func execute(_ sql: String) throws {
    guard db != nil else { throw Failure(message: "Catalog unavailable") }
    try check(sqlite3_exec(db, sql, nil, nil, nil))
  }
  private func statement<T>(_ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
    guard db != nil else { throw Failure(message: "Catalog unavailable") }
    var s: OpaquePointer?
    try check(sqlite3_prepare_v2(db, sql, -1, &s, nil))
    guard let s else { throw Failure(message: "Empty SQLite statement") }
    defer { sqlite3_finalize(s) }
    return try body(s)
  }
  private func bind(_ s: OpaquePointer, _ index: Int32, _ text: String) throws {
    try check(sqlite3_bind_text(s, index, text, -1, transient))
  }
  private func step(_ s: OpaquePointer) throws -> Bool {
    let result = sqlite3_step(s)
    if result == SQLITE_ROW { return true }
    if result == SQLITE_DONE { return false }
    try check(result)
    return false
  }
  private func columns(_ table: String) throws -> Set<String> {
    try statement("PRAGMA table_info(\(table))") { s in
      var result = Set<String>()
      while try step(s) {
        if let value = sqlite3_column_text(s, 1) { result.insert(String(cString: value)) }
      }
      return result
    }
  }
  private func read(root: String) throws -> [MediaEntry]? {
    let exists = try statement("SELECT 1 FROM roots WHERE path=?") { s in
      try bind(s, 1, root)
      return try step(s)
    }
    guard exists else { return nil }
    return try statement(
      "SELECT path,size,modified,video FROM media WHERE root=? ORDER BY position"
    ) { s in
      try bind(s, 1, root)
      var result: [MediaEntry] = []
      while try step(s) {
        guard let p = sqlite3_column_text(s, 0) else { throw Failure(message: "NULL media path") }
        result.append(
          MediaEntry(
            path: String(cString: p), size: sqlite3_column_int64(s, 1),
            modified: sqlite3_column_double(s, 2), isVideo: sqlite3_column_int(s, 3) != 0))
      }
      return result
    }
  }
  // All methods except the explicitly queued cache operations are called on queue.
  func load(root: String) -> [MediaEntry]? {
    do { return try read(root: root) } catch {
      report(error)
      return nil
    }
  }
  func orderKey(root: String) -> String? {
    do {
      return try statement("SELECT order_key FROM roots WHERE path=?") { s in
        try bind(s, 1, root)
        guard try step(s), let value = sqlite3_column_text(s, 0) else { return nil }
        return String(cString: value)
      }
    } catch {
      report(error)
      return nil
    }
  }
  @discardableResult
  func save(root: String, entries: [MediaEntry], orderKey: String = "") -> Bool {
    do {
      try execute("BEGIN IMMEDIATE")
      do {
        let previous = try read(root: root) ?? []
        let old = Dictionary(
          uniqueKeysWithValues: previous.enumerated().map {
            ($0.element.path, ($0.offset, $0.element))
          })
        let paths = Set(entries.map(\.path))
        guard paths.count == entries.count else { throw Failure(message: "Duplicate media path") }
        var changed = 0
        try statement("DELETE FROM media WHERE root=? AND path=?") { s in
          for e in previous where !paths.contains(e.path) {
            try check(sqlite3_reset(s))
            try bind(s, 1, root)
            try bind(s, 2, e.path)
            _ = try step(s)
            changed += 1
          }
        }
        try statement("DELETE FROM durations WHERE path=?") { s in
          for e in previous where e.isVideo && !paths.contains(e.path) {
            try check(sqlite3_reset(s))
            try bind(s, 1, e.path)
            _ = try step(s)
          }
        }
        try statement(
          "INSERT INTO media(root,path,size,modified,video,position) VALUES(?,?,?,?,?,?) ON CONFLICT(root,path) DO UPDATE SET size=excluded.size,modified=excluded.modified,video=excluded.video,position=excluded.position"
        ) { s in
          for (position, e) in entries.enumerated() {
            if let prior = old[e.path], prior.0 == position && prior.1 == e { continue }
            try check(sqlite3_reset(s))
            try bind(s, 1, root)
            try bind(s, 2, e.path)
            try check(sqlite3_bind_int64(s, 3, e.size))
            try check(sqlite3_bind_double(s, 4, e.modified))
            try check(sqlite3_bind_int(s, 5, e.isVideo ? 1 : 0))
            try check(sqlite3_bind_int64(s, 6, Int64(position)))
            _ = try step(s)
            changed += 1
          }
        }
        try statement(
          "INSERT INTO roots(path,order_key) VALUES(?,?) ON CONFLICT(path) DO UPDATE SET order_key=excluded.order_key WHERE roots.order_key!=excluded.order_key"
        ) { s in
          try bind(s, 1, root)
          try bind(s, 2, orderKey)
          _ = try step(s)
        }
        try execute("COMMIT")
        saveCount += 1
        lastSaveChangedRows = changed
        lastError = nil
        return true
      } catch {
        try? execute("ROLLBACK")
        throw error
      }
    } catch {
      report(error)
      return false
    }
  }
  /// Video durations under root that still match the file's size and modification time.
  func durations(root: String, entries: [MediaEntry]) -> [MediaEntry: Double] {
    guard !entries.isEmpty else { return [:] }
    let prefix = root.hasSuffix("/") ? root : root + "/"
    let byPath = Dictionary(
      entries.filter(\.isVideo).map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
    guard !byPath.isEmpty else { return [:] }
    do {
      // "0" follows "/" in byte order, so the range covers exactly the paths under root.
      return try statement(
        "SELECT path,size,modified,seconds FROM durations WHERE path>=? AND path<?"
      ) { s in
        try bind(s, 1, prefix)
        try bind(s, 2, String(prefix.dropLast()) + "0")
        var result: [MediaEntry: Double] = [:]
        while try step(s) {
          guard let raw = sqlite3_column_text(s, 0),
            let entry = byPath[String(cString: raw)],
            entry.size == sqlite3_column_int64(s, 1),
            entry.modified == sqlite3_column_double(s, 2)
          else { continue }
          result[entry] = sqlite3_column_double(s, 3)
        }
        return result
      }
    } catch {
      report(error)
      return [:]
    }
  }
  /// Batched with cache bookkeeping; 0 records a length that could not be read.
  func saveDuration(_ entry: MediaEntry, seconds: Double) {
    queue.async { [self] in
      guard db != nil else { return }
      pendingDurations[entry] = seconds
      scheduleFlush()
    }
  }
  func noteCache(key: String, bytes: Int) { enqueueCache(key: key, bytes: max(0, bytes)) }
  func touchCache(key: String) { enqueueCache(key: key, bytes: nil) }
  private func enqueueCache(key: String, bytes: Int?) {
    queue.async { [self] in
      guard db != nil else { return }
      pendingCache[key] = (bytes ?? pendingCache[key]?.bytes, Date.timeIntervalSinceReferenceDate)
      scheduleFlush()
    }
  }
  private func scheduleFlush() {
    if pendingCache.count + pendingDurations.count >= 128 {
      flushCache()
      return
    }
    guard pendingFlush == nil else { return }
    let job = DispatchWorkItem { [weak self] in self?.flushCache() }
    pendingFlush = job
    queue.asyncAfter(deadline: .now() + 2, execute: job)
  }
  func flushCache() {
    pendingFlush?.cancel()
    pendingFlush = nil
    guard !pendingCache.isEmpty || !pendingDurations.isEmpty else { return }
    let pending = pendingCache
    let durations = pendingDurations
    pendingCache.removeAll(keepingCapacity: true)
    pendingDurations.removeAll(keepingCapacity: true)
    do {
      try execute("BEGIN IMMEDIATE")
      var delta: Int64 = 0
      do {
        try statement("INSERT OR REPLACE INTO durations VALUES(?,?,?,?)") { s in
          for (entry, seconds) in durations {
            try check(sqlite3_reset(s))
            try bind(s, 1, entry.path)
            try check(sqlite3_bind_int64(s, 2, entry.size))
            try check(sqlite3_bind_double(s, 3, entry.modified))
            try check(sqlite3_bind_double(s, 4, seconds))
            _ = try step(s)
          }
        }
        for (key, value) in pending {
          if let bytes = value.bytes {
            let old: Int64 = try statement("SELECT bytes FROM cache WHERE key=?") { s in
              try bind(s, 1, key)
              return try step(s) ? sqlite3_column_int64(s, 0) : 0
            }
            try statement("INSERT OR REPLACE INTO cache VALUES(?,?,?)") { s in
              try bind(s, 1, key)
              try check(sqlite3_bind_int64(s, 2, Int64(bytes)))
              try check(sqlite3_bind_double(s, 3, value.time))
              _ = try step(s)
            }
            delta += Int64(bytes) - old
          } else {
            try statement("UPDATE cache SET touched=? WHERE key=?") { s in
              try check(sqlite3_bind_double(s, 1, value.time))
              try bind(s, 2, key)
              _ = try step(s)
            }
          }
        }
        try execute("COMMIT")
        cacheBytes += delta
      } catch {
        try? execute("ROLLBACK")
        throw error
      }
    } catch { report(error) }
  }
  func trimCache(limit: Int64) {
    queue.async { [self] in
      flushCache()
      guard cacheBytes > limit else { return }
      do {
        var total = cacheBytes
        let victims: [(String, Int64)] = try statement(
          "SELECT key,bytes FROM cache ORDER BY touched"
        ) { s in
          var values: [(String, Int64)] = []
          while total > limit * 9 / 10, try step(s) {
            guard let raw = sqlite3_column_text(s, 0) else { continue }
            let key = String(cString: raw)
            let bytes = sqlite3_column_int64(s, 1)
            // A corrupt database must never turn a cache key into an arbitrary file path.
            guard !key.contains("/"), !key.contains("..") else { continue }
            total -= bytes
            values.append((key, bytes))
          }
          return values
        }
        try execute("BEGIN IMMEDIATE")
        do {
          try statement("DELETE FROM cache WHERE key=?") { s in
            for (key, _) in victims {
              try check(sqlite3_reset(s))
              try bind(s, 1, key)
              _ = try step(s)
            }
          }
          try execute("COMMIT")
          cacheBytes = total
          for (key, _) in victims {
            try? FileManager.default.removeItem(
              at: base.appendingPathComponent("thumbs").appendingPathComponent(key))
          }
        } catch {
          try? execute("ROLLBACK")
          throw error
        }
      } catch { report(error) }
    }
  }
}
