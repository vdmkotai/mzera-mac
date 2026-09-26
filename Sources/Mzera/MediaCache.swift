import CMedia
import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import ImageIO
import Metal

struct PreparedImage {
  let texture: MTLTexture
  let width: Int
  let height: Int
  let animated: Bool
  var sourceMax: Int = 0
  var cost: Int { texture.buffer?.length ?? width * height * 4 }
}

enum ImageDecoder {
  static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
  static func image(path: String, limit: Int, index: Int = 0) -> (CGImage, Bool, Int)? {
    guard
      let source = CGImageSourceCreateWithURL(
        URL(fileURLWithPath: path) as CFURL,
        [kCGImageSourceShouldCache: false] as CFDictionary),
      let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
    else { return nil }
    let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.int64Value ?? 0
    let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.int64Value ?? 0
    guard w > 0, h > 0, w <= 100000, h <= 100000, w * h <= 100_000_000 else { return nil }
    guard
      let image = CGImageSourceCreateThumbnailAtIndex(
        source, index,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceShouldCacheImmediately: true, kCGImageSourceThumbnailMaxPixelSize: limit,
        ] as CFDictionary)
    else { return nil }
    return (image, CGImageSourceGetCount(source) > 1, Int(max(w, h)))
  }
  static func prepare(
    _ image: CGImage, animated: Bool = false, sourceMax: Int = 0, device: MTLDevice
  ) -> PreparedImage? {
    let w = image.width
    let h = image.height
    let alignment = device.minimumLinearTextureAlignment(for: .bgra8Unorm)
    let row = ((w * 4 + alignment - 1) / alignment) * alignment
    guard w > 0, h > 0, w <= 16384, h <= 16384, w * h <= 100_000_000,
      let storage = device.makeBuffer(length: row * h, options: .storageModeShared),
      let context = CGContext(
        data: storage.contents(), width: w, height: h, bitsPerComponent: 8, bytesPerRow: row,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
          | CGBitmapInfo.byteOrder32Little.rawValue)
    else { return nil }
    // Replace every pixel, including transparent ones, without a separate clear pass.
    context.setBlendMode(.copy)
    context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
    descriptor.storageMode = .shared
    descriptor.usage = .shaderRead
    guard let texture = storage.makeTexture(descriptor: descriptor, offset: 0, bytesPerRow: row)
    else {
      return nil
    }
    return PreparedImage(
      texture: texture, width: w, height: h, animated: animated, sourceMax: sourceMax)
  }
  static func videoThumbnail(
    path: String, limit: Int, device: MTLDevice, duration: inout Double?
  ) -> PreparedImage? {
    var error = [CChar](repeating: 0, count: 256)
    guard let decoder = mz_open(path, 0, 0, &error, 256) else { return nil }
    defer { mz_close(decoder) }
    duration = mz_duration(decoder)
    mz_set_video_limit(decoder, Int32(limit))
    var frame = MZFrame()
    guard mz_next(decoder, &frame) == 1, let raw = frame.pixel else { return nil }
    let pixel = raw.takeUnretainedValue()
    CVPixelBufferLockBaseAddress(pixel, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
    guard let data = CVPixelBufferGetBaseAddress(pixel) else { return nil }
    let w = CVPixelBufferGetWidth(pixel)
    let h = CVPixelBufferGetHeight(pixel)
    guard
      let ctx = CGContext(
        data: data, width: w, height: h, bitsPerComponent: 8,
        bytesPerRow: CVPixelBufferGetBytesPerRow(pixel),
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
          | CGBitmapInfo.byteOrder32Little.rawValue), let original = ctx.makeImage()
    else { return nil }
    return prepare(original, device: device)
  }

  static func bitmap(_ image: PreparedImage) -> CGImage? {
    guard
      let context = CGContext(
        data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
        bytesPerRow: image.width * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
          | CGBitmapInfo.byteOrder32Little.rawValue), let data = context.data
    else { return nil }
    image.texture.getBytes(
      data, bytesPerRow: image.width * 4, from: MTLRegionMake2D(0, 0, image.width, image.height),
      mipmapLevel: 0)
    return context.makeImage()
  }
}

