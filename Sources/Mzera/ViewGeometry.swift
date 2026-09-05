import Foundation

enum ViewGeometry {
  static func clampedPan(_ pan: CGPoint, image: CGSize, viewport: CGSize, scale: Double) -> CGPoint
  {
    let x = max(0, (image.width * scale - viewport.width) / 2)
    let y = max(0, (image.height * scale - viewport.height) / 2)
    return CGPoint(x: min(x, max(-x, pan.x)), y: min(y, max(-y, pan.y)))
  }
  static func zoomedPan(
    _ pan: CGPoint, anchor: CGPoint, viewport: CGSize, oldScale: Double, newScale: Double
  ) -> CGPoint {
    guard oldScale > 0 else { return .zero }
    let ratio = newScale / oldScale
    let x = anchor.x - viewport.width / 2
    let y = anchor.y - viewport.height / 2
    return CGPoint(x: x - (x - pan.x) * ratio, y: y - (y - pan.y) * ratio)
  }
}
