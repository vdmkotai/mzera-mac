import AVFoundation
import AppKit
import CMedia
import ImageIO

final class Playback {
  private var token = Cancellation()
  private let queue = DispatchQueue(label: "mzera.playback", qos: .userInitiated)
  private var engine: AVAudioEngine?
  private var player: AVAudioPlayerNode?
  private let audioFormat = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
  private var seekPosition: Double?
  /// Bumped by every seek; frames decoded for an older request are dropped.
  private var seekGeneration = 0
  private var pausedValue = false
  private let lock = NSCondition()
  private var audioEnabled = false
  private var playingVideo = false
  var muted = true {
    didSet {
      if !muted, playingVideo, engine == nil { audioSetup() }
      player?.volume = muted ? 0 : 1
      lock.lock()
      audioEnabled = !muted && player != nil
      lock.broadcast()
      lock.unlock()
    }
  }
  var paused: Bool {
    lock.lock()
    defer { lock.unlock() }
    return pausedValue
  }
  private var currentGeneration: Int {
    lock.lock()
    defer { lock.unlock() }
    return seekGeneration
  }
  var onVideo: ((CVPixelBuffer, Bool, Bool, Bool, Bool, Double) -> Void)?
  var onImage: ((PreparedImage) -> Void)?
  var onError: ((String) -> Void)?
  var onLoop: (() -> Void)?
  private(set) var position = 0.0
  private(set) var duration = 0.0
  func stop() {
    playingVideo = false
    token.cancel()
    player?.stop()
    engine?.stop()
    engine = nil
    player = nil
    lock.lock()
    seekPosition = nil
    pausedValue = false
    audioEnabled = false
    lock.broadcast()
    lock.unlock()
    position = 0
    duration = 0
  }
  func togglePause() {
    lock.lock()
    pausedValue.toggle()
    let pause = pausedValue
    lock.broadcast()
    lock.unlock()
    if pause { player?.pause() } else { player?.play() }
  }
  func seek(by delta: Double) { seek(to: position + delta) }
  /// Rapid calls collapse: the decoder only honors the latest requested position.
  func seek(to seconds: Double) {
    let target = max(0, min(max(0, duration - 0.01), seconds))
    lock.lock()
    seekPosition = target
    seekGeneration += 1
    let paused = pausedValue
    lock.broadcast()
    lock.unlock()
    position = target
    player?.stop()
    if !paused { player?.play() }
  }
  private func audioSetup() {
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    engine.attach(player)
    engine.connect(player, to: engine.mainMixerNode, format: audioFormat)
    player.volume = muted ? 0 : 1
    do {
      try engine.start()
      player.play()
      self.engine = engine
      self.player = player
    } catch {
      NSLog("Mzera audio: %@", error.localizedDescription)
      self.engine = nil
      self.player = nil
    }
  }
  /// Sleeps until the deadline or a control change; paused playback has no polling timer.
  private func wait(until deadline: Double, token: Cancellation) -> Double? {
    lock.lock()
    defer { lock.unlock() }
    var target = deadline
    var pausedFor = 0.0
    while !token.cancelled && seekPosition == nil {
      if pausedValue {
        let start = ProcessInfo.processInfo.systemUptime
        repeat { lock.wait() } while pausedValue && !token.cancelled && seekPosition == nil
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        pausedFor += elapsed
        target += elapsed
      } else {
        let remaining = target - ProcessInfo.processInfo.systemUptime
        if remaining <= 0 { return pausedFor }
        _ = lock.wait(until: Date(timeIntervalSinceNow: remaining))
      }
    }
    return nil
  }
  func startVideo(path: String, withAudio: Bool = true) {
    stop()
    let token = Cancellation()
    self.token = token
    playingVideo = withAudio
    if !muted && withAudio { audioSetup() }
    lock.lock()
    audioEnabled = !muted && player != nil
    lock.unlock()
    let gate = DispatchSemaphore(value: 2)
    queue.async { [weak self] in
      guard let self, !token.cancelled else { return }
      var error = [CChar](repeating: 0, count: 256)
      guard let decoder = mz_open(path, withAudio ? 1 : 0, 1, &error, 256) else {
        let message = String(cString: error)
        DispatchQueue.main.async { if !token.cancelled { self.onError?(message) } }
        return
      }
      defer { mz_close(decoder) }
      let duration = mz_duration(decoder)
      DispatchQueue.main.async { if !token.cancelled { self.duration = duration } }
      var origin: Double?
      var seekFloor = 0.0
      var framesThisLoop = 0
      var generation = self.currentGeneration
      // The first frame after a seek is shown at once, even when paused meanwhile.
      var seekFramePending = false
      // A seek into the tail after the last frame shows that frame instead of wrapping.
      var lastBeforeFloor: (MZFrame, CVPixelBuffer)?
      func present(_ frame: MZFrame, _ pixel: CVPixelBuffer) -> Bool {
        let seconds = frame.seconds
        let full = frame.full_range != 0
        let bt601 = frame.bt601 != 0
        let bt2020 = frame.bt2020 != 0
        let hardware = frame.hardware != 0
        guard let permit = FramePermit(gate: gate, token: token), !token.cancelled else {
          return false
        }
        DispatchQueue.main.async { [pixel, permit, generation] in
          defer { withExtendedLifetime(permit) {} }
          guard !token.cancelled, generation == self.currentGeneration else { return }
          self.position = seconds
          self.onVideo?(pixel, full, bt601, bt2020, hardware, seconds)
        }
        return true
      }
      while !token.cancelled {
        self.lock.lock()
        let seek = self.seekPosition
        self.seekPosition = nil
        let seekGeneration = self.seekGeneration
        self.lock.unlock()
        if let seek {
          _ = mz_seek(decoder, seek)
          origin = nil
          seekFloor = seek
          framesThisLoop = 0
          generation = seekGeneration
          seekFramePending = true
          lastBeforeFloor = nil
        }
        if self.paused && !seekFramePending {
          guard let elapsed = self.wait(until: ProcessInfo.processInfo.systemUptime, token: token)
          else { continue }
          if let old = origin { origin = old + elapsed }
        }
        self.lock.lock()
        let audioEnabled = self.audioEnabled
        self.lock.unlock()
        mz_set_audio_enabled(decoder, audioEnabled ? 1 : 0)
        var frame = MZFrame()
        let result = mz_next(decoder, &frame)
        if result == 0, seekFramePending, let (last, pixel) = lastBeforeFloor {
          seekFramePending = false
          lastBeforeFloor = nil
          origin = nil
          framesThisLoop += 1
          guard present(last, pixel) else { break }
          continue
        }
        if result <= 0 {
          // A seek past the last frame also wraps to the start instead of reporting no frames.
          if result == 0 && (framesThisLoop > 0 || seekFloor > 0) && mz_seek(decoder, 0) == 1 {
            origin = nil
            seekFloor = 0
            framesThisLoop = 0
            DispatchQueue.main.async {
              if !token.cancelled {
                self.player?.stop()
                if !self.paused { self.player?.play() }
                self.onLoop?()
              }
            }
            continue
          }
          DispatchQueue.main.async {
            if !token.cancelled {
              self.onError?(result < 0 ? "Cannot decode this video" : "No video frames")
            }
          }
          break
        }
        guard frame.seconds + 0.001 >= seekFloor else {
          if seekFramePending, frame.kind == 1, let raw = frame.pixel {
            lastBeforeFloor = (frame, raw.takeUnretainedValue())
          }
          continue
        }
        if seekFramePending && (frame.kind == 1 || self.paused) {
          // While paused, audio before the target frame is dropped.
          guard frame.kind == 1, let raw = frame.pixel else { continue }
          seekFramePending = false
          lastBeforeFloor = nil
          if self.paused { origin = nil }
          framesThisLoop += 1
          guard present(frame, raw.takeUnretainedValue()) else { break }
          continue
        }
        if frame.kind == 2 && frame.samples == 0 { continue }
        let seconds = frame.seconds
        if origin == nil { origin = ProcessInfo.processInfo.systemUptime - seconds + 0.025 }
        var target = origin! + seconds
        let lead = frame.kind == 2 ? 0.1 : 0.002
        guard let adjustment = self.wait(until: target - lead, token: token) else { continue }
        origin! += adjustment
        target += adjustment
        guard !token.cancelled else { break }
        if frame.kind == 1, let raw = frame.pixel {
          let pixel = raw.takeUnretainedValue()
          framesThisLoop += 1
          // Skip late frames rather than accumulate a presentation backlog.
          if ProcessInfo.processInfo.systemUptime - target > 0.15 { continue }
          guard present(frame, pixel) else { break }
        } else if frame.kind == 2, frame.samples > 0, let l = frame.left, let r = frame.right,
          let buffer = AVAudioPCMBuffer(
            pcmFormat: self.audioFormat, frameCapacity: AVAudioFrameCount(frame.samples))
        {
          buffer.frameLength = AVAudioFrameCount(frame.samples)
          buffer.floatChannelData![0].update(from: l, count: Int(frame.samples))
          buffer.floatChannelData![1].update(from: r, count: Int(frame.samples))
          DispatchQueue.main.async {
            guard !token.cancelled else { return }
            let time = AVAudioTime(
              hostTime: AVAudioTime.hostTime(
                forSeconds: max(target, ProcessInfo.processInfo.systemUptime)))
            self.player?.scheduleBuffer(buffer, at: time)
          }
        }
      }
    }
  }
  func startAnimation(path: String, limit: Int, device: MTLDevice) {
    if ["apng", "png"].contains(URL(fileURLWithPath: path).pathExtension.lowercased()) {
      startVideo(path: path, withAudio: false)
      return
    }
    stop()
    let token = Cancellation()
    self.token = token
    let gate = DispatchSemaphore(value: 2)
    queue.async { [weak self] in
      guard let self, !token.cancelled,
        let source = CGImageSourceCreateWithURL(
          URL(fileURLWithPath: path) as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
      else { return }
      let count = CGImageSourceGetCount(source)
      guard count > 1 else { return }
      let webp = path.lowercased().hasSuffix(".webp") ? mz_animation_open(path) : nil
      if path.lowercased().hasSuffix(".webp") && webp == nil {
        DispatchQueue.main.async {
          if !token.cancelled {
            self.onError?("Cannot decode animation (maximum canvas: 16 megapixels)")
          }
        }
        return
      }
      defer { if let webp { mz_animation_close(webp) } }
      var index = 0
      var deadline = ProcessInfo.processInfo.systemUptime
      while !token.cancelled {
        if self.paused {
          guard let elapsed = self.wait(until: ProcessInfo.processInfo.systemUptime, token: token)
          else { continue }
          deadline += elapsed
        }
        var webpDelay: Int32 = 0
        let prepared: PreparedImage? = autoreleasepool {
          if let webp {
            var data: UnsafePointer<UInt8>?
            var w: Int32 = 0
            var h: Int32 = 0
            guard mz_animation_next(webp, &data, &w, &h, &webpDelay) == 1, let data,
              let provider = CGDataProvider(
                dataInfo: nil, data: data, size: Int(w) * Int(h) * 4, releaseData: { _, _, _ in }),
              let image = CGImage(
                width: Int(w), height: Int(h), bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: Int(w) * 4, space: ImageDecoder.colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
            else { return nil }
            return ImageDecoder.prepare(image, animated: true, device: device)
          }
          guard
            let image = CGImageSourceCreateThumbnailAtIndex(
              source, index,
              [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: limit,
                kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary)
          else { return nil }
          return ImageDecoder.prepare(image, animated: true, device: device)
        }
        guard let prepared else { break }
        let properties =
          CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any] ?? [:]
        var delay = 0.1
        for name in ["{GIF}", "{PNG}", "{WebP}", "{HEICS}"] {
          if let dictionary = properties[name] as? [String: Any],
            let value = (dictionary["UnclampedDelayTime"] ?? dictionary["DelayTime"]) as? NSNumber
          {
            delay = max(0.01, value.doubleValue)
            break
          }
        }
        if webp != nil { delay = max(0.01, Double(webpDelay) / 1000) }
        guard let adjustment = self.wait(until: deadline, token: token) else { continue }
        deadline += adjustment
        guard let permit = FramePermit(gate: gate, token: token), !token.cancelled else { break }
        DispatchQueue.main.async { [permit] in
          defer { withExtendedLifetime(permit) {} }
          if !token.cancelled { self.onImage?(prepared) }
        }
        deadline = max(deadline + delay, ProcessInfo.processInfo.systemUptime)
        index = (index + 1) % count
        if index == 0, let webp { mz_animation_reset(webp) }
      }
    }
  }
}

// A permit returns its slot even when cancellation wins between acquisition and dispatch.
final class FramePermit {
  private let gate: DispatchSemaphore
  private var acquired = false
  init?(gate: DispatchSemaphore, token: Cancellation) {
    self.gate = gate
    while !token.cancelled {
      if gate.wait(timeout: .now() + 0.02) == .success {
        acquired = true
        return
      }
    }
    return nil
  }
  deinit { if acquired { gate.signal() } }
}
