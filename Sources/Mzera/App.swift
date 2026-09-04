import AppKit
import Metal

final class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate {
  var window: NSWindow!
  var render: RenderView!
  private var cache: MediaCache!
  private var catalog: Catalog!
  private let playback = Playback()
  private var all: [MediaEntry] = []
  private var root: URL?
  private var scanToken = Cancellation()
  private var sortToken = Cancellation()
  private var rootCatalogReady = false
  private var watcher: FolderWatcher?
  private var scanRunning = false
  private var sortRunning = false
  private var rescanAfter = false
  private var scanID = 0, sortID = 0
  private let scanner = DispatchQueue(label: "mzera.scanner", qos: .userInitiated)
  private let sorter = DispatchQueue(label: "mzera.sort", qos: .userInitiated)
  private var sortOrder = SortOrder.path
  private var grouped = false
  private var filter = 0
  private var animationPath: String?
  private var pendingSave: DispatchWorkItem?
  private var pendingRescan: DispatchWorkItem?
  private var restorePath: String?
  private var restoreViewer = false
  private var restoreOffset = 0.0
  private var initialOrderPending = true
  private var selectionChanged = false
  private let status = NSTextField(labelWithString: "Open a folder to begin")
  private let titleField = NSTextField(labelWithString: "")
  private let grouping = NSSegmentedControl(
    labels: ["Flat", "By folder"], trackingMode: .selectOne, target: nil, action: nil)
  private let sorting = NSPopUpButton()
  private let filtering = NSPopUpButton()
  private let sound = NSButton(title: "Sound off", target: nil, action: nil)
  private let pause = NSButton(title: "Pause", target: nil, action: nil)
  private let scroller = NSScroller()
  private var statsTimer: Timer?
  private var loadError: String?
  private var firstContent = false
  private let launchTime = ProcessInfo.processInfo.systemUptime
  private var firstPreparedMS: Double?
  private var folderOpenedAt = CACurrentMediaTime()
  private var settingsWindow: NSWindow?

