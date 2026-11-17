import CoreGraphics
import Foundation

@main struct PlacementChecks {
  static func main() {
    let screen = CGRect(x: 0, y: 0, width: 1728, height: 1050)
    let rightOverflow = PopoverPlacement.containedFrame(
      CGRect(x: 1500, y: 550, width: 420, height: 480), in: screen)
    precondition(rightOverflow == CGRect(x: 1300, y: 550, width: 420, height: 480))
    let leftScreen = CGRect(x: -1920, y: -200, width: 1920, height: 1080)
    let negative = PopoverPlacement.containedFrame(
      CGRect(x: -150, y: 900, width: 420, height: 480), in: leftScreen)
    precondition(negative == CGRect(x: -428, y: 392, width: 420, height: 480))
    let oversized = PopoverPlacement.containedFrame(
      CGRect(x: -30, y: -20, width: 2000, height: 2000), in: screen)
    precondition(oversized == CGRect(x: 8, y: 8, width: 1712, height: 1034))
    let fitted = CGRect(x: 80, y: 90, width: 420, height: 480)
    precondition(PopoverPlacement.containedFrame(fitted, in: screen) == fitted)
    precondition(PopoverPlacement.containedFrame(rightOverflow, in: screen) == rightOverflow)
    let bottom = PopoverPlacement.containedFrame(
      CGRect(x: 70, y: -500, width: 420, height: 480), in: screen)
    precondition(bottom.minY == 8)
    print("6 popover containment cases passed")
  }
}
