import AppKit
import Metal

final class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate {
  var window: ViewerWindow!
  var render: RenderView!
  private var cache: MediaCache!
  private var catalog: Catalog!
  private let playback = Playback()
  private var all: [MediaEntry] = []
  private var allOrderKey: String?
  private var refreshScheduled = false
  private var root: URL?
  private var scanToken = Cancellation()
  private var sortToken = Cancellation()
  private var rootCatalogReady = false
  private var watcher: FolderWatcher?
  private var scanRunning = false
  private var sortRunning = false
  private var rescanAfter = false
  private var pendingChanges = Set<FolderWatcher.Change>()
  private var requiresFullScan = false
  private var scanID = 0, sortID = 0
  private var completedSortCount = 0, unchangedScanCount = 0
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
  private let videoControls = VideoControlsView()
  private let toolbar = NSStackView()
  private var windowedRenderConstraints: [NSLayoutConstraint] = []
  private var fullscreenRenderConstraints: [NSLayoutConstraint] = []
  private var panelsHidden = false
  private var statsTimer: Timer?
  private var loadError: String?
  private var firstContent = false
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
    cache.setPhotoBudget(savedRAM * 1_048_576)
    playback.muted = !defaults.bool(forKey: "sound")
    buildMenu()
    buildWindow()
    render.onViewport = { [weak self] in
      self?.scheduleRefresh()
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
    render.onMouseMoved = { [weak self] in self?.revealVideoControls() }
    render.onMouseExited = { [weak self] in
      guard let self, !self.videoControls.scrubbing else { return }
      self.videoControls.hide()
    }
    videoControls.onTogglePause = { [weak self] in self?.togglePause() }
    videoControls.onToggleSound = { [weak self] in self?.toggleSound() }
    videoControls.onSeek = { [weak self] seconds in self?.playback.seek(to: seconds) }
    videoControls.onIdle = { [weak self] in
      // In full screen the pointer disappears together with the controls.
      if self?.window.isImmersive == true { NSCursor.setHiddenUntilMouseMoves(true) }
    }
    cache.didPrepare = { [weak self] path in
      guard let self else { return }
      self.render.needsDisplay = true
      if self.render.viewer, self.current?.path == path { self.showPrepared() }
      if self.render.viewer, let current = self.current,
        current.path == path, self.cache.failure(current, limit: self.displayLimit) == .budget
      {
        self.refreshRequests()
      }
      self.markFirstContent()
    }
    playback.onVideo = { [weak self] pixel, full, bt601, bt2020, hw, _ in
      guard let self, self.render.viewer else { return }
      guard self.render.showPixel(pixel, fullRange: full, bt601: bt601, bt2020: bt2020) else {
        self.loadError = "Unsupported video pixel format"
        self.updateStatus()
        return
      }
      self.markFirstContent()
      self.titleField.toolTip = hw ? "VideoToolbox frame" : "Software decoder"
      if self.videoControls.shown {
        self.videoControls.update(
          position: self.playback.position, duration: self.playback.duration)
      }
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
    if CommandLine.arguments.contains("--metrics") {
      statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
        self?.updateStatus()
        self?.writeMetrics()
      }
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
    view.addItem(
      withTitle: "Gallery / viewer (G / C)", action: #selector(toggleGallery), keyEquivalent: "g"
    ).target =
      self
    view.addItem(
      withTitle: "Show / hide panels (T)", action: #selector(togglePanels), keyEquivalent: ""
    ).target = self
    view.addItem(
      withTitle: "Full screen without panels (F)", action: #selector(fullscreen), keyEquivalent: "f"
    )
    .target = self
    let standardFullscreen = view.addItem(
      withTitle: "Toggle full screen", action: #selector(fullscreen), keyEquivalent: "f")
    standardFullscreen.target = self
    standardFullscreen.keyEquivalentModifierMask = [.command, .control]
    view.addItem(withTitle: "Keyboard shortcuts (H)", action: #selector(help), keyEquivalent: "/")
      .target = self
    NSApp.mainMenu = menu
  }
  private func buildWindow() {
    window = ViewerWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1280, height: 850),
      styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false
    )
    window.title = "Mzera"
    window.backgroundColor = .black
    window.onToggleFullscreen = { [weak self] in self?.fullscreen() }
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
    toolbar.orientation = .horizontal
    toolbar.spacing = 8
    toolbar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
    func button(_ title: String, _ selector: Selector) -> NSButton {
      NSButton(title: title, target: self, action: selector)
    }
    toolbar.addArrangedSubview(button("Open…", #selector(chooseFolder)))
    toolbar.addArrangedSubview(button("Gallery", #selector(showGallery)))
    toolbar.toolTip = "G: gallery/viewer · T: hide panels · F: full screen · H: all shortcuts"
    let fullscreenButton = button("Full screen", #selector(fullscreen))
    fullscreenButton.toolTip = "F / ⌘F / ⌃⌘F: image only on a black screen. Esc: exit."
    toolbar.addArrangedSubview(fullscreenButton)
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
    sound.toolTip = "V: sound on/off"
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
    for view in [toolbar, render!, status, scroller, videoControls] {
      view.translatesAutoresizingMaskIntoConstraints = false
      content.addSubview(view)
    }
    windowedRenderConstraints = [
      render.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
      render.trailingAnchor.constraint(equalTo: scroller.leadingAnchor),
      render.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -6),
    ]
    fullscreenRenderConstraints = [
      render.topAnchor.constraint(equalTo: content.topAnchor),
      render.trailingAnchor.constraint(equalTo: content.trailingAnchor),
      render.bottomAnchor.constraint(equalTo: content.bottomAnchor),
    ]
    NSLayoutConstraint.activate(
      windowedRenderConstraints + [
        toolbar.topAnchor.constraint(equalTo: content.topAnchor),
        toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
        toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        toolbar.heightAnchor.constraint(equalToConstant: 48),
        render.leadingAnchor.constraint(equalTo: content.leadingAnchor),
        scroller.widthAnchor.constraint(equalToConstant: 14),
        scroller.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        scroller.topAnchor.constraint(equalTo: render.topAnchor),
        scroller.bottomAnchor.constraint(equalTo: render.bottomAnchor),
        status.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
        status.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
        status.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -7),
        status.heightAnchor.constraint(equalToConstant: 16),
      ] + videoControls.constraints(over: render))
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
    if window.isImmersive { setFullscreen(false) }
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
    pendingChanges.removeAll()
    requiresFullScan = false
    pendingRescan?.cancel()
    playback.stop()
    videoControls.available = false
    animationPath = nil
    cache.clear()
    all = []
    allOrderKey = nil
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
      let durations = self.catalog.durations(root: rootPath, entries: cached ?? [])
      DispatchQueue.main.async {
        guard self.scanID == id, !token.cancelled else { return }
        self.rootCatalogReady = true
        self.cache.installDurations(durations)
        if let cached {
          self.all = cached
          self.allOrderKey = cachedOrder
          self.applyOrder(restoring: true, alreadySorted: cachedOrder == self.currentOrderKey)
        }
        self.startScan(progressive: cached == nil)
        self.watcher = FolderWatcher(path: rootPath) { [weak self] changes in
          self?.folderChanged(changes)
        }
      }
    }
  }
  private func startScan(progressive: Bool, changes: Set<FolderWatcher.Change>? = nil) {
    guard let root else { return }
    guard rootCatalogReady else {
      rescanAfter = true
      return
    }
    if scanRunning {
      rescanAfter = true
      if let changes { pendingChanges.formUnion(changes) } else { requiresFullScan = true }
      return
    }
    scanRunning = true
    rescanAfter = false
    let token = scanToken
    let id = scanID
    let previous = all
    let gate = DispatchSemaphore(value: 3)
    scanner.async { [weak self] in
      guard let self else { return }
      var fresh: [MediaEntry] = []
      let collect: ([MediaEntry]) -> Void = { batch in
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
            self.allOrderKey = nil
            // During initial discovery use arrival order. Final sort runs once, off-main.
            if !self.render.viewer {
              let visibleBatch =
                self.filter == 0
                ? batch : batch.filter { self.filter == 2 ? $0.isVideo : !$0.isVideo }
              self.render.entries.append(contentsOf: visibleBatch)
              self.render.grouped = false
              self.render.rebuild()
            }
            self.updateStatus()
          }
        }
      }
      let result: (count: Int, errors: Int)
      if let changes, !changes.isEmpty {
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        let valid = changes.filter { $0.path == root.path || $0.path.hasPrefix(rootPrefix) }
        var replacements: [String: MediaEntry] = [:]
        var errors = 0
        for change in valid {
          let report = Scanner.scan(
            root: URL(fileURLWithPath: change.path), cancellation: token,
            recursive: change.recursive
          ) { batch in
            for entry in batch { replacements[entry.path] = entry }
          }
          errors += report.errors
        }
        // A failed incremental read cannot safely imply deletion; retry the full root.
        if errors > 0 {
          result = Scanner.scan(root: root, cancellation: token, batch: collect)
        } else {
          fresh = previous.filter { entry in
            !valid.contains {
              $0.recursive
                ? entry.path.hasPrefix($0.path.hasSuffix("/") ? $0.path : $0.path + "/")
                : entry.folder == $0.path
            }
          }
          fresh.append(contentsOf: replacements.values)
          result = (fresh.count, 0)
        }
      } else {
        result = Scanner.scan(root: root, cancellation: token, batch: collect)
      }
      guard !token.cancelled else {
        DispatchQueue.main.async {
          self.scanRunning = false
          if self.scanID != id { self.startScan(progressive: self.all.isEmpty) }
        }
        return
      }
      let snapshot = fresh
      let unchanged = !progressive && Scanner.sameContents(previous, snapshot)
      DispatchQueue.main.async {
        guard self.scanID == id else {
          self.scanRunning = false
          self.startScan(progressive: self.all.isEmpty)
          return
        }
        self.scanRunning = false
        if unchanged { self.unchangedScanCount += 1 }
        if unchanged || (result.errors > 0 && !previous.isEmpty) {
          self.updateStatus()
        } else {
          self.all = snapshot
          self.allOrderKey = nil
          self.applyOrder(restoring: true)
        }
        if result.errors > 0 {
          self.status.stringValue = "\(result.count) media · \(result.errors) unreadable entries"
        }
        if self.rescanAfter { self.runPendingScan() }
      }
    }
  }
  private var currentOrderKey: String { "natural-v2|\(sortOrder.rawValue)|\(grouped ? 1 : 0)" }
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
    let canPersist = !scanRunning
    let alreadySorted = alreadySorted || allOrderKey == orderKey
    let width = render.bounds.width
    let tile = render.tile
    sorter.async { [weak self] in
      guard !token.cancelled else { return }
      let ordered = alreadySorted ? snapshot : order.sorted(snapshot, grouped: grouped)
      let entries =
        filter == 0 ? ordered : ordered.filter { filter == 2 ? $0.isVideo : (!$0.isVideo) }
      var layout = GridLayout()
      layout.rebuild(entries: entries, width: width, tile: tile, grouped: grouped)
      let positions = Dictionary(
        uniqueKeysWithValues: entries.enumerated().map { ($0.element.path, $0.offset) })
      guard !token.cancelled else { return }
      if !alreadySorted, canPersist, let self, let rootPath {
        self.catalog.queue.async {
          guard !token.cancelled else { return }
          self.catalog.save(root: rootPath, entries: ordered, orderKey: orderKey)
        }
      }
      DispatchQueue.main.async {
        guard let self, self.sortID == id, self.scanID == scan else { return }
        if !alreadySorted { self.completedSortCount += 1 }
        self.sortRunning = false
        self.all = ordered
        self.allOrderKey = orderKey
        let selected =
          self.restorePath
          ?? ((self.selectionChanged || !self.initialOrderPending) ? self.current?.path : nil)
        self.initialOrderPending = false
        self.render.install(entries: entries, layout: layout, grouped: grouped)
        self.render.selected = selected.flatMap { positions[$0] } ?? 0
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
  private func scheduleRefresh() {
    guard !refreshScheduled else { return }
    refreshScheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.refreshScheduled = false
      self.refreshRequests()
    }
  }
  private func refreshRequests() {
    guard render != nil, cache != nil else { return }
    var requests: [MediaCache.Request] = []
    if render.viewer, let current {
      if !current.isVideo {
        requests.append(.init(entry: current, limit: displayLimit, urgent: true))
        if displayLimit > 2560 && cache.failure(current, limit: displayLimit) == .budget {
          requests.append(.init(entry: current, limit: 2560, urgent: true))
        }
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
      requests = visible.map {
        .init(entry: render.entries[$0], limit: render.thumbnailLimit, urgent: true)
      }
      let wanted = Set(visible)
      for i in render.layout.visible(
        offset: render.offset, height: render.bounds.height, overscan: render.bounds.height * 0.5)
      where !wanted.contains(i) {
        requests.append(
          .init(entry: render.entries[i], limit: render.thumbnailLimit, urgent: false))
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
    videoControls.available = entry.isVideo
    videoControls.update(position: 0, duration: cache.duration(entry) ?? 0)
    videoControls.update(paused: false, muted: playback.muted)
    refreshRequests()
    updateScroller()
    updateStatus()
    scheduleSave()
    render.setAccessibilityLabel("Viewing \(entry.name)")
  }
  private func showPrepared() {
    guard render.viewer, let entry = current, !entry.isVideo else { return }
    if let image = cache.get(entry, limit: displayLimit) ?? cache.get(entry, limit: 2560)
      ?? cache.get(entry, limit: 512)
    {
      loadError = nil
      render.photo = image
      render.needsDisplay = true
      markFirstContent()
      if image.animated, animationPath != entry.path {
        animationPath = entry.path
        playback.startAnimation(path: entry.path, limit: displayLimit, device: render.device!)
      }
    } else if cache.isFailed(entry, limit: displayLimit) {
      loadError =
        cache.failure(entry, limit: displayLimit) == .budget
        ? "Image exceeds the current memory budget" : "Unsupported or damaged image"
      updateStatus()
    }
  }
  @objc func showGallery() {
    if window.isImmersive { setFullscreen(false) }
    playback.stop()
    videoControls.available = false
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
  @objc private func toggleGallery() {
    if render.viewer { showGallery() } else { openViewer(render.selected) }
  }
  @objc private func togglePanels() {
    guard !window.isImmersive else { return }  // Full screen always stays clean.
    panelsHidden.toggle()
    updateChrome()
    window.makeFirstResponder(render)
  }
  private func key(_ event: NSEvent) -> Bool {
    let command = event.modifierFlags.contains(.command)
    let shift = event.modifierFlags.contains(.shift)
    let option = event.modifierFlags.contains(.option)
    let plain = event.modifierFlags.intersection([.command, .control, .option]).isEmpty
    if plain {
      // Physical keys keep working when the input layout is Russian.
      switch event.keyCode {
      case 5, 8:
        toggleGallery()
        return true  // G / C
      case 17:
        togglePanels()
        return true  // T
      case 3:
        fullscreen()
        return true  // F
      case 46:  // M: same grouping toggle as Linux Mzera.
        grouping.selectedSegment = grouped ? 0 : 1
        changeGrouping()
        return true
      case 9:
        toggleSound()
        return true  // V
      case 31:
        chooseFolder()
        return true  // O
      case 4, 44:
        help()
        return true  // H / ?
      case 13:  // W: fit / actual pixels.
        render.zoom = render.zoom == nil ? 1 / window.backingScaleFactor : nil
        render.pan = .zero
        refreshRequests()
        render.needsDisplay = true
        return true
      default: break
      }
    }
    switch event.keyCode {
    case 53:
      if window.isImmersive {
        setFullscreen(false)
      } else if render.viewer {
        showGallery()
      }
      return true
    case 36:
      toggleGallery()
      return true
    case 49:
      if render.viewer && (current?.isVideo == true || animationPath != nil) {
        togglePause()
      } else if !render.viewer {
        openViewer(render.selected)
      } else {
        move(shift ? -1 : 1)
      }
      return true
    case 123:
      if option {
        selectBoundary(0)
      } else if (command || shift) && render.viewer && current?.isVideo == true {
        seekVideo(by: -5)
      } else {
        move(-1)
      }
      return true
    case 124:
      if option {
        selectBoundary(render.entries.count - 1)
      } else if (command || shift) && render.viewer && current?.isVideo == true {
        seekVideo(by: 5)
      } else {
        move(1)
      }
      return true
    case 125:
      if option { movePage(1) } else { move(render.viewer ? 1 : render.layout.columns) }
      return true
    case 126:
      if option { movePage(-1) } else { move(render.viewer ? -1 : (-render.layout.columns)) }
      return true
    case 115:
      selectBoundary(0)
      return true
    case 119:
      selectBoundary(render.entries.count - 1)
      return true
    case 116:
      movePage(-1)
      return true
    case 121:
      movePage(1)
      return true
    default: break
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
      if render.viewer {
        render.magnify(by: 0.2)
        return true
      }
      render.tile = min(300, render.tile + 20)
      render.rebuild()
      return true
    }
    if event.charactersIgnoringModifiers == "-" {
      if render.viewer {
        render.magnify(by: -1.0 / 6)
        return true
      }
      render.tile = max(90, render.tile - 20)
      render.rebuild()
      return true
    }
    return false
  }
  private func seekVideo(by delta: Double) {
    playback.seek(by: delta)
    revealVideoControls()
  }
  private func revealVideoControls() {
    guard videoControls.available else { return }
    let duration = playback.duration > 0 ? playback.duration : current.flatMap(cache.duration)
    videoControls.update(position: playback.position, duration: duration ?? 0)
    videoControls.reveal()
  }
  private func move(_ delta: Int) { selectBoundary(render.selected + delta) }
  private func movePage(_ direction: Int) {
    let step =
      render.viewer
      ? 10 : max(1, Int(render.bounds.height / render.layout.stride)) * render.layout.columns
    move(direction * step)
  }
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
    videoControls.update(paused: playback.paused, muted: playback.muted)
    scheduleSave()
    window.makeFirstResponder(render)
  }
  @objc private func togglePause() {
    playback.togglePause()
    pause.title = playback.paused ? "Play" : "Pause"
    videoControls.update(paused: playback.paused, muted: playback.muted)
    window.makeFirstResponder(render)
  }
  @objc private func fullscreen() {
    if !window.isImmersive, !render.viewer, !render.entries.isEmpty {
      openViewer(render.selected)
    }
    setFullscreen(!window.isImmersive)
  }
  private func setFullscreen(_ enabled: Bool) {
    guard enabled != window.isImmersive else { return }
    window.setImmersive(enabled)
    updateChrome()
    window.makeFirstResponder(render)
  }
  private func updateChrome() {
    let hidden = window.isImmersive || panelsHidden
    NSLayoutConstraint.deactivate(windowedRenderConstraints + fullscreenRenderConstraints)
    toolbar.isHidden = hidden
    status.isHidden = hidden
    scroller.isHidden = hidden || render.viewer
    render.showHeaders = !hidden
    NSLayoutConstraint.activate(hidden ? fullscreenRenderConstraints : windowedRenderConstraints)
    window.contentView?.layoutSubtreeIfNeeded()
    render.rebuild()
    refreshRequests()
  }
  @objc private func rescan() { startScan(progressive: false) }
  private func runPendingScan() {
    let changes = requiresFullScan ? nil : pendingChanges
    pendingChanges.removeAll()
    requiresFullScan = false
    startScan(progressive: false, changes: changes)
  }
  private func folderChanged(_ changes: Set<FolderWatcher.Change>?) {
    if let changes { pendingChanges.formUnion(changes) } else { requiresFullScan = true }
    pendingRescan?.cancel()
    let task = DispatchWorkItem { [weak self] in self?.runPendingScan() }
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
    scroller.isHidden = render.viewer || window.isImmersive || panelsHidden
    scroller.isEnabled = !render.viewer && render.layout.height > render.bounds.height
    scroller.knobProportion = min(1, render.bounds.height / max(1, render.layout.height))
    scroller.doubleValue = render.offset / max(1, render.layout.height - render.bounds.height)
  }
  private func updateStatus() {
    guard cache != nil else { return }
    let title = current?.name ?? ""
    if titleField.stringValue != title { titleField.stringValue = title }
    let count = render.entries.count
    let mode = scanRunning ? "Scanning…" : (sortRunning ? "Sorting…" : "\(count.formatted()) files")
    let diagnostics = CommandLine.arguments.contains("--metrics") ? " · \(cache.stats)" : ""
    let text =
      "\(loadError.map{$0+" · "} ?? "")\(mode) · \(count==0 ? 0:render.selected+1)/\(count)\(diagnostics)"
    if status.stringValue != text { status.stringValue = text }
    let canPause = render.viewer && (current?.isVideo == true || animationPath != nil)
    if pause.isEnabled != canPause { pause.isEnabled = canPause }
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
      "completedSorts": completedSortCount, "unchangedScans": unchangedScanCount,
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
    cache.setPhotoBudget(value * 1_048_576)
    UserDefaults.standard.set(value, forKey: "photoCacheMiB")
  }
  @objc private func help() {
    alert(
      "Keyboard shortcuts",
      "F: full screen, no panels, #000000 background\nEsc: leave full screen; then return to gallery\nG / C / Enter: gallery ↔ viewer\nT: show/hide panels in windowed mode\nM: flat ↔ folders · V: sound on/off\nO: open folder · H / ?: this help\nArrows: browse\nOption ↑/↓: page in grid; ±10 in viewer\nOption ←/→: first/last file\nW: fit ↔ 1:1 · 0: fit · 1: actual pixels\n+ / −: zoom in viewer; thumbnail size in grid\nPinch: zoom · drag: pan\nSpace: pause video/animation; next photo\nShift+Space: previous photo\nShift ←/→: seek video ±5 seconds\nMove the mouse over a video: play/pause, timeline, sound\nLetter shortcuts also work with Russian input."
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
