import CMedia
import Foundation

final class Catalog {
  let base: URL
  let queue = DispatchQueue(label: "mzera.catalog", qos: .utility)
  private var db: OpaquePointer?
  private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
  init(base: URL? = nil) {
    self.base =
      base
      ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("local.mzera.mac")
    try? FileManager.default.createDirectory(at: self.base, withIntermediateDirectories: true)
    sqlite3_open_v2(
      self.base.appendingPathComponent("catalog.sqlite").path, &db,
      SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
    sqlite3_busy_timeout(db, 3000)
    sqlite3_exec(
      db,
      "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; CREATE TABLE IF NOT EXISTS media(root TEXT,path TEXT,size INTEGER,modified REAL,video INTEGER,PRIMARY KEY(root,path)); CREATE TABLE IF NOT EXISTS roots(path TEXT PRIMARY KEY); CREATE TABLE IF NOT EXISTS cache(key TEXT PRIMARY KEY,bytes INTEGER,touched REAL);",
      nil, nil, nil)
    // Existing catalogs predate the persisted presentation order. Duplicate-column
    // errors are harmless: an empty order key forces one fresh sort after migration.
    sqlite3_exec(
      db, "ALTER TABLE media ADD COLUMN position INTEGER NOT NULL DEFAULT 0", nil, nil, nil)
    sqlite3_exec(
      db, "ALTER TABLE roots ADD COLUMN order_key TEXT NOT NULL DEFAULT ''", nil, nil, nil)
    sqlite3_exec(
      db, "CREATE INDEX IF NOT EXISTS media_order ON media(root,position)", nil, nil, nil)
  }
  deinit { sqlite3_close(db) }
  private func bind(_ statement: OpaquePointer?, _ index: Int32, _ text: String) {
    sqlite3_bind_text(statement, index, text, -1, transient)
  }
  // Access on queue. Snapshot reads and replacements never run on the UI thread.
  func load(root: String) -> [MediaEntry]? {
    var check: OpaquePointer?
    sqlite3_prepare_v2(db, "SELECT 1 FROM roots WHERE path=?", -1, &check, nil)
    bind(check, 1, root)
    let exists = sqlite3_step(check) == SQLITE_ROW
    sqlite3_finalize(check)
    guard exists else { return nil }
    var statement: OpaquePointer?
    sqlite3_prepare_v2(
      db, "SELECT path,size,modified,video FROM media WHERE root=? ORDER BY position", -1,
      &statement, nil)
    bind(statement, 1, root)
    defer { sqlite3_finalize(statement) }
    var result: [MediaEntry] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let p = sqlite3_column_text(statement, 0) else { continue }
      result.append(
        MediaEntry(
          path: String(cString: p), size: sqlite3_column_int64(statement, 1),
          modified: sqlite3_column_double(statement, 2),
          isVideo: sqlite3_column_int(statement, 3) != 0))
    }
    return result
  }
  func orderKey(root: String) -> String? {
    var statement: OpaquePointer?
    sqlite3_prepare_v2(db, "SELECT order_key FROM roots WHERE path=?", -1, &statement, nil)
    bind(statement, 1, root)
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0)
    else { return nil }
    return String(cString: value)
  }
  func save(root: String, entries: [MediaEntry], orderKey: String = "") {
    sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil)
    var stmt: OpaquePointer?
    sqlite3_prepare_v2(db, "DELETE FROM media WHERE root=?", -1, &stmt, nil)
    bind(stmt, 1, root)
    sqlite3_step(stmt)
    sqlite3_finalize(stmt)
    sqlite3_prepare_v2(
      db, "INSERT INTO media(root,path,size,modified,video,position) VALUES(?,?,?,?,?,?)", -1,
      &stmt, nil)
    for (position, e) in entries.enumerated() {
      sqlite3_reset(stmt)
      bind(stmt, 1, root)
      bind(stmt, 2, e.path)
      sqlite3_bind_int64(stmt, 3, e.size)
      sqlite3_bind_double(stmt, 4, e.modified)
      sqlite3_bind_int(stmt, 5, e.isVideo ? 1 : 0)
      sqlite3_bind_int64(stmt, 6, Int64(position))
      sqlite3_step(stmt)
    }
    sqlite3_finalize(stmt)
    sqlite3_prepare_v2(
      db, "INSERT OR REPLACE INTO roots(path,order_key) VALUES(?,?)", -1, &stmt, nil)
    bind(stmt, 1, root)
    bind(stmt, 2, orderKey)
    sqlite3_step(stmt)
    sqlite3_finalize(stmt)
    sqlite3_exec(db, "COMMIT", nil, nil, nil)
  }
  func noteCache(key: String, bytes: Int) {
    queue.async {
      var stmt: OpaquePointer?
      sqlite3_prepare_v2(self.db, "INSERT OR REPLACE INTO cache VALUES(?,?,?)", -1, &stmt, nil)
      self.bind(stmt, 1, key)
      sqlite3_bind_int64(stmt, 2, Int64(bytes))
      sqlite3_bind_double(stmt, 3, Date.timeIntervalSinceReferenceDate)
      sqlite3_step(stmt)
      sqlite3_finalize(stmt)
    }
  }
  func touchCache(key: String) {
    queue.async {
      var stmt: OpaquePointer?
      sqlite3_prepare_v2(self.db, "UPDATE cache SET touched=? WHERE key=?", -1, &stmt, nil)
      sqlite3_bind_double(stmt, 1, Date.timeIntervalSinceReferenceDate)
      self.bind(stmt, 2, key)
      sqlite3_step(stmt)
      sqlite3_finalize(stmt)
    }
  }
  func trimCache(limit: Int64) {
    queue.async {
      var stmt: OpaquePointer?
      sqlite3_prepare_v2(self.db, "SELECT COALESCE(SUM(bytes),0) FROM cache", -1, &stmt, nil)
      sqlite3_step(stmt)
      var total = sqlite3_column_int64(stmt, 0)
      sqlite3_finalize(stmt)
      guard total > limit else { return }
      sqlite3_prepare_v2(
        self.db, "SELECT key,bytes FROM cache ORDER BY touched ASC", -1, &stmt, nil)
      var victims: [String] = []
      while total > limit * 9 / 10 && sqlite3_step(stmt) == SQLITE_ROW {
        let key = String(cString: sqlite3_column_text(stmt, 0))
        total -= sqlite3_column_int64(stmt, 1)
        victims.append(key)
      }
      sqlite3_finalize(stmt)
      sqlite3_prepare_v2(self.db, "DELETE FROM cache WHERE key=?", -1, &stmt, nil)
      for key in victims {
        try? FileManager.default.removeItem(
          at: self.base.appendingPathComponent("thumbs").appendingPathComponent(key))
        sqlite3_reset(stmt)
        self.bind(stmt, 1, key)
        sqlite3_step(stmt)
      }
      sqlite3_finalize(stmt)
    }
  }
}