// Mutable cache state belongs to the main thread. Bounded workers prepare immutable
// images; desired requests replace the old waiting set rather than append to it.
final class MediaCache {
  struct Key: Hashable {
    let entry: MediaEntry
    let limit: Int
    var diskText: String { "v2|\(entry.path)|\(entry.size)|\(entry.modified)|\(limit)" }
  }
  enum Failure { case decode, budget }
  struct Request {
    let entry: MediaEntry
    let limit: Int
    let urgent: Bool
    var key: Key { Key(entry: entry, limit: limit) }
  }
  let device: MTLDevice
  let catalog: Catalog
  let thumbnails = ByteLRU<Key, PreparedImage>(limit: 384 * 1024 * 1024)
  let photos = ByteLRU<Key, PreparedImage>(limit: 1024 * 1024 * 1024)
  private let workers = DispatchQueue(
    label: "mzera.decode", qos: .userInitiated, attributes: .concurrent)
  private let videos = DispatchQueue(
    label: "mzera.video-thumbnails", qos: .utility, attributes: .concurrent)
  private let diskWriter = DispatchQueue(label: "mzera.thumbnail-writer", qos: .utility)
  private let diskSlots = DispatchSemaphore(value: 8)
  private var wanted: [Request] = []
  private var wantedKeys: Set<Key> = []
  private var active: Set<Key> = []
  private var failures: [Key: Failure] = [:]
  private var fullSizePhotos: [MediaEntry: Key] = [:]
  /// Container durations of videos, filled by thumbnail jobs and the persistent catalog.
  /// Zero marks a length that could not be read, so it is not probed again.
  private var durations: [MediaEntry: Double] = [:]
  private var probing: Set<MediaEntry> = []
  private let probes = DispatchQueue(label: "mzera.duration-probe", qos: .utility)
  private var configuredPhotoBudget = 1024 * 1024 * 1024
  private var underPressure = false
  private var inFlightBytes = 0
  private let diskLimit: Int64
  private var imageJobs = 0, videoJobs = 0, writes = 0
  private(set) var queuedCount = 0
  private(set) var peakJobs = 0
  private var pressure: DispatchSourceMemoryPressure?
  var didPrepare: ((String) -> Void)?
  init(device: MTLDevice, catalog: Catalog) {
    self.device = device
    self.catalog = catalog
    diskLimit =
      Int64(
        UserDefaults.standard.integer(forKey: "diskCacheGiB").clamped(to: 1...100, fallback: 30))
      * 1024 * 1024 * 1024
    try? FileManager.default.createDirectory(
      at: catalog.base.appendingPathComponent("thumbs"), withIntermediateDirectories: true)
    pressure = DispatchSource.makeMemoryPressureSource(
      eventMask: [.normal, .warning, .critical], queue: .main)
    pressure?.setEventHandler { [weak self] in
      guard let self else { return }
      self.setMemoryPressure(self.pressure?.data.contains(.normal) != true)
    }
    pressure?.resume()
    catalog.trimCache(limit: diskLimit)
  }
  func setPhotoBudget(_ bytes: Int) {
    configuredPhotoBudget = bytes
    photos.limit = underPressure ? min(bytes, 128 * 1024 * 1024) : bytes
    failures = failures.filter { $0.value != .budget }
  }
  func setMemoryPressure(_ pressured: Bool) {
    underPressure = pressured
    thumbnails.limit = pressured ? 64 * 1024 * 1024 : 384 * 1024 * 1024
    setPhotoBudget(configuredPhotoBudget)
    if pressured { request(Array(wanted.filter(\.urgent).prefix(1))) } else { pump() }
  }
  static func key(_ entry: MediaEntry, limit: Int) -> Key {
    Key(entry: entry, limit: limit)
  }
  func get(_ e: MediaEntry, limit: Int) -> PreparedImage? {
    if limit > 512, let key = fullSizePhotos[e], let image = photos.get(key) { return image }
    return (limit <= 512 ? thumbnails : photos).get(Self.key(e, limit: limit))
  }
  func isFailed(_ e: MediaEntry, limit: Int) -> Bool {
    failures[Self.key(e, limit: limit)] != nil
  }
  func failure(_ e: MediaEntry, limit: Int) -> Failure? { failures[Self.key(e, limit: limit)] }
  func peek(_ e: MediaEntry, limit: Int) -> PreparedImage? {
    (limit <= 512 ? thumbnails : photos).peek(Self.key(e, limit: limit))
  }
  func duration(_ e: MediaEntry) -> Double? { durations[e].flatMap { $0 > 0 ? $0 : nil } }
  func installDurations(_ known: [MediaEntry: Double]) {
    durations.merge(known) { current, _ in current }
  }
  func request(_ requests: [Request]) {
    var seen = Set<Key>()
    wanted = requests.filter { seen.insert($0.key).inserted }
    wantedKeys = seen
    pump()
  }
  func clear() {
    wanted = []
    wantedKeys.removeAll()
    fullSizePhotos.removeAll()
    durations.removeAll()
    probing.removeAll()
    thumbnails.clear()
    photos.clear()
    failures.removeAll()
  }
  var stats: String {
    "RAM \((thumbnails.cost+photos.cost)/1_048_576) MB · decode \(imageJobs+videoJobs) · queue \(queuedCount)"
  }
  private func pump() {
    var remaining: [Request] = []
    for request in wanted {
      let key = Self.key(request.entry, limit: request.limit)
      if active.contains(key) || failures[key] != nil
        || get(request.entry, limit: request.limit) != nil
      {
        continue
      }
      let concurrency =
        underPressure
        ? 1
        : (request.limit <= 512
          ? min(8, max(2, ProcessInfo.processInfo.activeProcessorCount - 2)) : 2)
      let reserved = min(
        request.limit * request.limit * 4, (request.limit <= 512 ? thumbnails : photos).limit)
      if request.entry.isVideo
        ? videoJobs >= (underPressure ? 1 : 2)
        : (imageJobs >= (request.urgent ? concurrency : max(1, concurrency - 1))
          || (imageJobs > 0 && inFlightBytes + reserved > 512 * 1024 * 1024))
      {
        remaining.append(request)
        continue
      }
      active.insert(key)
      inFlightBytes += reserved
      if request.entry.isVideo { videoJobs += 1 } else { imageJobs += 1 }
      peakJobs = max(peakJobs, imageJobs + videoJobs)
      let queue = request.entry.isVideo ? videos : workers
      let needsDuration = request.entry.isVideo && durations[request.entry] == nil
      queue.async { [weak self] in
        guard let self else { return }
        var duration: Double?
        let result: PreparedImage? = autoreleasepool {
          let diskKey =
            SHA256.hash(data: Data(key.diskText.utf8)).map { String(format: "%02x", $0) }.joined()
            + ".png"
          let cacheURL = self.catalog.base.appendingPathComponent("thumbs").appendingPathComponent(
            diskKey)
          if request.limit <= 512,
            let (image, _, _) = ImageDecoder.image(path: cacheURL.path, limit: request.limit)
          {
            self.catalog.touchCache(key: diskKey)
            return ImageDecoder.prepare(image, device: self.device)
          }
          if request.entry.isVideo {
            let prepared = ImageDecoder.videoThumbnail(
              path: request.entry.path, limit: request.limit, device: self.device,
              duration: &duration)
            if let prepared, let image = ImageDecoder.bitmap(prepared) {
              self.persist(image, to: cacheURL, key: diskKey)
            }
            return prepared
          }
          guard
            let (image, animated, sourceMax) = ImageDecoder.image(
              path: request.entry.path, limit: request.limit)
          else { return nil }
          let prepared = ImageDecoder.prepare(
            image, animated: animated, sourceMax: sourceMax, device: self.device)
          if request.limit <= 512, prepared != nil {
            self.persist(image, to: cacheURL, key: diskKey)
          }
          return prepared
        }
        DispatchQueue.main.async { [duration] in
          if needsDuration {
            // A thumbnail from the disk cache is shown first; its length is read afterwards.
            if let duration { self.record(duration, for: request.entry) } else {
              self.probeDuration(request.entry)
            }
          }
          self.active.remove(key)
          self.inFlightBytes -= reserved
          if request.entry.isVideo { self.videoJobs -= 1 } else { self.imageJobs -= 1 }
          // A completed old request is harmless, but never enters the cache unless still wanted.
          if self.wantedKeys.contains(key) {
            let destination = request.limit <= 512 ? self.thumbnails : self.photos
            if let result, result.cost <= destination.limit {
              destination.put(key, result, cost: result.cost)
              if request.limit > 512 && result.sourceMax > 0
                && max(result.width, result.height) >= result.sourceMax
              {
                if self.fullSizePhotos.count >= 4096 { self.fullSizePhotos.removeAll() }
                self.fullSizePhotos[request.entry] = key
              }
            } else {
              if self.failures.count >= 4096 { self.failures.removeAll(keepingCapacity: true) }
              self.failures[key] = result == nil ? .decode : .budget
            }
            self.didPrepare?(request.entry.path)
          }
          self.writes += 1
          if self.writes % 100 == 0 { self.catalog.trimCache(limit: self.diskLimit) }
          self.pump()
        }
      }
    }
    // Keep the desired set (including active jobs) for generation checks on completion.
    queuedCount = remaining.count
  }
  private func record(_ seconds: Double, for entry: MediaEntry) {
    guard durations[entry] == nil else { return }
    let value = seconds.isFinite && seconds > 0 ? seconds : 0
    durations[entry] = value
    catalog.saveDuration(entry, seconds: value)
  }
  private func probeDuration(_ entry: MediaEntry) {
    guard durations[entry] == nil, probing.insert(entry).inserted else { return }
    probes.async { [weak self] in
      let seconds = mz_probe_duration(entry.path)
      DispatchQueue.main.async {
        guard let self else { return }
        self.probing.remove(entry)
        self.record(seconds, for: entry)
        if seconds > 0 { self.didPrepare?(entry.path) }
      }
    }
  }
  private func persist(_ image: CGImage, to url: URL, key: String) {
    // Never wait for an encoder/writer before delivering a ready thumbnail.
    guard diskSlots.wait(timeout: .now()) == .success else { return }
    diskWriter.async { [self] in
      defer { diskSlots.signal() }
      autoreleasepool {
        let tmp = url.appendingPathExtension(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard
          let dest = CGImageDestinationCreateWithURL(tmp as CFURL, "public.png" as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(dest, image, nil)
        if CGImageDestinationFinalize(dest) {
          guard rename(tmp.path, url.path) == 0 else { return }
          if let attr = try? FileManager.default.attributesOfItem(atPath: url.path),
            let size = attr[.size] as? Int
          {
            catalog.noteCache(key: key, bytes: size)
          }
        }
      }
    }
  }
}

extension Int {
  func clamped(to range: ClosedRange<Int>, fallback: Int) -> Int {
    self == 0 ? fallback : Swift.min(range.upperBound, Swift.max(range.lowerBound, self))
  }
}
