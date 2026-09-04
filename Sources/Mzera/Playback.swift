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
  private var pausedValue = false
  private let lock = NSLock()
  private var playingVideo = false
  var muted = true {
    didSet {
      if !muted, playingVideo, engine == nil { audioSetup() }
      player?.volume = muted ? 0 : 1
    }
  }
  var paused: Bool {
    lock.lock()
    defer { lock.unlock() }
    return pausedValue
  }
  var onVideo: ((CVPixelBuffer, Bool, Bool, Bool, Double) -> Void)?
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
    lock.unlock()
    position = 0
    duration = 0
  }
  func togglePause() {
    lock.lock()
    pausedValue.toggle()
    let pause = pausedValue
    lock.unlock()
    if pause { player?.pause() } else { player?.play() }
  }
  func seek(by delta: Double) {
    lock.lock()
    seekPosition = max(0, min(max(0, duration - 0.01), position + delta))
    lock.unlock()
    player?.stop()
    player?.play()
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
      self.engine = nil
      self.player = nil
    }
  }
  func startVideo(path: String) {
    stop()
    let token = Cancellation()
    self.token = token
    playingVideo = true
    if !muted { audioSetup() }
    let gate = DispatchSemaphore(value: 2)
    queue.async { [weak self] in
      guard let self, !token.cancelled else { return }
      var error = [CChar](repeating: 0, count: 256)
      guard let decoder = mz_open(path, 1, 1, &error, 256) else {
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
      while !token.cancelled {
        self.lock.lock()
        let seek = self.seekPosition
        self.seekPosition = nil
        self.lock.unlock()
        if let seek {
          _ = mz_seek(decoder, seek)
          origin = nil
          seekFloor = seek
          framesThisLoop = 0
        }
        if self.paused {
          let t = ProcessInfo.processInfo.systemUptime
          while self.paused && !token.cancelled { Thread.sleep(forTimeInterval: 0.01) }
          if let old = origin { origin = old + ProcessInfo.processInfo.systemUptime - t }
        }
        var frame = MZFrame()
        let result = mz_next(decoder, &frame)
        if result <= 0 {
          if result == 0 && framesThisLoop > 0 && mz_seek(decoder, 0) == 1 {
            origin = nil
            seekFloor = 0
            framesThisLoop = 0
            DispatchQueue.main.async {
              if !token.cancelled {
                self.player?.stop()
                self.player?.play()
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
        guard frame.seconds + 0.001 >= seekFloor else { continue }
        let seconds = frame.seconds
        if origin == nil { origin = ProcessInfo.processInfo.systemUptime - seconds + 0.025 }
        let target = origin! + seconds
        let lead = frame.kind == 2 ? 0.1 : 0.002
        while !token.cancelled && ProcessInfo.processInfo.systemUptime < target - lead {
          Thread.sleep(
            forTimeInterval: min(
              0.008, max(0.001, target - lead - ProcessInfo.processInfo.systemUptime)))
        }
        guard !token.cancelled else { break }
        if frame.kind == 1, let raw = frame.pixel {
          let pixel = raw.takeUnretainedValue()
          framesThisLoop += 1
          // Skip late frames rather than accumulate a presentation backlog.
          if ProcessInfo.processInfo.systemUptime - target > 0.15 { continue }
          let full = frame.full_range != 0
          let bt601 = frame.bt601 != 0
          let hardware = frame.hardware != 0
          guard let permit = FramePermit(gate: gate, token: token), !token.cancelled else { break }
          DispatchQueue.main.async { [pixel, permit] in
            defer { withExtendedLifetime(permit) {} }
            guard !token.cancelled else { return }
            self.position = seconds
            self.onVideo?(pixel, full, bt601, hardware, seconds)
          }
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
      var index = 0
      var deadline = ProcessInfo.processInfo.systemUptime
      while !token.cancelled {
        if self.paused {
          while self.paused && !token.cancelled { Thread.sleep(forTimeInterval: 0.01) }
          deadline = ProcessInfo.processInfo.systemUptime
        }
        let prepared: PreparedImage? = autoreleasepool {
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
        while !token.cancelled && ProcessInfo.processInfo.systemUptime < deadline {
          Thread.sleep(forTimeInterval: min(0.008, deadline - ProcessInfo.processInfo.systemUptime))
        }
        guard let permit = FramePermit(gate: gate, token: token), !token.cancelled else { break }
        DispatchQueue.main.async { [permit] in
          defer { withExtendedLifetime(permit) {} }
          if !token.cancelled { self.onImage?(prepared) }
        }
        deadline = max(deadline + delay, ProcessInfo.processInfo.systemUptime)
        index = (index + 1) % count
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
