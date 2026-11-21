import AppKit
import MiraSupervisorCore

/// The Mira sparks (a large and a small four-point star) as a menu-bar template image.
/// Same geometry as the app icon and the web favicon (viewBox 98..414).
enum Sparks {
    /// Cubic segments, one star each: tip, then (control1, control2, next tip) four times.
    private static let stars: [[(CGFloat, CGFloat)]] = [
        [(256, 98),
         (258, 216), (296, 254), (414, 256),
         (296, 258), (258, 296), (256, 414),
         (254, 296), (216, 258), (98, 256),
         (216, 254), (254, 216), (256, 98)],
        [(362, 292),
         (362.5, 320.4), (371.6, 329.5), (400, 330),
         (371.6, 330.5), (362.5, 339.6), (362, 368),
         (361.5, 339.6), (352.4, 330.5), (324, 330),
         (352.4, 329.5), (361.5, 320.4), (362, 292)],
    ]

    static func image(alpha: CGFloat, side: CGFloat = 18) -> NSImage {
        let scale = side / 316
        let img = NSImage(size: NSSize(width: side, height: side), flipped: true) { _ in
            func pt(_ p: (CGFloat, CGFloat)) -> NSPoint { NSPoint(x: (p.0 - 98) * scale, y: (p.1 - 98) * scale) }
            NSColor.black.withAlphaComponent(alpha).setFill()
            for s in stars {
                let path = NSBezierPath()
                path.move(to: pt(s[0]))
                var i = 1
                while i + 2 < s.count {
                    path.curve(to: pt(s[i + 2]), controlPoint1: pt(s[i]), controlPoint2: pt(s[i + 1]))
                    i += 3
                }
                path.close()
                path.fill()
            }
            return true
        }
        img.isTemplate = true
        return img
    }

    /// Dim when the model is not serving right now, full when it is.
    static func alpha(for kind: MenuStatus.Kind) -> CGFloat {
        switch kind {
        case .ready: return 1
        case .starting, .loadingModel, .waking, .settingUp, .stopping: return 0.7
        case .asleep: return 0.5
        case .needsSetup, .stopped, .failed: return 0.35
        }
    }
}
