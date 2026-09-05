import AppKit

/// Instant full-screen presentation on the current display, without a Spaces transition.
final class ViewerWindow: NSWindow {
  var onToggleFullscreen: (() -> Void)?
  private(set) var isImmersive = false
  private var savedFrame = NSRect.zero
  private var savedStyle: NSWindow.StyleMask = []
  private var savedPresentation: NSApplication.PresentationOptions = []
  private var savedAutosaveName: NSWindow.FrameAutosaveName = ""
  private var savedShadow = true

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }
  override func toggleFullScreen(_ sender: Any?) { onToggleFullscreen?() }

  func setImmersive(_ enabled: Bool) {
    guard enabled != isImmersive else { return }
    if enabled {
      guard let display = screen ?? NSScreen.main else { return }
      savedFrame = frame
      savedStyle = styleMask
      savedPresentation = NSApp.presentationOptions
      savedAutosaveName = frameAutosaveName
      savedShadow = hasShadow
      setFrameAutosaveName("")
      isImmersive = true
      NSApp.presentationOptions = [.hideDock, .hideMenuBar]
      styleMask = [.borderless]
      // WindowServer's shadow decoration can leave a bright rim even on a borderless window.
      hasShadow = false
      setFrame(display.frame, display: true, animate: false)
      NSCursor.setHiddenUntilMouseMoves(true)
    } else {
      isImmersive = false
      NSApp.presentationOptions = savedPresentation
      styleMask = savedStyle
      hasShadow = savedShadow
      setFrame(savedFrame, display: true, animate: false)
      setFrameAutosaveName(savedAutosaveName)
      NSCursor.setHiddenUntilMouseMoves(false)
    }
    makeKeyAndOrderFront(nil)
  }
}
