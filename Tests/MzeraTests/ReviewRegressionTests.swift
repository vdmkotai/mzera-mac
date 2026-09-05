import AppKit
import CMedia
import ImageIO
import Metal
import XCTest

@testable import Mzera

extension CoreTests {
  func testSequentialWebPCompositesEveryFrameAndResets() throws {
    let url = try XCTUnwrap(
      Bundle.module.url(forResource: "sequential", withExtension: "webp", subdirectory: "Fixtures"))
    let decoder = try XCTUnwrap(mz_animation_open(url.path))
    defer { mz_animation_close(decoder) }
    var data: UnsafePointer<UInt8>?
    var w: Int32 = 0
    var h: Int32 = 0
    var delay: Int32 = 0
    var count = 0
    var firstGreen: UInt8 = 0
    var lastGreen: UInt8 = 0
    while mz_animation_next(decoder, &data, &w, &h, &delay) == 1 {
      XCTAssertEqual(w, 96)
      XCTAssertEqual(h, 64)
      XCTAssertEqual(delay, 40)
      let green = try XCTUnwrap(data)[(20 * 96 + 5) * 4 + 1]
      if count == 0 { firstGreen = green }
      lastGreen = green
      count += 1
      XCTAssertLessThanOrEqual(count, 300)
    }
    XCTAssertEqual(count, 300)
    XCTAssertGreaterThan(firstGreen, lastGreen)
    mz_animation_reset(decoder)
    XCTAssertEqual(mz_animation_next(decoder, &data, &w, &h, &delay), 1)
    XCTAssertEqual(try XCTUnwrap(data)[(20 * 96 + 5) * 4 + 1], firstGreen)
  }
  func testSoftwareVideoExportsScaledPooledBuffers() throws {
    let url = try XCTUnwrap(
      Bundle.module.url(forResource: "software", withExtension: "webm", subdirectory: "Fixtures"))
    var error = [CChar](repeating: 0, count: 256)
    let decoder = try XCTUnwrap(mz_open(url.path, 0, 0, &error, 256))
    defer { mz_close(decoder) }
    mz_set_video_limit(decoder, 64)
    var frame = MZFrame()
    var frames = 0
    var surfaces = Set<UInt>()
    while mz_next(decoder, &frame) == 1 {
      let pixel = try XCTUnwrap(frame.pixel).takeUnretainedValue()
      XCTAssertEqual(CVPixelBufferGetWidth(pixel), 64)
      XCTAssertEqual(CVPixelBufferGetHeight(pixel), 36)
      surfaces.insert(UInt(bitPattern: Unmanaged.passUnretained(pixel).toOpaque()))
      frames += 1
    }
    XCTAssertEqual(frames, 15)
    XCTAssertLessThanOrEqual(surfaces.count, 3)
  }
  func testTenBitVideoDecodesToRenderableFrames() throws {
    let url = try XCTUnwrap(
      Bundle.module.url(forResource: "ten-bit", withExtension: "mp4", subdirectory: "Fixtures"))
    var error = [CChar](repeating: 0, count: 256)
    let decoder = try XCTUnwrap(mz_open(url.path, 0, 1, &error, 256))
    defer { mz_close(decoder) }
    let view = try RenderView(device: try XCTUnwrap(MTLCreateSystemDefaultDevice()))
    var frame = MZFrame()
    XCTAssertEqual(mz_next(decoder, &frame), 1)
    XCTAssertTrue(
      view.showPixel(
        try XCTUnwrap(frame.pixel).takeUnretainedValue(), fullRange: frame.full_range != 0,
        bt601: frame.bt601 != 0, bt2020: frame.bt2020 != 0))
  }
  func testFolderWatcherReportsChangedDirectory() throws {
    let root = try temporary()
    let delivered = expectation(description: "file event")
    var fulfilled = false
    let watcher = FolderWatcher(path: root.path) { changes in
      if !fulfilled
        && (changes == nil
          || changes!.contains(where: { $0.path == root.path || $0.path.hasPrefix(root.path + "/") }
          ))
      {
        fulfilled = true
        delivered.fulfill()
      }
    }
    try Data([1]).write(to: root.appendingPathComponent("new.jpg"))
    wait(for: [delivered], timeout: 8)
    withExtendedLifetime(watcher) {}
  }
  func testNaturalOrderHandlesLongNumbersCaseAndLeadingZeros() {
    let names = ["10000000000000000000000.jpg", "20.jpg", "2.jpg", "02.jpg", "A10.jpg", "a2.jpg"]
    let result = SortOrder.name.sorted(names.map { entry("/a/" + $0) }, grouped: false).map(\.name)
    XCTAssertEqual(
      result, ["02.jpg", "2.jpg", "20.jpg", "10000000000000000000000.jpg", "a2.jpg", "A10.jpg"])
    XCTAssertEqual(NaturalKey("É2"), NaturalKey("e\u{301}2"))
  }
  func testUnchangedSnapshotIgnoresEnumerationOrderButDetectsChanges() {
    let a = [entry("/a/1.jpg"), entry("/a/2.jpg")]
    XCTAssertTrue(Scanner.sameContents(a, a.reversed()))
    XCTAssertFalse(Scanner.sameContents(a, [a[0]]))
    XCTAssertFalse(Scanner.sameContents(a, [a[0], entry("/a/2.jpg", date: 2)]))
  }
  func testNonrecursiveRescanDoesNotIncludeDescendantsAndIgnoresAppleDouble() throws {
    let root = try temporary()
    let nested = root.appendingPathComponent("nested")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    for path in [
      root.appendingPathComponent("photo.jfif"), root.appendingPathComponent("._photo.jpg"),
      nested.appendingPathComponent("photo.jpg"),
    ] {
      try Data([1]).write(to: path)
    }
    var entries: [MediaEntry] = []
    _ = Scanner.scan(root: root, cancellation: Cancellation(), recursive: false) { entries += $0 }
    XCTAssertEqual(entries.map(\.name), ["photo.jfif"])
  }
  func testCatalogRollbackPreservesPreviousSnapshotAfterInsertFailure() throws {
    let root = try temporary()
    let catalog = Catalog(base: root)
    catalog.queue.sync {
      XCTAssertTrue(catalog.save(root: "/a", entries: [entry("/a/good.jpg")], orderKey: "before"))
    }
    var db: OpaquePointer?
    XCTAssertEqual(sqlite3_open(root.appendingPathComponent("catalog.sqlite").path, &db), SQLITE_OK)
    defer { sqlite3_close(db) }
    XCTAssertEqual(
      sqlite3_exec(
        db,
        "CREATE TRIGGER fail_insert BEFORE INSERT ON media WHEN NEW.path='/a/bad.jpg' BEGIN SELECT RAISE(ABORT,'injected failure'); END",
        nil, nil, nil), SQLITE_OK)
    catalog.queue.sync {
      XCTAssertFalse(catalog.save(root: "/a", entries: [entry("/a/bad.jpg")], orderKey: "after"))
      XCTAssertEqual(catalog.load(root: "/a"), [entry("/a/good.jpg")])
      XCTAssertEqual(catalog.orderKey(root: "/a"), "before")
    }
  }
  func testCatalogDoesNotRewriteUnchangedRows() throws {
    let catalog = Catalog(base: try temporary())
    let entries = [entry("/a/1.jpg"), entry("/a/2.jpg")]
    catalog.queue.sync {
      XCTAssertTrue(catalog.save(root: "/a", entries: entries))
      XCTAssertEqual(catalog.lastSaveChangedRows, 2)
      XCTAssertTrue(catalog.save(root: "/a", entries: entries))
      XCTAssertEqual(catalog.lastSaveChangedRows, 0)
      XCTAssertTrue(catalog.save(root: "/a", entries: [entries[0], entry("/a/2.jpg", date: 2)]))
      XCTAssertEqual(catalog.lastSaveChangedRows, 1)
    }
  }
  func testCorruptCatalogFailsGracefully() throws {
    let root = try temporary()
    try Data("this is not sqlite".utf8).write(to: root.appendingPathComponent("catalog.sqlite"))
    let catalog = Catalog(base: root)
    catalog.queue.sync {
      XCTAssertNil(catalog.load(root: "/a"))
      XCTAssertFalse(catalog.save(root: "/a", entries: []))
      XCTAssertNotNil(catalog.lastError)
    }
  }
  func testLRUEvictionOrderSurvivesTouchReplacementAndPressure() {
    let cache = ByteLRU<Int, Int>(limit: 1000)
    for i in 0..<1000 { cache.put(i, i, cost: 1) }
    XCTAssertEqual(cache.get(0), 0)
    cache.put(1000, 1000, cost: 1)
    XCTAssertNil(cache.peek(1))
    cache.put(0, 2, cost: 2)
    XCTAssertEqual(cache.get(0), 2)
    cache.limit = 2
    XCTAssertEqual(cache.count, 1)
    XCTAssertEqual(cache.cost, 2)
    cache.limit = 0
    XCTAssertEqual(cache.count, 0)
  }
  func testBufferTextureAlignmentAndTransparency() throws {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let context = try XCTUnwrap(
      CGContext(
        data: nil, width: 13, height: 7, bitsPerComponent: 8, bytesPerRow: 52,
        space: ImageDecoder.colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 0.5))
    context.fill(CGRect(x: 0, y: 0, width: 13, height: 7))
    let prepared = try XCTUnwrap(
      ImageDecoder.prepare(try XCTUnwrap(context.makeImage()), device: device))
    let buffer = try XCTUnwrap(prepared.texture.buffer)
    XCTAssertEqual(prepared.cost, buffer.length)
    XCTAssertEqual(
      prepared.texture.bufferBytesPerRow % device.minimumLinearTextureAlignment(for: .bgra8Unorm), 0
    )
    var pixel = [UInt8](repeating: 0, count: 4)
    prepared.texture.getBytes(
      &pixel, bytesPerRow: 4, from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
    XCTAssertEqual(pixel[0], 0)
    XCTAssertEqual(Int(pixel[2]), 128, accuracy: 1)
    XCTAssertEqual(Int(pixel[3]), 128, accuracy: 1)
  }
  func testMemoryPressureRestoresConfiguredBudget() throws {
    let cache = MediaCache(
      device: try XCTUnwrap(MTLCreateSystemDefaultDevice()), catalog: Catalog(base: try temporary())
    )
    cache.setPhotoBudget(512 * 1024 * 1024)
    cache.setMemoryPressure(true)
    XCTAssertEqual(cache.photos.limit, 128 * 1024 * 1024)
    cache.setMemoryPressure(false)
    XCTAssertEqual(cache.photos.limit, 512 * 1024 * 1024)
    XCTAssertEqual(cache.thumbnails.limit, 384 * 1024 * 1024)
  }
  func testFullSizePhotoIsReusedAcrossDisplayLimits() throws {
    let root = try temporary()
    let path = root.appendingPathComponent("small.png")
    try writeImage(path)
    let cache = MediaCache(
      device: try XCTUnwrap(MTLCreateSystemDefaultDevice()),
      catalog: Catalog(base: root.appendingPathComponent("cache")))
    let e = entry(path.path)
    let ready = expectation(description: "prepared")
    cache.didPrepare = { _ in ready.fulfill() }
    cache.request([.init(entry: e, limit: 2560, urgent: true)])
    wait(for: [ready], timeout: 3)
    let small = try XCTUnwrap(cache.get(e, limit: 2560))
    let large = try XCTUnwrap(cache.get(e, limit: 8192))
    XCTAssertTrue(small.texture === large.texture)
    XCTAssertEqual(cache.photos.count, 1)
  }
  func testP010PixelBufferIsAcceptedByRenderer() throws {
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let view = try RenderView(device: device)
    var pixel: CVPixelBuffer?
    let attrs: [CFString: Any] = [
      kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferIOSurfacePropertiesKey: [:],
    ]
    XCTAssertEqual(
      CVPixelBufferCreate(
        nil, 64, 32, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, attrs as CFDictionary, &pixel
      ), kCVReturnSuccess)
    XCTAssertTrue(view.showPixel(try XCTUnwrap(pixel), fullRange: false, bt601: false))
    XCTAssertEqual(view.video?.y.pixelFormat, .r16Unorm)
    XCTAssertEqual(view.video?.uv?.pixelFormat, .rg16Unorm)
    XCTAssertEqual(view.video?.tenBit, true)
  }
  func testZoomKeepsPointUnderCursorAndPanWithinImage() {
    let viewport = CGSize(width: 800, height: 600)
    let anchor = CGPoint(x: 500, y: 350)
    let pan = ViewGeometry.zoomedPan(
      .zero, anchor: anchor, viewport: viewport, oldScale: 1, newScale: 2)
    XCTAssertEqual(pan, CGPoint(x: -100, y: -50))
    let clamped = ViewGeometry.clampedPan(
      CGPoint(x: 100000, y: -100000), image: CGSize(width: 1000, height: 800), viewport: viewport,
      scale: 1)
    XCTAssertEqual(clamped, CGPoint(x: 100, y: -100))
    XCTAssertEqual(
      ViewGeometry.clampedPan(
        pan, image: CGSize(width: 100, height: 100), viewport: viewport, scale: 1), .zero)
  }
}