  func applicationDidFinishLaunching(_ notification: Notification) {
    guard let device = MTLCreateSystemDefaultDevice() else {
      fatal("Metal is unavailable on this Mac")
      return
    }
    do { render = try RenderView(device: device) } catch {
      fatal("Cannot initialize Metal: \(error)")
      return
    }
    catalog = Catalog()
    cache = MediaCache(device: device, catalog: catalog)
    render.cache = cache
    let defaults = UserDefaults.standard
    grouped = defaults.bool(forKey: "grouped")
    filter = min(2, max(0, defaults.integer(forKey: "filter")))
    sortOrder = SortOrder(rawValue: defaults.integer(forKey: "sort")) ?? .path
    render.tile = Double(defaults.integer(forKey: "tile").clamped(to: 90...300, fallback: 160))
    let savedRAM = defaults.integer(forKey: "photoCacheMiB").clamped(to: 128...3072, fallback: 1024)
    cache.photos.limit = savedRAM * 1_048_576
    playback.muted = !defaults.bool(forKey: "sound")
    buildMenu()
    buildWindow()
    render.onViewport = { [weak self] in
      self?.refreshRequests()
      self?.updateScroller()
      self?.scheduleSave()
    }
    render.onOpen = { [weak self] i in self?.openViewer(i) }
    render.onSelect = { [weak self] _ in
      self?.selectionChanged = true
      self?.updateStatus()
      self?.scheduleSave()
    }
    render.onKey = { [weak self] e in self?.key(e) ?? false }
    cache.didPrepare = { [weak self] path in
      guard let self else { return }
      self.render.needsDisplay = true
      if self.render.viewer, self.current?.path == path { self.showPrepared() }
      self.markFirstContent()
    }
    playback.onVideo = { [weak self] pixel, full, bt601, hw, _ in
      guard let self, self.render.viewer else { return }
      self.render.showPixel(pixel, fullRange: full, bt601: bt601)
      self.markFirstContent()
      self.titleField.toolTip = hw ? "VideoToolbox frame" : "Software decoder"
    }
    playback.onImage = { [weak self] image in
      self?.render.photo = image
      self?.render.needsDisplay = true
    }
    playback.onError = { [weak self] error in
      self?.loadError = error
      self?.updateStatus()
    }
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    window.makeFirstResponder(render)
    statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      self?.updateStatus()
      self?.writeMetrics()
    }
    if let index = CommandLine.arguments.firstIndex(of: "--folder"),
      CommandLine.arguments.count > index + 1
    {
      openRoot(URL(fileURLWithPath: CommandLine.arguments[index + 1]))
    } else if let saved = defaults.string(forKey: "root"),
      FileManager.default.fileExists(atPath: saved)
    {
      restorePath = defaults.string(forKey: "selectedPath")
      restoreViewer = defaults.bool(forKey: "viewer")
      restoreOffset = defaults.double(forKey: "offset")
      openRoot(URL(fileURLWithPath: saved), restore: true)
    } else {
      DispatchQueue.main.async { self.chooseFolder() }
    }
  }
  private func buildMenu() {
    let menu = NSMenu()
    let appItem = NSMenuItem()
    menu.addItem(appItem)
    let app = NSMenu()
    appItem.submenu = app
    app.addItem(withTitle: "About Mzera", action: #selector(about), keyEquivalent: "").target = self
    app.addItem(withTitle: "Settings…", action: #selector(settings), keyEquivalent: ",").target =
      self
    app.addItem(.separator())
    app.addItem(
      withTitle: "Quit Mzera", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    let fileItem = NSMenuItem()
    menu.addItem(fileItem)
    let file = NSMenu(title: "File")
    fileItem.submenu = file
    file.addItem(withTitle: "Open folder…", action: #selector(chooseFolder), keyEquivalent: "o")
      .target = self
    file.addItem(withTitle: "Refresh folder", action: #selector(rescan), keyEquivalent: "r")
      .target = self
    let viewItem = NSMenuItem()
    menu.addItem(viewItem)
    let view = NSMenu(title: "View")
    viewItem.submenu = view
    view.addItem(withTitle: "Gallery", action: #selector(showGallery), keyEquivalent: "g").target =
      self
    view.addItem(withTitle: "Full screen", action: #selector(fullscreen), keyEquivalent: "f")
      .target = self
    view.addItem(withTitle: "Keyboard shortcuts", action: #selector(help), keyEquivalent: "/")
      .target = self
    NSApp.mainMenu = menu
  }
  private func buildWindow() {
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1280, height: 850),
      styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false
    )
    window.title = "Mzera"
    window.minSize = NSSize(width: 760, height: 450)
    window.center()
    window.delegate = self
    window.setFrameAutosaveName("MzeraMainWindow")
    let content = FolderDropView()
    content.onDropFolder = { [weak self] url in
      self?.openRoot(url)
      self?.window.makeFirstResponder(self?.render)
    }
    window.contentView = content
    let toolbar = NSStackView()
    toolbar.orientation = .horizontal
    toolbar.spacing = 8
    toolbar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
    func button(_ title: String, _ selector: Selector) -> NSButton {
      NSButton(title: title, target: self, action: selector)
    }
    toolbar.addArrangedSubview(button("Open…", #selector(chooseFolder)))
    toolbar.addArrangedSubview(button("Gallery", #selector(showGallery)))
    grouping.target = self
    grouping.action = #selector(changeGrouping)
    grouping.selectedSegment = grouped ? 1 : 0
    toolbar.addArrangedSubview(grouping)
    for order in SortOrder.allCases { sorting.addItem(withTitle: order.title) }
    sorting.selectItem(at: sortOrder.rawValue)
    sorting.target = self
    sorting.action = #selector(changeSort)
    toolbar.addArrangedSubview(sorting)
    filtering.addItems(withTitles: ["All media", "Photos", "Videos"])
    filtering.selectItem(at: filter)
    filtering.target = self
    filtering.action = #selector(changeFilter)
    toolbar.addArrangedSubview(filtering)
    sound.target = self
    sound.action = #selector(toggleSound)
    sound.title = playback.muted ? "Sound off" : "Sound on"
    toolbar.addArrangedSubview(sound)
    pause.target = self
    pause.action = #selector(togglePause)
    toolbar.addArrangedSubview(pause)
    titleField.lineBreakMode = .byTruncatingMiddle
    titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    toolbar.addArrangedSubview(titleField)
    status.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
    status.textColor = .secondaryLabelColor
    status.lineBreakMode = .byTruncatingMiddle
    scroller.target = self
    scroller.action = #selector(scrollbar)
    scroller.scrollerStyle = .legacy
    for view in [toolbar, render!, status, scroller] {
      view.translatesAutoresizingMaskIntoConstraints = false
      content.addSubview(view)
    }
    NSLayoutConstraint.activate([
      toolbar.topAnchor.constraint(equalTo: content.topAnchor),
      toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
      toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
      toolbar.heightAnchor.constraint(equalToConstant: 48),
      render.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
      render.leadingAnchor.constraint(equalTo: content.leadingAnchor),
      render.trailingAnchor.constraint(equalTo: scroller.leadingAnchor),
      render.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -6),
      scroller.widthAnchor.constraint(equalToConstant: 14),
      scroller.trailingAnchor.constraint(equalTo: content.trailingAnchor),
      scroller.topAnchor.constraint(equalTo: render.topAnchor),
      scroller.bottomAnchor.constraint(equalTo: render.bottomAnchor),
      status.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
      status.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
      status.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -7),
      status.heightAnchor.constraint(equalToConstant: 16),
    ])
  }
  private var current: MediaEntry? {
    render.entries.indices.contains(render.selected) ? render.entries[render.selected] : nil
  }
  private var displayLimit: Int {
    if render.zoom != nil { return 8192 }
    let pixels = max(render.bounds.width, render.bounds.height) * (window.backingScaleFactor)
    return pixels > 2560 ? 4096 : 2560
  }
  @objc func chooseFolder() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.beginSheetModal(for: window) { [weak self] result in
      if result == .OK, let url = panel.url { self?.openRoot(url) }
    }
  }
  func openRoot(_ url: URL, restore: Bool = false) {
    sortRunning = false
    rootCatalogReady = false
    sortToken.cancel()
    initialOrderPending = true
    selectionChanged = false
    folderOpenedAt = CACurrentMediaTime()
    firstPreparedMS = nil
    render.firstMediaPresentedTime = nil
    scanToken.cancel()
    scanToken = Cancellation()
    scanID += 1
    sortID += 1
    watcher = nil
    pendingRescan?.cancel()
    playback.stop()
    animationPath = nil
    cache.clear()
    all = []
    render.entries = []
    render.selected = 0
    render.viewer = false
    render.resetViewer()
    render.offset = 0
    if !restore {
      restorePath = nil
      restoreViewer = false
      restoreOffset = 0
    }
    root = url.standardizedFileURL
    render.root = root!.path
    window.title = "Mzera · \(url.lastPathComponent)"
    firstContent = false
    render.rebuild()
    status.stringValue = "Opening \(url.lastPathComponent)…"
    let id = scanID
    let token = scanToken
    let rootPath = root!.path
    catalog.queue.async { [weak self] in
      guard let self, !token.cancelled else { return }
      let cached = self.catalog.load(root: rootPath)
      let cachedOrder = self.catalog.orderKey(root: rootPath)
      DispatchQueue.main.async {
        guard self.scanID == id, !token.cancelled else { return }
        self.rootCatalogReady = true
        if let cached {
          self.all = cached
          self.applyOrder(restoring: true, alreadySorted: cachedOrder == self.currentOrderKey)
        }
        self.startScan(progressive: cached == nil)
        self.watcher = FolderWatcher(path: rootPath) { [weak self] in self?.folderChanged() }
      }
    }
  }
  private func startScan(progressive: Bool) {
    guard let root else { return }
    guard rootCatalogReady else { return }
    if scanRunning {
      rescanAfter = true
      return
    }
    scanRunning = true
    rescanAfter = false
    let token = scanToken
    let id = scanID
    let gate = DispatchSemaphore(value: 3)
    scanner.async { [weak self] in
      guard let self else { return }
      var fresh: [MediaEntry] = []
      let result = Scanner.scan(root: root, cancellation: token) { batch in
        fresh.append(contentsOf: batch)
        if progressive {
          while gate.wait(timeout: .now() + 0.02) != .success { if token.cancelled { return } }
          if token.cancelled {
            gate.signal()
            return
          }
          DispatchQueue.main.async {
            defer { gate.signal() }
            guard self.scanID == id, !token.cancelled else { return }
            self.all.append(contentsOf: batch)
            // During initial discovery use arrival order. Final sort runs once, off-main.
            if !self.render.viewer {
              self.render.entries = self.all
              self.render.grouped = false
              self.render.rebuild()
            }
            self.updateStatus()
          }
        }
      }
      guard !token.cancelled else {
        DispatchQueue.main.async {
          self.scanRunning = false
          if self.scanID != id { self.startScan(progressive: self.all.isEmpty) }
        }
        return
      }
      let snapshot = fresh
      DispatchQueue.main.async {
        guard self.scanID == id else {
          self.scanRunning = false
          self.startScan(progressive: self.all.isEmpty)
          return
        }
        self.scanRunning = false
        self.all = snapshot
        self.applyOrder(restoring: true)
        if result.errors > 0 {
          self.status.stringValue = "\(result.count) media · \(result.errors) unreadable entries"
        }
        if self.rescanAfter { self.startScan(progressive: false) }
      }
    }
  }
  private var currentOrderKey: String { "\(sortOrder.rawValue)|\(grouped ? 1 : 0)" }
  private func applyOrder(restoring: Bool = false, alreadySorted: Bool = false) {
    sortRunning = true
    updateStatus()
    sortToken.cancel()
    let token = Cancellation()
    sortToken = token
    sortID += 1
    let id = sortID
    let scan = scanID
    let snapshot = all
    let order = sortOrder
    let grouped = grouped
    let filter = filter
    let orderKey = currentOrderKey
    let rootPath = root?.path
    sorter.async { [weak self] in
      guard !token.cancelled else { return }
      let ordered = alreadySorted ? snapshot : order.sorted(snapshot, grouped: grouped)
      let entries =
        filter == 0 ? ordered : ordered.filter { filter == 2 ? $0.isVideo : (!$0.isVideo) }
      guard !token.cancelled else { return }
      if !alreadySorted, let self, let rootPath {
        self.catalog.queue.async {
          guard !token.cancelled else { return }
          self.catalog.save(root: rootPath, entries: ordered, orderKey: orderKey)
        }
      }
      DispatchQueue.main.async {
        guard let self, self.sortID == id, self.scanID == scan else { return }
        self.sortRunning = false
        let selected =
          self.restorePath
          ?? ((self.selectionChanged || !self.initialOrderPending) ? self.current?.path : nil)
        self.initialOrderPending = false
        self.render.entries = entries
        self.render.grouped = grouped
        self.render.selected = selected.flatMap { p in entries.firstIndex { $0.path == p } } ?? 0
        self.render.rebuild()
        if restoring, self.restorePath != nil {
          self.render.offset = self.restoreOffset
          self.render.rebuild()
          if self.restoreViewer && !entries.isEmpty { self.openViewer(self.render.selected) }
          self.restorePath = nil
          self.restoreViewer = false
        } else if self.render.viewer {
          if entries.isEmpty { self.showGallery() } else { self.openViewer(self.render.selected) }
        } else {
          self.render.scrollToSelected()
        }
        self.updateStatus()
        self.refreshRequests()
        self.scheduleSave()
      }
    }
  }
  private func refreshRequests() {
    guard render != nil, cache != nil else { return }
    var requests: [MediaCache.Request] = []
    if render.viewer, let current {
      if !current.isVideo {
        requests.append(.init(entry: current, limit: displayLimit, urgent: true))
        requests.append(.init(entry: current, limit: 512, urgent: true))
        for step in [1, 2, 3, 4, 5, 6, 7, 8, -1, -2, -3] {
          let i = render.selected + step
          if render.entries.indices.contains(i), !render.entries[i].isVideo {
            requests.append(
              .init(
                entry: render.entries[i], limit: render.zoom == nil ? displayLimit : 2560,
                urgent: false))
          }
        }
      }
    } else {
      let visible = render.layout.visible(offset: render.offset, height: render.bounds.height)
      requests = visible.map { .init(entry: render.entries[$0], limit: 512, urgent: true) }
      let wanted = Set(visible)
      for i in render.layout.visible(
        offset: render.offset, height: render.bounds.height, overscan: render.bounds.height * 0.5)
      where !wanted.contains(i) {
        requests.append(.init(entry: render.entries[i], limit: 512, urgent: false))
      }
    }
    cache.request(requests)
    if render.viewer { showPrepared() }
  }
  func openViewer(_ index: Int) {
    guard render.entries.indices.contains(index) else { return }
    playback.stop()
    animationPath = nil
    loadError = nil
    render.viewer = true
    render.selected = index
    render.resetViewer()
    let entry = render.entries[index]
    titleField.toolTip = nil
    if entry.isVideo { playback.startVideo(path: entry.path) } else { showPrepared() }
    pause.title = "Pause"
    refreshRequests()
    updateScroller()
    updateStatus()
    scheduleSave()
    render.setAccessibilityLabel("Viewing \(entry.name)")
  }
  private func showPrepared() {
    guard render.viewer, let entry = current, !entry.isVideo else { return }
    if let image = cache.get(entry, limit: displayLimit) ?? cache.get(entry, limit: 512) {
      render.photo = image
      render.needsDisplay = true
      markFirstContent()
      if image.animated, animationPath != entry.path {
        animationPath = entry.path
        playback.startAnimation(path: entry.path, limit: displayLimit, device: render.device!)
      }
    } else if cache.isFailed(entry, limit: displayLimit) {
      loadError = "Unsupported or damaged image"
      updateStatus()
    }
  }
  @objc func showGallery() {
    playback.stop()
    animationPath = nil
    loadError = nil
    render.viewer = false
    render.resetViewer()
    render.scrollToSelected()
    refreshRequests()
    updateScroller()
    updateStatus()
    scheduleSave()
    render.setAccessibilityLabel("Photo gallery")
  }
  private func key(_ event: NSEvent) -> Bool {
    let command = event.modifierFlags.contains(.command)
    switch event.keyCode {
    case 53:
      if render.viewer {
        showGallery()
      } else if window.styleMask.contains(.fullScreen) {
        fullscreen()
      }
      return true
    case 36:
      if !render.viewer { openViewer(render.selected) }
      return true
    case 49:
      if render.viewer && (current?.isVideo == true || animationPath != nil) {
        togglePause()
      } else if !render.viewer {
        openViewer(render.selected)
      } else {
        move(1)
      }
      return true
    case 123:
      if command && render.viewer && current?.isVideo == true {
        playback.seek(by: -5)
      } else {
        move(-1)
      }
      return true
    case 124:
      if command && render.viewer && current?.isVideo == true {
        playback.seek(by: 5)
      } else {
        move(1)
      }
      return true
    case 125:
      move(render.viewer ? 1 : render.layout.columns)
      return true
    case 126:
      move(render.viewer ? -1 : (-render.layout.columns))
      return true
    case 115:
      selectBoundary(0)
      return true
    case 119:
      selectBoundary(render.entries.count - 1)
      return true
    case 116:
      move(-(max(1, Int(render.bounds.height / render.layout.stride)) * render.layout.columns))
      return true
    case 121:
      move(max(1, Int(render.bounds.height / render.layout.stride)) * render.layout.columns)
      return true
    default: break
    }
    if event.charactersIgnoringModifiers == "f" {
      fullscreen()
      return true
    }
    if event.charactersIgnoringModifiers == "m" {
      toggleSound()
      return true
    }
    if event.charactersIgnoringModifiers == "1" {
      render.zoom = 1 / window.backingScaleFactor
      render.pan = .zero
      refreshRequests()
      render.needsDisplay = true
      return true
    }
    if event.charactersIgnoringModifiers == "0" {
      render.zoom = nil
      render.pan = .zero
      refreshRequests()
      render.needsDisplay = true
      return true
    }
    if event.charactersIgnoringModifiers == "+" || event.charactersIgnoringModifiers == "=" {
      render.tile = min(300, render.tile + 20)
      render.rebuild()
      return true
    }
    if event.charactersIgnoringModifiers == "-" {
      render.tile = max(90, render.tile - 20)
      render.rebuild()
      return true
    }
    return false
  }
  private func move(_ delta: Int) { selectBoundary(render.selected + delta) }
  private func selectBoundary(_ index: Int) {
    selectionChanged = true
    guard !render.entries.isEmpty else { return }
    let index = max(0, min(render.entries.count - 1, index))
    if render.viewer, index != render.selected {
      render.markPreparedInput(cache.get(render.entries[index], limit: displayLimit) != nil)
    }
    if render.viewer {
      if index != render.selected { openViewer(index) }
    } else {
      render.selected = index
      render.scrollToSelected()
      updateStatus()
      scheduleSave()
    }
    render.interact()
  }
  @objc private func changeGrouping() {
    grouped = grouping.selectedSegment == 1
    applyOrder()
    window.makeFirstResponder(render)
  }
  @objc private func changeSort() {
    sortOrder = SortOrder(rawValue: sorting.indexOfSelectedItem) ?? .path
    applyOrder()
    window.makeFirstResponder(render)
  }
  @objc private func changeFilter() {
    filter = filtering.indexOfSelectedItem
    applyOrder()
    window.makeFirstResponder(render)
  }
  @objc private func toggleSound() {
    playback.muted.toggle()
    sound.title = playback.muted ? "Sound off" : "Sound on"
    scheduleSave()
    window.makeFirstResponder(render)
  }
  @objc private func togglePause() {
    playback.togglePause()
    pause.title = playback.paused ? "Play" : "Pause"
    window.makeFirstResponder(render)
  }
  @objc private func fullscreen() { window.toggleFullScreen(nil) }
  @objc private func rescan() { startScan(progressive: false) }
  private func folderChanged() {
    pendingRescan?.cancel()
    let task = DispatchWorkItem { [weak self] in self?.rescan() }
    pendingRescan = task
    DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: task)
  }
  @objc private func scrollbar() {
    let maxOffset = max(0, render.layout.height - render.bounds.height)
    switch scroller.hitPart {
    case .decrementPage: render.offset = max(0, render.offset - render.bounds.height)
    case .incrementPage: render.offset = min(maxOffset, render.offset + render.bounds.height)
    default: render.offset = scroller.doubleValue * maxOffset
    }
    render.needsDisplay = true
    refreshRequests()
    updateScroller()
    scheduleSave()
  }
  private func updateScroller() {
    scroller.isHidden = render.viewer
    scroller.isEnabled = !render.viewer && render.layout.height > render.bounds.height
    scroller.knobProportion = min(1, render.bounds.height / max(1, render.layout.height))
    scroller.doubleValue = render.offset / max(1, render.layout.height - render.bounds.height)
  }
  private func updateStatus() {
    guard cache != nil else { return }
    titleField.stringValue = current?.name ?? ""
    let count = render.entries.count
    let mode = scanRunning ? "Scanning…" : (sortRunning ? "Sorting…" : "\(count.formatted()) files")
    let diagnostics = CommandLine.arguments.contains("--metrics") ? " · \(cache.stats)" : ""
    status.stringValue =
      "\(loadError.map{$0+" · "} ?? "")\(mode) · \(count==0 ? 0:render.selected+1)/\(count)\(diagnostics)"
    sound.isEnabled = true
    pause.isEnabled = render.viewer && (current?.isVideo == true || animationPath != nil)
  }
  private func markFirstContent() {
    guard !firstContent else { return }
    firstContent = true
    firstPreparedMS = (CACurrentMediaTime() - folderOpenedAt) * 1000
    NSLog("Mzera first prepared content: %.1f ms since folder open", firstPreparedMS!)
  }
  private func writeMetrics() {
    guard let i = CommandLine.arguments.firstIndex(of: "--metrics"),
      CommandLine.arguments.count > i + 1
    else { return }
    let samples = render.presentationSamples.sorted()
    func percentile(_ p: Double) -> Double {
      samples.isEmpty ? 0 : samples[min(samples.count - 1, Int(Double(samples.count - 1) * p))]
    }
    let data: [String: Any] = [
      "entries": render.entries.count, "selected": render.selected, "viewer": render.viewer,
      "cacheBytes": cache.photos.cost + cache.thumbnails.cost, "peakDecodeJobs": cache.peakJobs,
      "queuedDecodeJobs": cache.queuedCount,
      "preparedNavigationSamples": samples.count, "handlerToPresentP50ms": percentile(0.5),
      "handlerToPresentP95ms": percentile(0.95),
      "lastCPUdrawMS": render.lastDrawMilliseconds, "frames": render.renderedFrames,
      "scanRunning": scanRunning,
      "displayMaximumFPS": window.screen?.maximumFramesPerSecond ?? 0,
      "folderOpenToFirstPreparedMS": firstPreparedMS ?? -1,
      "folderOpenToFirstPresentedMS": render.firstMediaPresentedTime.map {
        ($0 - folderOpenedAt) * 1000
      } ?? -1,
    ]
    let url = URL(fileURLWithPath: CommandLine.arguments[i + 1])
    if let json = try? JSONSerialization.data(
      withJSONObject: data, options: [.prettyPrinted, .sortedKeys])
    {
      try? json.write(to: url, options: .atomic)
    }
  }
  private func scheduleSave() {
    pendingSave?.cancel()
    let task = DispatchWorkItem { [weak self] in self?.save() }
    pendingSave = task
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: task)
  }
  private func save() {
    guard let root else { return }
    let d = UserDefaults.standard
    d.set(root.path, forKey: "root")
    d.set(current?.path, forKey: "selectedPath")
    d.set(render.viewer, forKey: "viewer")
    d.set(render.offset, forKey: "offset")
    d.set(grouped, forKey: "grouped")
    d.set(sortOrder.rawValue, forKey: "sort")
    d.set(filter, forKey: "filter")
    d.set(Int(render.tile), forKey: "tile")
    d.set(!playback.muted, forKey: "sound")
  }
  @objc private func settings() {
    if let settingsWindow {
      settingsWindow.makeKeyAndOrderFront(nil)
      return
    }
    let panel = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 420, height: 200), styleMask: [.titled, .closable],
      backing: .buffered, defer: false)
    panel.title = "Mzera settings"
    panel.isReleasedWhenClosed = false
    settingsWindow = panel
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 14
    stack.frame = NSRect(x: 20, y: 20, width: 380, height: 160)
    stack.addArrangedSubview(NSTextField(labelWithString: "Photo cache in memory (MB)"))
    let memory = NSSlider(
      value: Double(cache.photos.limit / 1_048_576), minValue: 128, maxValue: 3072, target: self,
      action: #selector(memoryBudget(_:)))
    stack.addArrangedSubview(memory)
    memory.widthAnchor.constraint(equalToConstant: 370).isActive = true
    stack.addArrangedSubview(
      NSTextField(
        wrappingLabelWithString:
          "Thumbnail cache: 384 MB. Disk cache: 30 GB.\nMemory pressure automatically reduces RAM use.\nArrow keys follow the latest requested position."
      ))
    panel.contentView?.addSubview(stack)
    panel.center()
    panel.makeKeyAndOrderFront(nil)
  }
  @objc private func memoryBudget(_ slider: NSSlider) {
    let value = Int(slider.doubleValue)
    cache.photos.limit = value * 1_048_576
    UserDefaults.standard.set(value, forKey: "photoCacheMiB")
  }
  @objc private func help() {
    alert(
      "Keyboard shortcuts",
      "Enter: open image\nEsc / ⌘G: gallery\nArrows: browse\nHome / End, Page Up / Down: jump\nF / ⌘F: full screen\n1: actual pixels · 0: fit\nPinch / ⌘wheel: zoom · drag: pan\n+ / -: thumbnail size\nSpace: pause animation/video\nM: mute · ⌘← / ⌘→: seek video\n⌘O: open folder · ⌘R: refresh"
    )
  }
  @objc private func about() {
    alert(
      "Mzera for Mac",
      "Native local photo and video viewer.\nSwift · AppKit · Metal · Image I/O · FFmpeg\nApple Silicon, macOS 26 or later."
    )
  }
  private func alert(_ title: String, _ text: String) {
    let a = NSAlert()
    a.messageText = title
    a.informativeText = text
    a.beginSheetModal(for: window)
  }
  private func fatal(_ text: String) {
    let a = NSAlert()
    a.messageText = text
    a.runModal()
    NSApp.terminate(nil)
  }
  func windowWillClose(_ notification: Notification) {
    if (notification.object as? NSWindow) === window {
      save()
      NSApp.terminate(nil)
    }
  }
  func applicationWillTerminate(_ notification: Notification) {
    save()
    scanToken.cancel()
    playback.stop()
    watcher = nil
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
