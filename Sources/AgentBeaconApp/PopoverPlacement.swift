import CoreGraphics
import Foundation

enum PopoverPlacement {
  /// Global screen coordinates can be negative when a display is left of or
  /// below the primary display. Clamp to the anchor display, not the main one.
  static func containedFrame(_ frame: CGRect, in visibleFrame: CGRect, margin: CGFloat = 8)
    -> CGRect
  {
    guard visibleFrame.width > 0, visibleFrame.height > 0 else { return frame }
    let inset = min(max(0, margin), max(0, (min(visibleFrame.width, visibleFrame.height) - 1) / 2))
    let available = visibleFrame.insetBy(dx: inset, dy: inset)
    let width = min(frame.width, available.width)
    let height = min(frame.height, available.height)
    return CGRect(
      x: min(max(frame.minX, available.minX), available.maxX - width),
      y: min(max(frame.minY, available.minY), available.maxY - height),
      width: width, height: height)
  }
}
