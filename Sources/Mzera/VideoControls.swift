import AppKit

enum Timecode {
  /// Elapsed time, truncated to whole seconds: 0:07, 12:34, 1:02:03.
  static func text(_ seconds: Double) -> String {
    let total = seconds.isFinite ? max(0, Int(seconds.rounded(.down))) : 0
    let h = total / 3600
    let m = total / 60 % 60
    let s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
  }
  /// Clip length, rounded to the nearest second; a non-empty clip is at least 0:01.
  static func length(_ seconds: Double) -> String {
    text(seconds.isFinite && seconds > 0 ? max(1, seconds.rounded()) : 0)
  }
}

/// Transport bar for video: play/pause, elapsed time, scrubber, length and sound.
/// Hidden by default; mouse movement reveals it and inactivity hides it again.
final class VideoControlsView: NSView {
  var onTogglePause: (() -> Void)?
  var onToggleSound: (() -> Void)?
  var onSeek: ((Double) -> Void)?
  /// Called when the bar hides itself after inactivity.
  var onIdle: (() -> Void)?
  /// Controls exist only while a video is open in the viewer.
  var available = false {
    didSet { if !available { hide(animated: false) } }
  }
  private(set) var shown = false
  private(set) var scrubbing = false
  private var hideDeadline = 0.0
  private var pendingHide: DispatchWorkItem?
  private let playButton = NSButton()
  private let soundButton = NSButton()
  private let slider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
  private let elapsed = NSTextField(labelWithString: "0:00")
  private let total = NSTextField(labelWithString: "0:00")

  init() {
    super.init(frame: .zero)
    wantsLayer = true
    layer?.backgroundColor = NSColor(calibratedWhite: 0, alpha: 0.62).cgColor
    layer?.cornerRadius = 12
    appearance = NSAppearance(named: .darkAqua)
    isHidden = true
    alphaValue = 0
    for (button, action) in [
      (playButton, #selector(pauseClicked)), (soundButton, #selector(soundClicked)),
    ] {
      button.isBordered = false
      button.bezelStyle = .regularSquare
      button.imagePosition = .imageOnly
      button.contentTintColor = .white
      button.refusesFirstResponder = true
      button.target = self
      button.action = action
      button.widthAnchor.constraint(equalToConstant: 28).isActive = true
    }
    playButton.toolTip = "Space: play / pause"
    soundButton.toolTip = "V: sound on / off"
    slider.target = self
    slider.action = #selector(scrubbed)
    slider.isContinuous = true
    slider.refusesFirstResponder = true
    slider.controlSize = .small
    slider.toolTip = "Shift ← / →: seek 5 seconds"
    slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
    for label in [elapsed, total] {
      label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
      label.textColor = .white
      label.setContentHuggingPriority(.required, for: .horizontal)
    }
    let stack = NSStackView(views: [playButton, elapsed, slider, total, soundButton])
    stack.orientation = .horizontal
    stack.spacing = 10
    stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor),
      stack.topAnchor.constraint(equalTo: topAnchor),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
    update(paused: false, muted: true)
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  /// Bottom-centered over the video, at most 720 points wide.
  func constraints(over video: NSView) -> [NSLayoutConstraint] {
    let width = widthAnchor.constraint(equalTo: video.widthAnchor, constant: -40)
    // Must stay below windowSizeStayPut, or Auto Layout shrinks the window to fit the bar.
    width.priority = .defaultLow
    return [
      centerXAnchor.constraint(equalTo: video.centerXAnchor),
      bottomAnchor.constraint(equalTo: video.bottomAnchor, constant: -20),
      heightAnchor.constraint(equalToConstant: 40),
      widthAnchor.constraint(lessThanOrEqualToConstant: 720),
      width,
    ]
  }
  func update(position: Double, duration: Double) {
    let known = duration.isFinite && duration > 0
    if slider.isEnabled != known { slider.isEnabled = known }
    if known, slider.maxValue != duration { slider.maxValue = duration }
    if !known, slider.doubleValue != 0 { slider.doubleValue = 0 }
    let length = known ? Timecode.length(duration) : "--:--"
    if total.stringValue != length { total.stringValue = length }
    guard !scrubbing else { return }
    if known, slider.doubleValue != position { slider.doubleValue = position }
    let text = Timecode.text(position)
    if elapsed.stringValue != text { elapsed.stringValue = text }
  }
  func update(paused: Bool, muted: Bool) {
    func symbol(_ name: String, _ label: String) -> NSImage? {
      NSImage(systemSymbolName: name, accessibilityDescription: label)?.withSymbolConfiguration(
        .init(pointSize: 15, weight: .semibold))
    }
    playButton.image = symbol(paused ? "play.fill" : "pause.fill", paused ? "Play" : "Pause")
    soundButton.image = symbol(
      muted ? "speaker.slash.fill" : "speaker.wave.2.fill", muted ? "Sound off" : "Sound on")
  }
  /// Shows the bar and restarts the inactivity countdown.
  func reveal() {
    guard available else { return }
    if !shown {
      shown = true
      isHidden = false
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.15
        animator().alphaValue = 1
      }
    }
    // Mouse moves only push the deadline; one pending check re-arms itself if needed.
    hideDeadline = CACurrentMediaTime() + 2.5
    if pendingHide == nil { scheduleIdle(after: 2.5) }
  }
  private func scheduleIdle(after delay: Double) {
    let task = DispatchWorkItem { [weak self] in self?.idle() }
    pendingHide = task
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: task)
  }
  func hide(animated: Bool = true) {
    pendingHide?.cancel()
    pendingHide = nil
    guard shown || !isHidden else { return }
    shown = false
    scrubbing = false
    guard animated else {
      alphaValue = 0
      isHidden = true
      return
    }
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.3
      animator().alphaValue = 0
    } completionHandler: { [weak self] in
      MainActor.assumeIsolated {
        guard let self, !self.shown else { return }
        self.isHidden = true
      }
    }
  }
  private func idle() {
    pendingHide = nil
    guard shown else { return }
    let remaining = hideDeadline - CACurrentMediaTime()
    if remaining > 0.05 {
      scheduleIdle(after: remaining)
      return
    }
    // Keep the bar while the pointer rests on it or the knob is held. The live pointer
    // position is used because hiding the bar suppresses its mouse-exited event.
    let pointer = window.map { convert($0.mouseLocationOutsideOfEventStream, from: nil) }
    if scrubbing || pointer.map(bounds.contains) == true {
      reveal()
      return
    }
    hide()
    onIdle?()
  }
  // Clicks on the bar's background must not fall through to the viewer's pan/zoom.
  override func mouseDown(with event: NSEvent) {}
  @objc private func pauseClicked() { onTogglePause?() }
  @objc private func soundClicked() { onToggleSound?() }
  @objc private func scrubbed() {
    let type = NSApp.currentEvent?.type
    scrubbing = type == .leftMouseDown || type == .leftMouseDragged
    let text = Timecode.text(slider.doubleValue)
    if elapsed.stringValue != text { elapsed.stringValue = text }
    onSeek?(slider.doubleValue)
    reveal()
  }
}
