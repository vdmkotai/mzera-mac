import AppKit
import CMedia
import CoreGraphics
import ImageIO
import Metal
import XCTest

@testable import Mzera

final class CoreTests: XCTestCase {
  func testFolderDropAcceptsOneDirectoryAndRejectsFilesAndMultipleRoots() throws {
    let root = try temporary()
    let file = root.appendingPathComponent("image.png")
    try writeImage(file)
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    board.writeObjects([root as NSURL])
    XCTAssertEqual(FolderDropView.folder(from: board), root.standardizedFileURL)
    board.clearContents()
    board.writeObjects([file as NSURL])
    XCTAssertNil(FolderDropView.folder(from: board))
    board.clearContents()
    board.writeObjects([root as NSURL, root.appendingPathComponent("missing") as NSURL])
    XCTAssertNil(FolderDropView.folder(from: board))
  }
  func testFolderDropRejectsTextRemoteURLAndVanishedDirectory() throws {
    let root = try temporary().appendingPathComponent("vanished")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    board.setString(root.path, forType: .string)
    XCTAssertNil(FolderDropView.folder(from: board))
    board.clearContents()
    board.writeObjects([URL(string: "https://example.com/folder")! as NSURL])
    XCTAssertNil(FolderDropView.folder(from: board))
    board.clearContents()
    board.writeObjects([root as NSURL])
    try FileManager.default.removeItem(at: root)
    XCTAssertNil(FolderDropView.folder(from: board))
  }
  func testOversizedResultDoesNotDecodeForever() throws {
    guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
    let root = try temporary()
    let image = root.appendingPathComponent("large.png")
    try writeImage(image)
    let cache = MediaCache(
      device: device, catalog: Catalog(base: root.appendingPathComponent("cache")))
    cache.thumbnails.limit = 1
    let e = entry(image.path)
    let done = expectation(description: "Rejected once")
    done.assertForOverFulfill = true
    cache.didPrepare = { _ in done.fulfill() }
    cache.request([.init(entry: e, limit: 512, urgent: true)])
    wait(for: [done], timeout: 3)
    XCTAssertTrue(cache.isFailed(e, limit: 512))
    XCTAssertNil(cache.get(e, limit: 512))
    XCTAssertEqual(cache.queuedCount, 0)
  }
  func entry(_ path: String, size: Int64 = 100, date: Double = 1) -> MediaEntry {
    MediaEntry(path: path, size: size, modified: date, isVideo: false)
  }
  func temporary() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "mzera-test-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }
  func writeImage(_ url: URL) throws {
    let ctx = CGContext(
      data: nil, width: 128, height: 64, bitsPerComponent: 8, bytesPerRow: 512,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 128, height: 64))
    let image = ctx.makeImage()!
    let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    XCTAssertTrue(CGImageDestinationFinalize(dest))
  }
  func testMetalPipelineCompiles() throws {
    guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
    XCTAssertNoThrow(try RenderView(device: device))
  }
  func testViewportStaysBoundedAtHundredThousandEntries() {
    let entries = (0..<100_000).map { entry("/root/\($0).jpg") }
    var grid = GridLayout()
    grid.rebuild(entries: entries, width: 1000, tile: 160, grouped: false)
    for y in [0.0, 10000, grid.height / 2, grid.height - 750] {
      let visible = grid.visible(offset: y, height: 750)
      XCTAssertLessThanOrEqual(visible.count, 36)
      XCTAssertTrue(
        visible.allSatisfy { grid.rect(at: $0).maxY > y && grid.rect(at: $0).minY < y + 750 })
    }
    XCTAssertTrue(grid.visible(offset: grid.height + 100, height: 750).isEmpty)
  }
  func testGroupHeadersAndGapsAreNotSelectable() {
    let entries = [entry("/a/1.png"), entry("/a/2.png"), entry("/b/1.png")]
    var grid = GridLayout()
    grid.rebuild(entries: entries, width: 500, tile: 100, grouped: true)
    XCTAssertNil(grid.hit(x: 20, y: 15))
    XCTAssertEqual(grid.hit(x: 30, y: 60), 0)
    XCTAssertNil(grid.hit(x: 110, y: 60))
    let last = grid.rect(at: 2)
    XCTAssertEqual(grid.hit(x: last.midX, y: last.midY), 2)
    XCTAssertEqual(grid.sections.count, 2)
  }
  func testNaturalSortingAndStableTies() {
    let entries = [entry("/b/10.jpg"), entry("/a/2.jpg"), entry("/b/2.jpg")]
    XCTAssertEqual(
      SortOrder.path.sorted(entries, grouped: false).map(\.path),
      ["/a/2.jpg", "/b/2.jpg", "/b/10.jpg"])
    XCTAssertEqual(
      SortOrder.name.sorted(entries, grouped: false).map(\.path),
      ["/a/2.jpg", "/b/2.jpg", "/b/10.jpg"])
    let sizes = [
      entry("/a/a.jpg", size: 1), entry("/b/a.jpg", size: 3), entry("/a/b.jpg", size: 2),
    ]
    XCTAssertEqual(
      SortOrder.largest.sorted(sizes, grouped: true).map(\.path),
      ["/a/b.jpg", "/a/a.jpg", "/b/a.jpg"])
  }
  func testLRUEnforcesBytesAndProtectsRecentAccess() {
    let cache = ByteLRU<String, Int>(limit: 10)
    cache.put("a", 1, cost: 4)
    cache.put("b", 2, cost: 4)
    XCTAssertEqual(cache.get("a"), 1)
    cache.put("c", 3, cost: 4)
    XCTAssertNil(cache.get("b"))
    XCTAssertEqual(cache.cost, 8)
    cache.put("huge", 9, cost: 100)
    XCTAssertNil(cache.get("huge"))
    XCTAssertEqual(cache.cost, 8)
    cache.limit = 3
    XCTAssertEqual(cache.cost, 0)
  }
  func testScannerRecursesOneHundredLevelsWithoutFollowingSymlinkLoop() throws {
    let root = try temporary()
    var leaf = root
    for _ in 0..<100 { leaf.appendPathComponent("d") }
    try FileManager.default.createDirectory(at: leaf, withIntermediateDirectories: true)
    try Data([0]).write(to: leaf.appendingPathComponent("image.PNG"))
    try Data([0]).write(to: root.appendingPathComponent("clip.webm"))
    try Data([0]).write(to: root.appendingPathComponent("ignore.txt"))
    try FileManager.default.createSymbolicLink(
      at: leaf.appendingPathComponent("loop"), withDestinationURL: root)
    var entries: [MediaEntry] = []
    let result = Scanner.scan(root: root, cancellation: Cancellation()) {
      entries.append(contentsOf: $0)
    }
    XCTAssertEqual(result.count, 2)
    XCTAssertEqual(result.errors, 0)
    XCTAssertEqual(entries.filter(\.isVideo).count, 1)
  }
  func testCancelledScanProducesNoEntries() throws {
    let root = try temporary()
    try Data([0]).write(to: root.appendingPathComponent("image.jpg"))
    let token = Cancellation()
    token.cancel()
    let result = Scanner.scan(root: root, cancellation: token) { _ in
      XCTFail("Cancelled scan emitted results")
    }
    XCTAssertEqual(result.count, 0)
  }
  func testScannerIncludesMediaInsideApplicationPackages() throws {
    let root = try temporary()
    let assets = root.appendingPathComponent("Game.app/Contents/Resources")
    try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
    try Data([0]).write(to: assets.appendingPathComponent("asset.webp"))
    let result = Scanner.scan(root: root, cancellation: Cancellation()) { _ in }
    XCTAssertEqual(result.count, 1)
  }
  func testCancelledFramePermitNeverLeaksOrAddsSlots() {
    let gate = DispatchSemaphore(value: 1)
    let token = Cancellation()
    var permit = FramePermit(gate: gate, token: token)
    XCTAssertNotNil(permit)
    token.cancel()
    permit = nil
    XCTAssertNil(FramePermit(gate: gate, token: token))
    XCTAssertEqual(gate.wait(timeout: .now()), .success)
    XCTAssertEqual(gate.wait(timeout: .now()), .timedOut)
    gate.signal()
  }
  func testRapidAnimationCancellation() throws {
    guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
    let root = try temporary()
    let png = root.appendingPathComponent("red.png")
    let gif = root.appendingPathComponent("animation.gif")
    try writeImage(png)
    let image = try XCTUnwrap(ImageDecoder.image(path: png.path, limit: 64)?.0)
    let dest = try XCTUnwrap(
      CGImageDestinationCreateWithURL(gif as CFURL, "com.compuserve.gif" as CFString, 2, nil))
    for _ in 0..<2 {
      CGImageDestinationAddImage(
        dest, image,
        [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.01]] as CFDictionary)
    }
    XCTAssertTrue(CGImageDestinationFinalize(dest))
    let playback = Playback()
    let done = expectation(description: "Cancelled playback drains")
    var received = 0
    playback.onImage = { _ in
      received += 1
      if received == 1 {
        playback.togglePause()
        playback.stop()
        playback.startAnimation(path: gif.path, limit: 64, device: device)
        return
      }
      playback.stop()
      done.fulfill()
    }
    for _ in 0..<30 {
      playback.startAnimation(path: gif.path, limit: 64, device: device)
      playback.stop()
    }
    playback.startAnimation(path: gif.path, limit: 64, device: device)
    wait(for: [done], timeout: 3)
    XCTAssertEqual(received, 2)
  }
  func testCatalogReplacementRemovesDeletedFilesAndKeepsOtherRoots() throws {
    let base = try temporary()
    let catalog = Catalog(base: base)
    catalog.queue.sync {
      XCTAssertNil(catalog.load(root: "/a"))
      catalog.save(root: "/a", entries: [entry("/a/1.jpg"), entry("/a/2.jpg")])
      catalog.save(root: "/b", entries: [entry("/b/1.jpg")])
      catalog.save(root: "/a", entries: [entry("/a/2.jpg", size: 200)])
      XCTAssertEqual(catalog.load(root: "/a"), [entry("/a/2.jpg", size: 200)])
      XCTAssertEqual(catalog.load(root: "/b")?.count, 1)
      catalog.save(root: "/a", entries: [])
      XCTAssertEqual(catalog.load(root: "/a"), [])
    }
  }
  func testDecoderRejectsDisguisedNonImage() throws {
    let path = try temporary().appendingPathComponent("archive.jpg")
    try Data("PK\u{03}\u{04}not a picture".utf8).write(to: path)
    XCTAssertNil(ImageDecoder.image(path: path.path, limit: 512))
  }
  func testCatalogPreservesPresentationOrderAcrossReopen() throws {
    let base = try temporary()
    let ordered = [entry("/a/z.jpg"), entry("/a/2.jpg"), entry("/a/10.jpg")]
    do {
      let catalog = Catalog(base: base)
      _ = catalog.queue.sync { catalog.save(root: "/a", entries: ordered, orderKey: "2|1") }
    }
    let reopened = Catalog(base: base)
    reopened.queue.sync {
      XCTAssertEqual(reopened.load(root: "/a"), ordered)
      XCTAssertEqual(reopened.orderKey(root: "/a"), "2|1")
    }
  }
  func testLegacyCatalogMigratesWithoutLosingEntries() throws {
    let base = try temporary()
    var db: OpaquePointer?
    XCTAssertEqual(sqlite3_open(base.appendingPathComponent("catalog.sqlite").path, &db), SQLITE_OK)
    XCTAssertEqual(
      sqlite3_exec(
        db,
        "CREATE TABLE media(root TEXT,path TEXT,size INTEGER,modified REAL,video INTEGER,PRIMARY KEY(root,path)); CREATE TABLE roots(path TEXT PRIMARY KEY); INSERT INTO roots VALUES('/a'); INSERT INTO media VALUES('/a','/a/old.jpg',1,0,0);",
        nil, nil, nil), SQLITE_OK)
    sqlite3_close(db)
    let catalog = Catalog(base: base)
    catalog.queue.sync {
      XCTAssertEqual(catalog.load(root: "/a")?.first?.path, "/a/old.jpg")
      XCTAssertEqual(catalog.orderKey(root: "/a"), "")
      catalog.save(root: "/a", entries: [entry("/a/new.jpg")], orderKey: "0|0")
      XCTAssertEqual(catalog.orderKey(root: "/a"), "0|0")
      XCTAssertEqual(catalog.load(root: "/a")?.first?.path, "/a/new.jpg")
    }
  }
  func testPreparedTextureContainsDecodedPixels() throws {
    guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
    let path = try temporary().appendingPathComponent("red.png")
    try writeImage(path)
    let decoded = try XCTUnwrap(ImageDecoder.image(path: path.path, limit: 64))
    let prepared = try XCTUnwrap(ImageDecoder.prepare(decoded.0, device: device))
    XCTAssertEqual(prepared.width, 64)
    XCTAssertEqual(prepared.height, 32)
    var pixels = [UInt8](repeating: 0, count: prepared.cost)
    prepared.texture.getBytes(
      &pixels, bytesPerRow: prepared.width * 4,
      from: MTLRegionMake2D(0, 0, prepared.width, prepared.height), mipmapLevel: 0)
    XCTAssertGreaterThan(pixels[2], 250)
    XCTAssertLessThan(pixels[0], 5)
    XCTAssertEqual(pixels[3], 255)
  }
  func testCacheKeyInvalidatesAfterSourceChange() {
    let a = entry("/a.png", size: 1, date: 1)
    let b = entry("/a.png", size: 1, date: 2)
    XCTAssertNotEqual(MediaCache.key(a, limit: 512), MediaCache.key(b, limit: 512))
    XCTAssertNotEqual(MediaCache.key(a, limit: 512), MediaCache.key(a, limit: 2560))
  }
  func testReplacingDesiredRequestsDiscardsStaleCompletions() throws {
    guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
    let root = try temporary()
    let a = root.appendingPathComponent("a.png")
    let b = root.appendingPathComponent("b.png")
    try writeImage(a)
    try writeImage(b)
    let cache = MediaCache(
      device: device, catalog: Catalog(base: root.appendingPathComponent("cache")))
    let old = entry(a.path)
    let current = entry(b.path)
    let done = expectation(description: "Current image prepared")
    cache.didPrepare = { path in
      XCTAssertEqual(path, b.path)
      done.fulfill()
    }
    cache.request([.init(entry: old, limit: 512, urgent: true)])
    cache.request([.init(entry: current, limit: 512, urgent: true)])
    wait(for: [done], timeout: 5)
    XCTAssertNotNil(cache.get(current, limit: 512))
    XCTAssertNil(cache.get(old, limit: 512))
    XCTAssertLessThanOrEqual(cache.peakJobs, 4)
    cache.catalog.queue.sync {}
  }
}
