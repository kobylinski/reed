import AppKit

/// Renders Lucide line icons (stroked SVG paths) into template `NSImage`s.
/// Lucide's canvas is 24×24, stroke-width 2, round caps/joins.
enum LucideIcons {
    struct Glyph {
        let paths: [String]
        let circles: [(CGFloat, CGFloat, CGFloat)]                 // cx, cy, r
        let rects: [(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)] // x, y, w, h, rx
        init(_ paths: [String],
             circles: [(CGFloat, CGFloat, CGFloat)] = [],
             rects: [(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)] = []) {
            self.paths = paths; self.circles = circles; self.rects = rects
        }
    }

    static let audioLines = Glyph(["M2 10v3", "M6 6v11", "M10 3v18", "M14 8v7", "M18 5v13", "M22 10v3"])
    static let stepBack = Glyph(["M13.971 4.285A2 2 0 0 1 17 6v12a2 2 0 0 1-3.029 1.715l-9.997-5.998a2 2 0 0 1-.003-3.432z", "M21 20V4"])
    static let stepForward = Glyph(["M10.029 4.285A2 2 0 0 0 7 6v12a2 2 0 0 0 3.029 1.715l9.997-5.998a2 2 0 0 0 .003-3.432z", "M3 4v16"])
    static let shuffle = Glyph(["m18 14 4 4-4 4", "m18 2 4 4-4 4", "M2 18h1.973a4 4 0 0 0 3.3-1.7l5.454-8.6a4 4 0 0 1 3.3-1.7H22", "M2 6h1.972a4 4 0 0 1 3.6 2.2", "M22 18h-6.041a4 4 0 0 1-3.3-1.8l-.359-.45"])
    static let play = Glyph(["M5 5a2 2 0 0 1 3.008-1.728l11.997 6.998a2 2 0 0 1 .003 3.458l-12 7A2 2 0 0 1 5 19z"])
    static let playOff = Glyph(["m10.215 4.56 9.79 5.71a2 2 0 0 1 .003 3.458l-.393.23", "m16.042 16.042-8.034 4.686A2 2 0 0 1 5 19V5", "m2 2 20 20"])
    static let gitBranch = Glyph(["M15 6a9 9 0 0 0-9 9V3"], circles: [(18, 6, 3), (6, 18, 3)])
    static let heart = Glyph(["M2 9.5a5.5 5.5 0 0 1 9.591-3.676.56.56 0 0 0 .818 0A5.49 5.49 0 0 1 22 9.5c0 2.29-1.5 4-3 5.5l-5.492 5.313a2 2 0 0 1-3 .019L5 15c-1.5-1.5-3-3.2-3-5.5"])
    static let logOut = Glyph(["m16 17 5-5-5-5", "M21 12H9", "M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4"])
    static let pause = Glyph([], rects: [(14, 3, 5, 18, 1), (5, 3, 5, 18, 1)])
    static let repeatIcon = Glyph(["m17 2 4 4-4 4", "M3 11v-1a4 4 0 0 1 4-4h14", "m7 22-4-4 4-4", "M21 13v1a4 4 0 0 1-4 4H3"])
    static let split = Glyph(["M16 3h5v5", "M8 3H3v5", "M12 22v-8.3a4 4 0 0 0-1.172-2.872L3 3", "m15 9 6-6"])

