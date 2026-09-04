import AppKit

/// A drag destination on the content root also covers its unregistered children.
/// No overlay, timer or work is added to normal rendering and input handling.
final class FolderDropView: NSView {
  var onDropFolder: ((URL) -> Void)?
  private var candidate: URL?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    registerForDraggedTypes([.fileURL])
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  static func folder(from pasteboard: NSPasteboard) -> URL? {
    guard
      let urls = pasteboard.readObjects(
        forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
      urls.count == 1, let url = urls.first, url.isFileURL,
      let values = try? url.resourceValues(forKeys: [.isDirectoryKey]),
      values.isDirectory == true
    else { return nil }
    return url.standardizedFileURL
  }

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    candidate = Self.folder(from: sender.draggingPasteboard)
    return operation(sender)
  }
  override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    // Cursor movement uses the validated candidate, without repeated filesystem IO.
    operation(sender)
  }
  private func operation(_ sender: NSDraggingInfo) -> NSDragOperation {
    candidate != nil && sender.draggingSourceOperationMask.contains(.copy) ? .copy : []
  }
  override func draggingExited(_ sender: NSDraggingInfo?) { candidate = nil }
  override func draggingEnded(_ sender: NSDraggingInfo) { candidate = nil }
  override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
    operation(sender) == .copy
  }
  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    defer { candidate = nil }
    guard sender.draggingSourceOperationMask.contains(.copy),
      let folder = Self.folder(from: sender.draggingPasteboard), let onDropFolder
    else { return false }
    // Finish the native drag before resetting the existing viewer/scanner state.
    DispatchQueue.main.async { onDropFolder(folder) }
    return true
  }
}
