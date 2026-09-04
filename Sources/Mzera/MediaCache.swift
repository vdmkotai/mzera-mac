import CMedia
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Metal

struct PreparedImage {
  let texture: MTLTexture
  let width: Int
  let height: Int
  let animated: Bool
  var cost: Int { width * height * 4 }
}

enum ImageDecoder {
  static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
  static func image(path: String, limit: Int, index: Int = 0) -> (CGImage, Bool)? {
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
    return (image, CGImageSourceGetCount(source) > 1)
  }
  static func prepare(_ image: CGImage, animated: Bool = false, device: MTLDevice) -> PreparedImage?
  {
    let w = image.width
    let h = image.height
    guard w > 0, h > 0, w <= 16384, h <= 16384, w * h <= 100_000_000,
      let context = CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
          | CGBitmapInfo.byteOrder32Little.rawValue)
    else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
    descriptor.storageMode = .shared
    descriptor.usage = .shaderRead
    guard let texture = device.makeTexture(descriptor: descriptor), let data = context.data else {
      return nil
    }
    texture.replace(
      region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: data, bytesPerRow: w * 4)
    return PreparedImage(texture: texture, width: w, height: h, animated: animated)
  }
  static func videoThumbnail(path: String, limit: Int, device: MTLDevice) -> PreparedImage? {
    var error = [CChar](repeating: 0, count: 256)
    guard let decoder = mz_open(path, 0, 0, &error, 256) else { return nil }
    defer { mz_close(decoder) }
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
    let ratio = min(1, Double(limit) / Double(max(w, h)))
    let tw = max(1, Int(Double(w) * ratio))
    let th = max(1, Int(Double(h) * ratio))
    guard
      let small = CGContext(
        data: nil, width: tw, height: th, bitsPerComponent: 8, bytesPerRow: tw * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    small.draw(original, in: CGRect(x: 0, y: 0, width: tw, height: th))
    return small.makeImage().flatMap { prepare($0, device: device) }
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

// Owned by the main thread. At most four image jobs and one video-thumbnail job
// execute; desired requests replace the old waiting set rather than append to it.
final class MediaCache {
  struct Request {
    let entry: MediaEntry
    let limit: Int
    let urgent: Bool
  }
  let device: MTLDevice
  let catalog: Catalog
  let thumbnails = ByteLRU<String, PreparedImage>(limit: 384 * 1024 * 1024)
  let photos = ByteLRU<String, PreparedImage>(limit: 1024 * 1024 * 1024)
  private let workers = DispatchQueue(
    label: "mzera.decode", qos: .userInitiated, attributes: .concurrent)
  private let videos = DispatchQueue(label: "mzera.video-thumbnails", qos: .utility)
  private let diskWriter = DispatchQueue(label: "mzera.thumbnail-writer", qos: .utility)
  private let diskSlots = DispatchSemaphore(value: 8)
  private var wanted: [Request] = []
  private var active: Set<String> = []
  private var failures: Set<String> = []
  private var imageJobs = 0, videoJobs = 0, writes = 0
  private(set) var queuedCount = 0
  private(set) var peakJobs = 0
  private var pressure: DispatchSourceMemoryPressure?
  var didPrepare: ((String) -> Void)?
  init(device: MTLDevice, catalog: Catalog) {
    self.device = device
    self.catalog = catalog
    try? FileManager.default.createDirectory(
      at: catalog.base.appendingPathComponent("thumbs"), withIntermediateDirectories: true)
    pressure = DispatchSource.makeMemoryPressureSource(
      eventMask: [.warning, .critical], queue: .main)
    pressure?.setEventHandler { [weak self] in
      guard let self else { return }
      self.thumbnails.limit = 64 * 1024 * 1024
      self.photos.limit = 128 * 1024 * 1024
      self.wanted = Array(self.wanted.filter(\.urgent).prefix(1))
    }
    pressure?.resume()
    catalog.trimCache(
      limit: Int64(
        UserDefaults.standard.integer(forKey: "diskCacheGiB").clamped(to: 1...100, fallback: 30))
        * 1024 * 1024 * 1024)
  }
  static func key(_ entry: MediaEntry, limit: Int) -> String {
    let text = "v1|\(entry.path)|\(entry.size)|\(entry.modified)|\(limit)"
    return text
  }
  func get(_ e: MediaEntry, limit: Int) -> PreparedImage? {
    (limit <= 512 ? thumbnails : photos).get(Self.key(e, limit: limit))
  }
  func isFailed(_ e: MediaEntry, limit: Int) -> Bool {
    failures.contains(Self.key(e, limit: limit))
  }
  func request(_ requests: [Request]) {
    var seen = Set<String>()
    wanted = requests.filter { seen.insert(Self.key($0.entry, limit: $0.limit)).inserted }
    pump()
  }
  func clear() {
    wanted = []
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
      if active.contains(key) || failures.contains(key)
        || get(request.entry, limit: request.limit) != nil
      {
        continue
      }
      if request.entry.isVideo ? videoJobs >= 1 : imageJobs >= (request.urgent ? 4 : 3) {
        remaining.append(request)
        continue
      }
      active.insert(key)
      if request.entry.isVideo { videoJobs += 1 } else { imageJobs += 1 }
      peakJobs = max(peakJobs, imageJobs + videoJobs)
      let queue = request.entry.isVideo ? videos : workers
      queue.async { [weak self] in
        guard let self else { return }
        let result: PreparedImage? = autoreleasepool {
          let diskKey =
            SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined() + ".png"
          let cacheURL = self.catalog.base.appendingPathComponent("thumbs").appendingPathComponent(
            diskKey)
          if request.limit <= 512, FileManager.default.fileExists(atPath: cacheURL.path),
            let (image, _) = ImageDecoder.image(path: cacheURL.path, limit: request.limit)
          {
            self.catalog.touchCache(key: diskKey)
            return ImageDecoder.prepare(image, device: self.device)
          }
          if request.entry.isVideo {
            let prepared = ImageDecoder.videoThumbnail(
              path: request.entry.path, limit: request.limit, device: self.device)
            if let prepared, let image = ImageDecoder.bitmap(prepared) {
              self.persist(image, to: cacheURL, key: diskKey)
            }
            return prepared
          }
          guard
            let (image, animated) = ImageDecoder.image(
              path: request.entry.path, limit: request.limit)
          else { return nil }
          let prepared = ImageDecoder.prepare(image, animated: animated, device: self.device)
          if request.limit <= 512, prepared != nil {
            self.persist(image, to: cacheURL, key: diskKey)
          }
          return prepared
        }
        DispatchQueue.main.async {
          self.active.remove(key)
          if request.entry.isVideo { self.videoJobs -= 1 } else { self.imageJobs -= 1 }
          // A completed old request is harmless, but never enters the cache unless still wanted.
          if self.wanted.contains(where: { Self.key($0.entry, limit: $0.limit) == key }) {
            let destination = request.limit <= 512 ? self.thumbnails : self.photos
            if let result, result.cost <= destination.limit {
              destination.put(key, result, cost: result.cost)
            } else {
              if self.failures.count >= 4096 { self.failures.removeAll(keepingCapacity: true) }
              self.failures.insert(key)
            }
            self.didPrepare?(request.entry.path)
          }
          self.writes += 1
          if self.writes % 100 == 0 { self.catalog.trimCache(limit: 30 * 1024 * 1024 * 1024) }
          self.pump()
        }
      }
    }
    // Keep the desired set (including active jobs) for generation checks on completion.
    queuedCount = remaining.count
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
          try? FileManager.default.moveItem(at: tmp, to: url)
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