    /// `filled` solidifies the glyph (for "liked" hearts); otherwise it's stroked.
    static func image(_ glyph: Glyph, size: CGFloat, lineWidth: CGFloat = 2, filled: Bool = false) -> NSImage {
        let path = NSBezierPath()
        for d in glyph.paths { SVGPath.append(d, to: path) }
        for c in glyph.circles {
            path.appendOval(in: NSRect(x: c.0 - c.2, y: c.1 - c.2, width: c.2 * 2, height: c.2 * 2))
        }
        for r in glyph.rects {
            path.append(NSBezierPath(roundedRect: NSRect(x: r.0, y: r.1, width: r.2, height: r.3),
                                     xRadius: r.4, yRadius: r.4))
        }
        path.lineCapStyle = .round
        path.lineJoinStyle = .round

        // `flipped: true` gives a top-left, y-down context matching SVG; scale 24→size.
        let s = size / 24.0
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            NSGraphicsContext.current?.cgContext.scaleBy(x: s, y: s)
            path.lineWidth = lineWidth
            NSColor.black.setStroke()
            if filled { NSColor.black.setFill(); path.fill() }
            path.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// Minimal SVG path-data parser (M/L/H/V/C/A + relatives + Z), appending into an
/// `NSBezierPath` in SVG (y-down) coordinates. Elliptical arcs are converted to
/// cubic béziers.
enum SVGPath {
    static func append(_ d: String, to path: NSBezierPath) {
        var scanner = Scanner(Array(d))
        var cp = CGPoint.zero          // current point
        var start = CGPoint.zero       // subpath start (for Z)
        var cmd: Character = " "

        while scanner.skipSeparators(), let c = scanner.peek() {
            if isCommand(c) { cmd = scanner.next()! }
            let rel = cmd.isLowercase

            switch Character(cmd.uppercased()) {
            case "M":
                cp = scanner.point(rel: rel, cp: cp); start = cp
                path.move(to: cp)
                cmd = rel ? "l" : "L"          // implicit follow-ups are lineto
            case "L":
                cp = scanner.point(rel: rel, cp: cp); path.line(to: cp)
            case "H":
                let x = scanner.number() ?? cp.x
                cp = CGPoint(x: rel ? cp.x + x : x, y: cp.y); path.line(to: cp)
            case "V":
                let y = scanner.number() ?? cp.y
                cp = CGPoint(x: cp.x, y: rel ? cp.y + y : y); path.line(to: cp)
            case "C":
                let c1 = scanner.point(rel: rel, cp: cp)
                let c2 = scanner.point(rel: rel, cp: cp)
                let e = scanner.point(rel: rel, cp: cp)
                path.curve(to: e, controlPoint1: c1, controlPoint2: c2); cp = e
            case "A":
                let rx = scanner.number() ?? 0, ry = scanner.number() ?? 0
                let rot = scanner.number() ?? 0
                let large = scanner.flag(), sweep = scanner.flag()
                let e = scanner.point(rel: rel, cp: cp)
                appendArc(to: path, from: cp, rx: rx, ry: ry, rotDeg: rot, large: large, sweep: sweep, to: e)
                cp = e
            case "Z":
                path.close(); cp = start
            default:
                _ = scanner.next()             // skip the unknown token
            }
        }
    }

    private static func isCommand(_ c: Character) -> Bool {
        "MLHVCSQTAZmlhvcsqtaz".contains(c)
    }

    /// Standard SVG elliptical-arc → cubic-bézier conversion (spec F.6.5).
    private static func appendArc(to path: NSBezierPath, from p0: CGPoint, rx: CGFloat, ry: CGFloat,
                                  rotDeg: CGFloat, large: Bool, sweep: Bool, to p1: CGPoint) {
        guard rx != 0, ry != 0 else { path.line(to: p1); return }
        let phi = rotDeg * .pi / 180
        let cosP = cos(phi), sinP = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1p = cosP * dx + sinP * dy
        let y1p = -sinP * dx + cosP * dy
        var rxa = abs(rx), rya = abs(ry)
        let lambda = (x1p * x1p) / (rxa * rxa) + (y1p * y1p) / (rya * rya)
        if lambda > 1 { let f = sqrt(lambda); rxa *= f; rya *= f }

        let sign: CGFloat = (large != sweep) ? 1 : -1
        let num = rxa * rxa * rya * rya - rxa * rxa * y1p * y1p - rya * rya * x1p * x1p
        let den = rxa * rxa * y1p * y1p + rya * rya * x1p * x1p
        let coef = sign * sqrt(max(0, num / den))
        let cxp = coef * (rxa * y1p / rya)
        let cyp = coef * (-rya * x1p / rxa)
        let cx = cosP * cxp - sinP * cyp + (p0.x + p1.x) / 2
        let cy = sinP * cxp + cosP * cyp + (p0.y + p1.y) / 2

        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let dot = ux * vx + uy * vy
            let len = (ux * ux + uy * uy).squareRoot() * (vx * vx + vy * vy).squareRoot()
            var a = acos(max(-1, min(1, dot / len)))
            if ux * vy - uy * vx < 0 { a = -a }
            return a
        }
        let ux = (x1p - cxp) / rxa, uy = (y1p - cyp) / rya
        let vx = (-x1p - cxp) / rxa, vy = (-y1p - cyp) / rya
        let theta1 = angle(1, 0, ux, uy)
        var dtheta = angle(ux, uy, vx, vy)
        if !sweep, dtheta > 0 { dtheta -= 2 * .pi }
        if sweep, dtheta < 0 { dtheta += 2 * .pi }

        let segments = max(1, Int(ceil(abs(dtheta) / (.pi / 2))))
        let delta = dtheta / CGFloat(segments)
        let t = (4.0 / 3.0) * tan(delta / 4)
        var theta = theta1
        var prev = p0

        func point(_ a: CGFloat) -> CGPoint {
            CGPoint(x: cx + rxa * cos(a) * cosP - rya * sin(a) * sinP,
                    y: cy + rxa * cos(a) * sinP + rya * sin(a) * cosP)
        }
        func derivative(_ a: CGFloat) -> CGPoint {
            CGPoint(x: -rxa * sin(a) * cosP - rya * cos(a) * sinP,
                    y: -rxa * sin(a) * sinP + rya * cos(a) * cosP)
        }
        for _ in 0..<segments {
            let next = theta + delta
            let e = point(next)
            let d1 = derivative(theta), d2 = derivative(next)
            let c1 = CGPoint(x: prev.x + t * d1.x, y: prev.y + t * d1.y)
            let c2 = CGPoint(x: e.x - t * d2.x, y: e.y - t * d2.y)
            path.curve(to: e, controlPoint1: c1, controlPoint2: c2)
            prev = e; theta = next
        }
    }

    /// Character scanner for path data.
    private struct Scanner {
        private let chars: [Character]
        private var i = 0
        init(_ chars: [Character]) { self.chars = chars }

        func peek() -> Character? { i < chars.count ? chars[i] : nil }
        mutating func next() -> Character? { defer { i += 1 }; return peek() }

        @discardableResult
        mutating func skipSeparators() -> Bool {
            while let c = peek(), c == " " || c == "," || c == "\n" || c == "\t" || c == "\r" { i += 1 }
            return i < chars.count
        }

        mutating func number() -> CGFloat? {
            skipSeparators()
            var s = ""
            if let c = peek(), c == "-" || c == "+" { s.append(c); i += 1 }
            var hasDigits = false
            while let c = peek(), c.isNumber { s.append(c); i += 1; hasDigits = true }
            if let c = peek(), c == "." {
                s.append(c); i += 1
                while let d = peek(), d.isNumber { s.append(d); i += 1; hasDigits = true }
            }
            if let c = peek(), c == "e" || c == "E" {
                s.append(c); i += 1
                if let sgn = peek(), sgn == "-" || sgn == "+" { s.append(sgn); i += 1 }
                while let d = peek(), d.isNumber { s.append(d); i += 1 }
            }
            guard hasDigits, let value = Double(s) else { return nil }
            return CGFloat(value)
        }

        mutating func flag() -> Bool {
            skipSeparators()
            if let c = peek(), c == "0" || c == "1" { i += 1; return c == "1" }
            return false
        }

        mutating func point(rel: Bool, cp: CGPoint) -> CGPoint {
            let x = number() ?? 0, y = number() ?? 0
            return rel ? CGPoint(x: cp.x + x, y: cp.y + y) : CGPoint(x: x, y: y)
        }
    }
}
