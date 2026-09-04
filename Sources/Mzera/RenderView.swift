import AppKit
import MetalKit

struct VideoSurface {
  let pixel: CVPixelBuffer
  let y: MTLTexture
  let uv: MTLTexture?
  let references: [CVMetalTexture]
  let fullRange: Bool
  let bt601: Bool
  var width: Int { CVPixelBufferGetWidth(pixel) }
  var height: Int { CVPixelBufferGetHeight(pixel) }
}

final class RenderView: MTKView, MTKViewDelegate {
  private struct Vertex {
    var pos: SIMD2<Float>
    var uv: SIMD2<Float>
    var color: SIMD4<Float>
  }
  private let commands: MTLCommandQueue
  private let pipeline: MTLRenderPipelineState
  private let videoPipeline: MTLRenderPipelineState
  private let white: MTLTexture
  private var textureCache: CVMetalTextureCache?
  private var labels: [NSTextField] = []
  private var sectionsDirty = true
  var entries: [MediaEntry] = [] { didSet { sectionsDirty = true } }
  var layout = GridLayout()
  var grouped = false { didSet { if grouped != oldValue { sectionsDirty = true } } }
  var tile: Double = 160
  var offset: Double = 0
  var selected: Int = 0
  var viewer = false
  var photo: PreparedImage?
  var video: VideoSurface?
  var zoom: Double? = nil
  var pan = CGPoint.zero
  var cache: MediaCache?
  var root = ""
  var onViewport: (() -> Void)?
  var onOpen: ((Int) -> Void)?
  var onSelect: ((Int) -> Void)?
  var onKey: ((NSEvent) -> Bool)?
  private var dragPoint = CGPoint.zero
  private(set) var renderedFrames = 0
  private(set) var lastDrawMilliseconds = 0.0
  private var pendingInput: Double?
  private(set) var presentationSamples: [Double] = []
  var firstMediaPresentedTime: Double?
  func markPreparedInput(_ ready: Bool) { pendingInput = ready ? CACurrentMediaTime() : nil }
  func interact() {
    preferredFramesPerSecond = window?.screen?.maximumFramesPerSecond ?? 60
    needsDisplay = true
  }
  override var acceptsFirstResponder: Bool { true }
  override var isFlipped: Bool { true }
  init(device: MTLDevice) throws {
    guard let commands = device.makeCommandQueue() else { throw NSError(domain: "Metal", code: 1) }
    self.commands = commands
    let library: MTLLibrary
    if let url = Bundle.main.url(forResource: "Shaders", withExtension: "metallib") {
      library = try device.makeLibrary(URL: url)
    } else {
      let url = Bundle.module.url(forResource: "Shaders", withExtension: "metal")!
      library = try device.makeLibrary(
        source: String(contentsOf: url, encoding: .utf8), options: nil)
    }
    func make(_ fragment: String) throws -> MTLRenderPipelineState {
      let d = MTLRenderPipelineDescriptor()
      d.vertexFunction = library.makeFunction(name: "mz_vertex")
      d.fragmentFunction = library.makeFunction(name: fragment)
      d.colorAttachments[0].pixelFormat = .bgra8Unorm
      d.colorAttachments[0].isBlendingEnabled = true
      d.colorAttachments[0].sourceRGBBlendFactor = .one
      d.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
      d.colorAttachments[0].sourceAlphaBlendFactor = .one
      d.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
      return try device.makeRenderPipelineState(descriptor: d)
    }
    pipeline = try make("rgba")
    videoPipeline = try make("yuv")
    let d = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
    white = device.makeTexture(descriptor: d)!
    var pixel: UInt32 = 0xffff_ffff
    white.replace(
      region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &pixel, bytesPerRow: 4)
    super.init(frame: .zero, device: device)
    colorPixelFormat = .bgra8Unorm
    clearColor = MTLClearColorMake(0.065, 0.07, 0.08, 1)
    framebufferOnly = true
    enableSetNeedsDisplay = true
    isPaused = true
    delegate = self
    (layer as? CAMetalLayer)?.maximumDrawableCount = 2
    (layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
    CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
  }
  required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  func rebuild() {
    if sectionsDirty {
      layout.rebuild(entries: entries, width: bounds.width, tile: tile, grouped: grouped)
      sectionsDirty = false
    } else {
      layout.reflow(width: bounds.width, tile: tile)
    }
    offset = min(max(0, offset), max(0, layout.height - bounds.height))
    needsDisplay = true
    onViewport?()
  }
  func resetViewer() {
    photo = nil
    video = nil
    zoom = nil
    pan = .zero
    needsDisplay = true
  }
  func showPixel(_ pixel: CVPixelBuffer, fullRange: Bool, bt601: Bool) {
    guard let textureCache else { return }
    let planes = CVPixelBufferGetPlaneCount(pixel)
    var y: CVMetalTexture?
    var uv: CVMetalTexture?
    if planes == 2 {
      let format = CVPixelBufferGetPixelFormatType(pixel)
      guard
        format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
          || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
      else { return }
      CVMetalTextureCacheCreateTextureFromImage(
        nil, textureCache, pixel, nil, .r8Unorm, CVPixelBufferGetWidthOfPlane(pixel, 0),
        CVPixelBufferGetHeightOfPlane(pixel, 0), 0, &y)
      CVMetalTextureCacheCreateTextureFromImage(
        nil, textureCache, pixel, nil, .rg8Unorm, CVPixelBufferGetWidthOfPlane(pixel, 1),
        CVPixelBufferGetHeightOfPlane(pixel, 1), 1, &uv)
    } else {
      CVMetalTextureCacheCreateTextureFromImage(
        nil, textureCache, pixel, nil, .bgra8Unorm, CVPixelBufferGetWidth(pixel),
        CVPixelBufferGetHeight(pixel), 0, &y)
    }
    guard let y, let texture = CVMetalTextureGetTexture(y) else { return }
    video = VideoSurface(
      pixel: pixel, y: texture, uv: uv.flatMap(CVMetalTextureGetTexture),
      references: [y] + (uv.map { [$0] } ?? []), fullRange: fullRange, bt601: bt601)
    needsDisplay = true
  }
  func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { rebuild() }
  func draw(in view: MTKView) {
    let start = ProcessInfo.processInfo.systemUptime
    guard bounds.width > 0, bounds.height > 0, let pass = currentRenderPassDescriptor,
      let drawable = currentDrawable,
      let buffer = commands.makeCommandBuffer(),
      let encoder = buffer.makeRenderCommandEncoder(descriptor: pass)
    else { return }
    encoder.setRenderPipelineState(pipeline)
    var drewMedia = false
    func quad(_ rect: CGRect, _ texture: MTLTexture, _ color: SIMD4<Float> = SIMD4(repeating: 1)) {
      let l = Float(rect.minX / bounds.width * 2 - 1)
      let r = Float(rect.maxX / bounds.width * 2 - 1)
      let t = Float(1 - rect.minY / bounds.height * 2)
      let b = Float(1 - rect.maxY / bounds.height * 2)
      var vertices = [
        Vertex(pos: [l, t], uv: [0, 0], color: color),
        Vertex(pos: [l, b], uv: [0, 1], color: color),
        Vertex(pos: [r, t], uv: [1, 0], color: color),
        Vertex(pos: [r, t], uv: [1, 0], color: color),
        Vertex(pos: [l, b], uv: [0, 1], color: color),
        Vertex(pos: [r, b], uv: [1, 1], color: color),
      ]
      encoder.setVertexBytes(
        &vertices, length: MemoryLayout<Vertex>.stride * vertices.count, index: 0)
      encoder.setFragmentTexture(texture, index: 0)
      encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }
    if viewer {
      labels.forEach { $0.isHidden = true }
      if let video {
        drewMedia = true
        if let uv = video.uv {
          encoder.setRenderPipelineState(videoPipeline)
          encoder.setFragmentTexture(uv, index: 1)
          var flags = SIMD2<Float>(video.fullRange ? 1 : 0, video.bt601 ? 1 : 0)
          encoder.setFragmentBytes(&flags, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
        }
        quad(fitted(width: video.width, height: video.height), video.y)
        // Keep the CVPixelBuffer and CVMetalTexture wrappers alive through GPU completion.
        buffer.addCompletedHandler { _ in _ = video }
      } else if let photo {
        drewMedia = true
        quad(fitted(width: photo.width, height: photo.height), photo.texture)
      }
    } else {
      let visible = layout.visible(offset: offset, height: bounds.height)
      for index in visible {
        let entry = entries[index]
        let rect = layout.rect(at: index).offsetBy(dx: 0, dy: -offset)
        quad(rect, white, SIMD4(0.11, 0.12, 0.14, 1))
        if let thumb = cache?.get(entry, limit: 512) {
          drewMedia = true
          let scale = min(rect.width / Double(thumb.width), rect.height / Double(thumb.height))
          let w = Double(thumb.width) * scale
          let h = Double(thumb.height) * scale
          quad(
            CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h), thumb.texture)
        } else if cache?.isFailed(entry, limit: 512) == true {
          quad(
            CGRect(x: rect.midX - 7, y: rect.midY - 1, width: 14, height: 2), white,
            SIMD4(0.8, 0.35, 0.35, 1))
        }
        if entry.isVideo {
          quad(
            CGRect(x: rect.minX + 6, y: rect.maxY - 12, width: 18, height: 6), white,
            SIMD4(0.3, 0.7, 0.95, 1))
        }
        if index == selected {
          let c = SIMD4<Float>(0.3, 0.7, 1, 1)
          for edge in [
            CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 2),
            CGRect(x: rect.minX, y: rect.maxY - 2, width: rect.width, height: 2),
            CGRect(x: rect.minX, y: rect.minY, width: 2, height: rect.height),
            CGRect(x: rect.maxX - 2, y: rect.minY, width: 2, height: rect.height),
          ] { quad(edge, white, c) }
        }
      }
      updateHeaders()
    }
    if let input = pendingInput {
      pendingInput = nil
      drawable.addPresentedHandler { [weak self] presented in
        let elapsed = (presented.presentedTime - input) * 1000
        guard elapsed > 0 else { return }
        DispatchQueue.main.async {
          guard let self else { return }
          self.presentationSamples.append(elapsed)
          if self.presentationSamples.count > 2048 { self.presentationSamples.removeFirst(1024) }
        }
      }
    }
    if drewMedia, firstMediaPresentedTime == nil {
      drawable.addPresentedHandler { [weak self] presented in
        let time = presented.presentedTime
        DispatchQueue.main.async {
          if time > 0, self?.firstMediaPresentedTime == nil { self?.firstMediaPresentedTime = time }
        }
      }
    }
    encoder.endEncoding()
    buffer.present(drawable)
    buffer.commit()
    renderedFrames += 1
    lastDrawMilliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1000
  }
  private func fitted(width: Int, height: Int) -> CGRect {
    let fit = min(bounds.width / Double(width), bounds.height / Double(height))
    let scale = zoom ?? fit
    let w = Double(width) * scale
    let h = Double(height) * scale
    return CGRect(
      x: (bounds.width - w) / 2 + pan.x, y: (bounds.height - h) / 2 + pan.y, width: w, height: h)
  }
  private func updateHeaders() {
    var needed: [(String, Double)] = []
    if grouped {
      var i = layout.section(at: offset)
      while i < layout.sections.count && layout.sections[i].y < offset + bounds.height {
        let s = layout.sections[i]
        let y = max(s.y - offset, min(0, s.bottom - offset - layout.header))
        let title =
          s.title.hasPrefix(root)
          ? String(s.title.dropFirst(root.count)).trimmingCharacters(
            in: CharacterSet(charactersIn: "/")) : s.title
        needed.append((title.isEmpty ? (root as NSString).lastPathComponent : title, y))
        i += 1
      }
    }
    while labels.count < needed.count {
      let field = NSTextField(labelWithString: "")
      field.font = .systemFont(ofSize: 12, weight: .medium)
      field.textColor = .secondaryLabelColor
      field.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1)
      field.drawsBackground = true
      field.lineBreakMode = .byTruncatingHead
      addSubview(field)
      labels.append(field)
    }
    for (i, label) in labels.enumerated() {
      label.isHidden = i >= needed.count
      if i < needed.count {
        label.stringValue = needed[i].0
        label.frame = CGRect(x: 8, y: needed[i].1, width: bounds.width - 16, height: 26)
      }
    }
  }
  func scrollToSelected() {
    let rect = layout.rect(at: selected)
    if rect.minY < offset + layout.header { offset = max(0, rect.minY - layout.header) }
    if rect.maxY > offset + bounds.height { offset = rect.maxY - bounds.height }
    needsDisplay = true
    onViewport?()
  }
  override func scrollWheel(with event: NSEvent) {
    if viewer {
      if event.modifierFlags.contains(.command) {
        magnify(by: Double(event.scrollingDeltaY) * 0.015)
      } else if zoom != nil {
        pan.x += event.scrollingDeltaX
        pan.y += event.scrollingDeltaY
        needsDisplay = true
      }
      return
    }
    let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 24
    offset = min(max(0, offset - Double(delta)), max(0, layout.height - bounds.height))
    needsDisplay = true
    onViewport?()
    interact()
  }
  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    dragPoint = convert(event.locationInWindow, from: nil)
    if viewer {
      if event.clickCount == 2 {
        zoom = zoom == nil ? 1 / (window?.backingScaleFactor ?? 2) : nil
        pan = .zero
        needsDisplay = true
        onViewport?()
      }
      return
    }
    if let index = layout.hit(x: dragPoint.x, y: dragPoint.y + offset) {
      selected = index
      onSelect?(index)
      needsDisplay = true
      if event.clickCount == 2 { onOpen?(index) }
    }
  }
  override func mouseDragged(with event: NSEvent) {
    guard viewer else { return }
    let point = convert(event.locationInWindow, from: nil)
    pan.x += point.x - dragPoint.x
    pan.y += point.y - dragPoint.y
    dragPoint = point
    needsDisplay = true
  }
  override func magnify(with event: NSEvent) { if viewer { magnify(by: event.magnification) } }
  private func magnify(by amount: Double) {
    let w = video?.width ?? photo?.width ?? 1
    let h = video?.height ?? photo?.height ?? 1
    zoom = min(
      8,
      max(0.03, (zoom ?? min(bounds.width / Double(w), bounds.height / Double(h))) * (1 + amount)))
    needsDisplay = true
    onViewport?()
  }
  override func keyDown(with event: NSEvent) {
    if onKey?(event) != true { super.keyDown(with: event) }
  }
}
