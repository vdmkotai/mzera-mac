import CMedia
import Metal
import XCTest

@testable import Mzera

final class VideoControlsTests: XCTestCase {
  private func fixture() throws -> URL {
    try XCTUnwrap(
      Bundle.module.url(forResource: "software", withExtension: "webm", subdirectory: "Fixtures"))
  }
  private func temporary() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "mzera-test-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }
  private func video(_ path: String, size: Int64 = 100) -> MediaEntry {
    MediaEntry(path: path, size: size, modified: 1, isVideo: true)
  }

  func testTimecodeFormatsElapsedTimeAndLength() {
    XCTAssertEqual(Timecode.text(0), "0:00")
    XCTAssertEqual(Timecode.text(7.9), "0:07")
    XCTAssertEqual(Timecode.text(754), "12:34")
    XCTAssertEqual(Timecode.text(3723), "1:02:03")
    XCTAssertEqual(Timecode.text(-3), "0:00")
    XCTAssertEqual(Timecode.text(.nan), "0:00")
    XCTAssertEqual(Timecode.length(0.4), "0:01")
    XCTAssertEqual(Timecode.length(59.6), "1:00")
    XCTAssertEqual(Timecode.length(0), "0:00")
  }

  func testProbeDurationMatchesDecoderAndRejectsNonVideo() throws {
    let url = try fixture()
    var error = [CChar](repeating: 0, count: 256)
    let decoder = try XCTUnwrap(mz_open(url.path, 0, 0, &error, 256))
    let expected = mz_duration(decoder)
    mz_close(decoder)
    XCTAssertGreaterThan(expected, 0)
    XCTAssertEqual(mz_probe_duration(url.path), expected, accuracy: 0.001)
    let text = try temporary().appendingPathComponent("clip.mp4")
    try Data("not a video".utf8).write(to: text)
    XCTAssertEqual(mz_probe_duration(text.path), -1)
  }

  func testCatalogDurationsMatchFileVersionAndRoot() throws {
    let base = try temporary()
    let catalog = Catalog(base: base)
    let inside = video("/media/a/clip.webm")
    let sibling = video("/media/ab/clip.webm")
    catalog.saveDuration(inside, seconds: 12.5)
    catalog.saveDuration(sibling, seconds: 3)
    catalog.queue.sync {
      catalog.flushCache()
      XCTAssertEqual(
        catalog.durations(root: "/media/a", entries: [inside, sibling]), [inside: 12.5])
      // A rewritten file gets measured again.
      let changed = video(inside.path, size: 200)
      XCTAssertEqual(catalog.durations(root: "/media/a", entries: [changed]), [:])
    }
    let reopened = Catalog(base: base)
    reopened.queue.sync {
      XCTAssertEqual(reopened.durations(root: "/media/a/", entries: [inside]), [inside: 12.5])
      // Deleting the file from the root's snapshot drops its length too.
      reopened.save(root: "/media/a", entries: [inside])
      reopened.save(root: "/media/a", entries: [])
      XCTAssertEqual(reopened.durations(root: "/media/a", entries: [inside]), [:])
    }
  }

  func testVideoThumbnailRecordsDurationForGalleryBadge() throws {
    guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
    let url = try fixture()
    let base = try temporary()
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let entry = video(url.path, size: (attributes[.size] as? Int64) ?? 0)
    for pass in 0..<2 {
      // The second pass reads the disk thumbnail and must still learn the duration.
      let catalog = Catalog(base: base.appendingPathComponent("cache-\(pass)"))
      if pass == 1 {
        try FileManager.default.copyItem(
          at: base.appendingPathComponent("cache-0/thumbs"),
          to: catalog.base.appendingPathComponent("thumbs"))
      }
      let cache = MediaCache(device: device, catalog: catalog)
      let done = expectation(description: "Thumbnail and length \(pass)")
      done.assertForOverFulfill = false
      cache.didPrepare = { _ in
        if cache.get(entry, limit: 256) != nil, cache.duration(entry) != nil { done.fulfill() }
      }
      cache.request([.init(entry: entry, limit: 256, urgent: true)])
      wait(for: [done], timeout: 10)
      XCTAssertNotNil(cache.get(entry, limit: 256))
      XCTAssertGreaterThan(try XCTUnwrap(cache.duration(entry)), 0)
      if pass == 0 {
        // Let the thumbnail writer finish before the next pass copies its output.
        let deadline = Date().addingTimeInterval(5)
        while (try? FileManager.default.contentsOfDirectory(
          atPath: catalog.base.appendingPathComponent("thumbs").path))?.contains(where: {
            $0.hasSuffix(".png")
          }) != true, Date() < deadline
        {
          RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
      }
      catalog.queue.sync {
        catalog.flushCache()
        let root = url.deletingLastPathComponent().path
        XCTAssertEqual(catalog.durations(root: root, entries: [entry]).count, 1)
      }
    }
  }

  func testPausedSeekShowsFrameAndTailSeekShowsLastFrame() throws {
    let url = try fixture()
    let playback = Playback()
    defer { playback.stop() }
    var frames: [Double] = []
    var errors: [String] = []
    var waiting: (XCTestExpectation, (Double) -> Bool)?
    playback.onVideo = { _, _, _, _, _, seconds in
      frames.append(seconds)
      if let (expectation, matches) = waiting, matches(seconds) {
        waiting = nil
        expectation.fulfill()
      }
    }
    playback.onError = { errors.append($0) }
    func expectFrame(_ label: String, _ matches: @escaping (Double) -> Bool) {
      let frame = expectation(description: label)
      waiting = (frame, matches)
      wait(for: [frame], timeout: 5)
    }
    playback.startVideo(path: url.path, withAudio: false)
    expectFrame("first frame") { _ in true }
    playback.togglePause()
    XCTAssertTrue(playback.paused)
    let duration = playback.duration
    XCTAssertGreaterThan(duration, 0)
    let middle = duration / 2
    playback.seek(to: middle)
    XCTAssertEqual(playback.position, middle)
    expectFrame("paused preview") { $0 + 0.001 >= middle }
    // Exactly one preview frame; playback stays paused.
    let count = frames.count
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    XCTAssertEqual(frames.count, count)
    playback.seek(to: duration)
    expectFrame("last frame") { $0 > middle }
    XCTAssertTrue(playback.paused)
    playback.togglePause()
    expectFrame("wrapped to start") { $0 < middle }
    XCTAssertEqual(errors, [])
    // Seeks from the previous clip must not hide frames of the next one.
    playback.startVideo(path: url.path, withAudio: false)
    expectFrame("next clip") { _ in true }
  }
}
