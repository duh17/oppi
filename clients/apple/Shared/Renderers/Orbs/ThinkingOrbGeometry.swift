import Foundation

// Adapted from ThinkingOrbs (https://github.com/haplollc/ThinkingOrbs)
// commit e2c07bbdec4db797fb302300ef0159b1806a909f
// Original designs and engine: Jakub Antalik
// Swift port: Haplo LLC
// Voice-driven sash deformation: Oppi adaptation
// MIT License — see ThinkingOrbAttribution and LICENSE in this folder.

/// One finished dot in design-point space (0...size on both axes).
struct ThinkingOrbDot: Equatable, Sendable {
    var x: Double
    var y: Double
    var z: Double
    var r: Double
    var white: Double
    var a: Double = 1
    /// 0 = spinner tint only; 1 = full theme-palette accent.
    var accent: Double = 0
    /// Theme accent slot 0...3 (blue, cyan, purple, orange).
    var palette: Double = 0
}

struct ThinkingOrbFrame: Sendable {
    var dots: [ThinkingOrbDot]
}

enum ThinkingOrbStyle: String, CaseIterable, Sendable {
    case working
    case searching
    case solving
    case composing
    case breathing

    var isVoiceReactive: Bool {
        self == .composing || self == .breathing
    }
}

enum ThinkingOrbSizeClass: Equatable, Sendable {
    /// 18 pt working-row footprint.
    case workingCompact
    /// 20 pt settings preview.
    case workingPreview
    /// 32 pt expanded/ask dictation control.
    case dictationExpanded
    /// 44 pt standard dictation control.
    case dictationStandard

    var designSize: Double {
        switch self {
        case .workingCompact: return 18
        case .workingPreview: return 20
        case .dictationExpanded: return 32
        case .dictationStandard: return 44
        }
    }

    static func working(side: Double) -> Self {
        side <= 18 ? .workingCompact : .workingPreview
    }

    static func dictation(side: Double) -> Self {
        side <= 36 ? .dictationExpanded : .dictationStandard
    }
}

/// Batched CPU geometry for the five shipped orb styles.
enum ThinkingOrbGeometry {
    static func frame(
        style: ThinkingOrbStyle,
        sizeClass: ThinkingOrbSizeClass,
        size: Double,
        geometryTime t: Double,
        audioLevel: Float = 0,
        zSorted: Bool = true
    ) -> ThinkingOrbFrame {
        let safeSize = size.isFinite && size > 0 ? size : sizeClass.designSize
        let safeT = t.isFinite ? t : 0
        let voice = Double(ThinkingOrbAudio.clamp(audioLevel))
        let resolved = ThinkingOrbPresets.resolve(style, sizeClass)
        let built = resolved.build(safeSize, safeT, voice)
        if !zSorted {
            return built
        }
        return finalize(built.dots, rMin: resolved.rMin)
    }

    static func jsRound(_ x: Double) -> Double { (x + 0.5).rounded(.down) }

    static func frac(_ x: Double) -> Double { x - x.rounded(.down) }

    static func lerp(_ a: Double, _ b: Double, _ f: Double) -> Double { a + (b - a) * f }

    static func hashD(_ a: Double, _ b: Double) -> Double {
        let h = sin(a * 12.9898 + b * 78.233) * 43758.5453
        return h - h.rounded(.down)
    }

    static func fibDir(_ i: Int, _ n: Double) -> (Double, Double, Double) {
        let golden = Double.pi * (3 - 5.0.squareRoot())
        let y = 1 - (2 * (Double(i) + 0.5)) / n
        let rad = (1 - y * y).squareRoot()
        let a = Double(i) * golden
        return (rad * cos(a), y, rad * sin(a))
    }

    static func angleDelta(_ a: Double, _ b: Double) -> Double {
        atan2(sin(a - b), cos(a - b))
    }

    static func radiusScale(_ size: Double, _ p: Double) -> Double {
        pow(size / 300, p)
    }

    static func below(_ n: Double) -> Int { n > 0 ? Int(n.rounded(.up)) : 0 }

    static func through(_ n: Double) -> Int { n >= 0 ? Int(n.rounded(.down)) + 1 : 0 }

    struct Projector {
        let st: Double, ct: Double, sy: Double, cyw: Double
        let cx: Double, cy: Double, scale: Double

        init(yaw: Double, tilt: Double, cx: Double, cy: Double, scale: Double) {
            st = sin(tilt)
            ct = cos(tilt)
            sy = sin(yaw)
            cyw = cos(yaw)
            self.cx = cx
            self.cy = cy
            self.scale = scale
        }

        @inline(__always)
        func callAsFunction(_ x: Double, _ y: Double, _ z: Double) -> (Double, Double, Double) {
            let x1 = x * cyw + z * sy
            let z1 = -x * sy + z * cyw
            let y1 = y * ct - z1 * st
            let z2 = y * st + z1 * ct
            return (cx + x1 * scale, cy - y1 * scale, z2)
        }
    }

    static func finalize(_ dots: [ThinkingOrbDot], rMin: Double) -> ThinkingOrbFrame {
        var visible: [(Int, ThinkingOrbDot)] = []
        visible.reserveCapacity(dots.count)
        for (i, var d) in dots.enumerated() where d.a >= 0.02 {
            d.r = max(rMin, d.r)
            visible.append((i, d))
        }
        visible.sort { $0.1.z != $1.1.z ? $0.1.z < $1.1.z : $0.0 < $1.0 }
        return ThinkingOrbFrame(dots: visible.map(\.1))
    }
}

enum ThinkingOrbPresets {
    /// Compact working/searching/solving clock vs original Thinking Orbs rates.
    /// Display cadence stays 60/30 Hz. Solving compact ticks ~1s wall.
    static let workingMotionScale = 0.5

    struct Resolved: Sendable {
        var speed: Double
        var rMin: Double
        fileprivate var build: @Sendable (_ size: Double, _ t: Double, _ voice: Double) -> ThinkingOrbFrame
    }

    static func resolve(_ style: ThinkingOrbStyle, _ sizeClass: ThinkingOrbSizeClass) -> Resolved {
        switch (style, sizeClass) {
        case (.working, .workingCompact), (.working, .workingPreview):
            return orbits(
                speed: 3.9 * workingMotionScale,
                orbitN: 3,
                ghostN: 8,
                particles: 3,
                ghostR: 2.16,
                ghostA: 0.7,
                partR: 2.88,
                partRDepth: 3.84,
                rMin: 0.55
            )
        case (.working, .dictationExpanded), (.working, .dictationStandard):
            return orbits(
                speed: 1.885,
                orbitN: 5,
                ghostN: 10,
                particles: 3,
                ghostR: 1.2,
                ghostA: 0.5,
                partR: 1.6,
                partRDepth: 2.1
            )
        case (.searching, .workingCompact), (.searching, .workingPreview):
            return globe(
                speed: 2.665 * workingMotionScale,
                latRings: 5,
                lonDensity: 10,
                rBase: 1.05,
                rDepth: 2.4,
                rBoost: 1.4,
                scanMul: 4.335,
                dimBase: 0.45
            )
        case (.searching, .dictationExpanded), (.searching, .dictationStandard):
            return globe(
                speed: 2.015,
                latRings: 7,
                lonDensity: 14,
                rBase: 0.85,
                rDepth: 2.0,
                rBoost: 1.2,
                scanMul: 4.08,
                dimBase: 0.45
            )
        case (.solving, .workingCompact), (.solving, .workingPreview):
            return rubik(
                speed: 1.95 * workingMotionScale,
                latRings: 4,
                lonDensity: 8,
                moveCount: 8,
                rBase: 1.14,
                rDepth: 2.6,
                rActive: 0.5,
                slotDur: 1.95 * workingMotionScale
            )
        case (.solving, .dictationExpanded), (.solving, .dictationStandard):
            return rubik(
                speed: 1.82,
                latRings: 6,
                lonDensity: 12,
                moveCount: 10,
                rBase: 0.9,
                rDepth: 2.2,
                rActive: 0.4
            )
        case (.composing, .dictationExpanded):
            return ribbon(
                speed: 2.34,
                lanes: 4,
                segs: 18,
                ghostN: 8,
                rBase: 1.05,
                rDepth: 1.55,
                wobMul: 1,
                faceOn: false
            )
        case (.composing, .dictationStandard):
            return ribbon(
                speed: 2.34,
                lanes: 5,
                segs: 22,
                ghostN: 12,
                rBase: 1.1,
                rDepth: 1.6,
                wobMul: 1,
                faceOn: false
            )
        case (.composing, .workingCompact), (.composing, .workingPreview):
            return ribbon(
                speed: 3.12,
                lanes: 3,
                segs: 14,
                ghostN: 6,
                rBase: 1.15,
                rDepth: 1.7,
                wobMul: 1,
                faceOn: false
            )
        case (.breathing, .dictationExpanded):
            return ribbon(
                speed: 2.8,
                lanes: 4,
                segs: 16,
                ghostN: 0,
                rBase: 1.05,
                rDepth: 1.55,
                wobMul: 0.5,
                faceOn: true
            )
        case (.breathing, .dictationStandard):
            return ribbon(
                speed: 2.8,
                lanes: 5,
                segs: 20,
                ghostN: 0,
                rBase: 1.1,
                rDepth: 1.6,
                wobMul: 0.5,
                faceOn: true
            )
        case (.breathing, .workingCompact), (.breathing, .workingPreview):
            return ribbon(
                speed: 3.24,
                lanes: 3,
                segs: 12,
                ghostN: 0,
                rBase: 1.15,
                rDepth: 1.7,
                wobMul: 0.5,
                faceOn: true
            )
        }
    }

    private static func orbits(
        speed: Double,
        orbitN: Double,
        ghostN: Double,
        particles: Double,
        ghostR: Double,
        ghostA: Double,
        partR: Double,
        partRDepth: Double,
        rMin: Double = 0.3
    ) -> Resolved {
        Resolved(speed: speed, rMin: rMin) { size, t, _ in
            ThinkingOrbBuilders.orbits(
                size,
                t,
                orbitN: orbitN,
                ghostN: ghostN,
                particles: particles,
                ghostR: ghostR,
                ghostA: ghostA,
                partR: partR,
                partRDepth: partRDepth
            )
        }
    }

    private static func globe(
        speed: Double,
        latRings: Double,
        lonDensity: Double,
        rBase: Double,
        rDepth: Double,
        rBoost: Double,
        scanMul: Double,
        dimBase: Double
    ) -> Resolved {
        Resolved(speed: speed, rMin: 0.3) { size, t, _ in
            ThinkingOrbBuilders.globe(
                size,
                t,
                latRings: latRings,
                lonDensity: lonDensity,
                rBase: rBase,
                rDepth: rDepth,
                rBoost: rBoost,
                scanMul: scanMul,
                dimBase: dimBase
            )
        }
    }

    private static func rubik(
        speed: Double,
        latRings: Double,
        lonDensity: Double,
        moveCount: Int,
        rBase: Double,
        rDepth: Double,
        rActive: Double,
        slotDur: Double = 0.42
    ) -> Resolved {
        Resolved(speed: speed, rMin: 0.3) { size, t, _ in
            ThinkingOrbBuilders.rubik(
                size,
                t,
                latRings: latRings,
                lonDensity: lonDensity,
                moveCount: moveCount,
                rBase: rBase,
                rDepth: rDepth,
                rActive: rActive,
                slotDur: slotDur
            )
        }
    }

    private static func ribbon(
        speed: Double,
        lanes: Int,
        segs: Double,
        ghostN: Double,
        rBase: Double,
        rDepth: Double,
        wobMul: Double,
        faceOn: Bool
    ) -> Resolved {
        Resolved(speed: speed, rMin: 0.3) { size, t, voice in
            ThinkingOrbBuilders.ribbon(
                size,
                t,
                voice: voice,
                lanes: lanes,
                segs: segs,
                ghostN: ghostN,
                rBase: rBase,
                rDepth: rDepth,
                wobMul: wobMul,
                faceOn: faceOn
            )
        }
    }
}

private enum ThinkingOrbBuilders {
    static func orbits(
        _ size: Double,
        _ t: Double,
        orbitN: Double,
        ghostN: Double,
        particles: Double,
        ghostR: Double,
        ghostA: Double,
        partR: Double,
        partRDepth: Double
    ) -> ThinkingOrbFrame {
        let cx = size / 2
        let cy = size / 2
        let R = (size / 2) * 0.82
        let pt = ThinkingOrbGeometry.Projector(yaw: t * 0.12, tilt: 0.3, cx: cx, cy: cy, scale: 1)
        let rs = ThinkingOrbGeometry.radiusScale(size, 0.6)
        var dots: [ThinkingOrbDot] = []
        dots.reserveCapacity(
            ThinkingOrbGeometry.below(orbitN)
                * (ThinkingOrbGeometry.below(ghostN) + ThinkingOrbGeometry.below(particles))
        )

        for orb in 0..<ThinkingOrbGeometry.below(orbitN) {
            let h1 = ThinkingOrbGeometry.hashD(Double(orb), 1.7)
            let h2 = ThinkingOrbGeometry.hashD(Double(orb), 5.2)
            let h3 = ThinkingOrbGeometry.hashD(Double(orb), 8.9)
            let ro = R * (0.45 + 0.52 * h1)
            let th = h1 * 2 * Double.pi
            let phi = acos(2 * h2 - 1)
            let nx = sin(phi) * cos(th)
            let ny = cos(phi)
            let nz = sin(phi) * sin(th)
            var ux = -ny
            var uy = nx
            let uz = 0.0
            let ul = max(1e-6, (ux * ux + uy * uy).squareRoot())
            ux /= ul
            uy /= ul
            let vx = ny * uz - nz * uy
            let vy = nz * ux - nx * uz
            let vz = nx * uy - ny * ux
            let speed = (0.25 + 0.55 * h3) * (h3 > 0.5 ? 1 : -1)

            for k in 0..<ThinkingOrbGeometry.below(ghostN) {
                let a = (Double(k) / ghostN) * 2 * Double.pi
                let (px, py, z) = pt(
                    (ux * cos(a) + vx * sin(a)) * ro,
                    (uy * cos(a) + vy * sin(a)) * ro,
                    (uz * cos(a) + vz * sin(a)) * ro
                )
                let depth = (z / ro + 1) / 2
                dots.append(ThinkingOrbDot(
                    x: px, y: py, z: z, r: ghostR * rs, white: 0.72,
                    a: ghostA * (0.4 + 0.6 * depth)
                ))
            }
            for m in 0..<ThinkingOrbGeometry.below(particles) {
                let a = t * speed + (Double(m) / particles) * 2 * Double.pi + h2 * 6
                let (px, py, z) = pt(
                    (ux * cos(a) + vx * sin(a)) * ro,
                    (uy * cos(a) + vy * sin(a)) * ro,
                    (uz * cos(a) + vz * sin(a)) * ro
                )
                let depth = (z / ro + 1) / 2
                dots.append(ThinkingOrbDot(
                    x: px, y: py, z: z,
                    r: (partR + partRDepth * depth) * rs,
                    white: 0.3 - 0.22 * depth,
                    accent: 0.9,
                    palette: Double(orb % 4)
                ))
            }
        }
        return ThinkingOrbFrame(dots: dots)
    }

    static func globe(
        _ size: Double,
        _ t: Double,
        latRings: Double,
        lonDensity: Double,
        rBase: Double,
        rDepth: Double,
        rBoost: Double,
        scanMul: Double,
        dimBase: Double
    ) -> ThinkingOrbFrame {
        let spin = 0.5
        let cx = size / 2
        let cy = size / 2
        let radius = (size / 2) * 0.82
        let tilt = 0.4 + 0.06 * sin(t * 0.35)
        let pt = ThinkingOrbGeometry.Projector(yaw: t * spin, tilt: tilt, cx: cx, cy: cy, scale: radius)
        let scan = t * (spin + (1.7 - spin) * scanMul)
        let rs = ThinkingOrbGeometry.radiusScale(size, 0.6)
        var dots: [ThinkingOrbDot] = []
        for li in 0..<ThinkingOrbGeometry.through(latRings) {
            let lat = -Double.pi / 2 + (Double(li) / latRings) * Double.pi
            let cosLat = cos(lat)
            let sinLat = sin(lat)
            let lonCount = max(1, Int(ThinkingOrbGeometry.jsRound(abs(cosLat) * lonDensity)))
            for lj in 0..<lonCount {
                let lon = (Double(lj) / Double(lonCount)) * 2 * Double.pi
                let (px, py, z) = pt(cosLat * cos(lon), sinLat, cosLat * sin(lon))
                let depth = (z + 1) / 2
                let d = ThinkingOrbGeometry.angleDelta(lon + t * spin, scan)
                let boost = exp(-(d * d) / 0.18) * max(0, z)
                dots.append(ThinkingOrbDot(
                    x: px, y: py, z: z,
                    r: (rBase + rDepth * depth + rBoost * boost) * rs,
                    white: 0.62 - 0.54 * depth,
                    a: dimBase + (1 - dimBase) * min(1, boost),
                    accent: min(1, boost),
                    palette: Double(li % 4)
                ))
            }
        }
        return ThinkingOrbFrame(dots: dots)
    }

    private struct Move {
        let axis: Int
        let lo: Double
        let hi: Double
        let ang: Double
    }

    private static func solveCycle(
        _ time: Double,
        _ count: Int,
        _ slotDur: Double,
        _ rest: Double
    ) -> (amount: [Double], active: Int) {
        let cyc = 2 * Double(count) * slotDur + rest
        var tc = time.truncatingRemainder(dividingBy: cyc)
        if tc < 0 { tc += cyc }
        var amount = [Double](repeating: 0, count: count)
        var active = -1
        if tc < 2 * Double(count) * slotDur {
            let slot = Int((tc / slotDur).rounded(.down))
            let p = (tc - Double(slot) * slotDur) / slotDur
            let cl = min(1, p / 0.7)
            let ep = 1 - pow(1 - cl, 3)
            if slot < count {
                for i in 0..<slot { amount[i] = 1 }
                amount[slot] = ep
                active = slot
            } else {
                let u = 2 * count - 1 - slot
                for i in 0..<u { amount[i] = 1 }
                amount[u] = 1 - ep
                active = u
            }
        }
        return (amount, active)
    }

    private static func makeMoves(_ count: Int) -> [Move] {
        (0..<count).map { i in
            let fi = Double(i)
            let axis = min(2, Int((ThinkingOrbGeometry.hashD(fi, 2.3) * 3).rounded(.down)))
            let lo = -1.0 + 0.5 * min(3, (ThinkingOrbGeometry.hashD(fi, 5.9) * 4).rounded(.down))
            let dir: Double = ThinkingOrbGeometry.hashD(fi, 7.7) < 0.5 ? 1 : -1
            return Move(axis: axis, lo: lo, hi: lo + 0.5, ang: (dir * Double.pi) / 2)
        }
    }

    private struct MovedPoint {
        var x: Double
        var y: Double
        var z: Double
        var inActive: Bool
    }

    private static func applyMoves(
        _ px: Double,
        _ py: Double,
        _ pz: Double,
        _ moves: [Move],
        _ amount: [Double],
        _ active: Int
    ) -> MovedPoint {
        var x = px, y = py, z = pz
        var inActive = false
        for i in 0..<moves.count {
            if amount[i] <= 0 { continue }
            let mv = moves[i]
            let coord = mv.axis == 0 ? x : mv.axis == 1 ? y : z
            if coord < mv.lo || coord >= mv.hi { continue }
            if i == active { inActive = true }
            let a = mv.ang * amount[i]
            let ca = cos(a)
            let sa = sin(a)
            if mv.axis == 0 {
                let y2 = y * ca - z * sa
                z = y * sa + z * ca
                y = y2
            } else if mv.axis == 1 {
                let x2 = x * ca + z * sa
                z = -x * sa + z * ca
                x = x2
            } else {
                let x2 = x * ca - y * sa
                y = x * sa + y * ca
                x = x2
            }
        }
        return MovedPoint(x: x, y: y, z: z, inActive: inActive)
    }

    static func rubik(
        _ size: Double,
        _ t: Double,
        latRings: Double,
        lonDensity: Double,
        moveCount: Int,
        rBase: Double,
        rDepth: Double,
        rActive: Double,
        slotDur: Double
    ) -> ThinkingOrbFrame {
        let cx = size / 2
        let cy = size / 2
        let R = (size / 2) * 0.82
        let pt = ThinkingOrbGeometry.Projector(
            yaw: t * 0.55,
            tilt: 0.35 + 0.1 * sin(t * 0.9),
            cx: cx,
            cy: cy,
            scale: R
        )
        let rs = ThinkingOrbGeometry.radiusScale(size, 0.6)
        let moves = makeMoves(moveCount)
        let sc = solveCycle(t, moveCount, slotDur, 1.2)
        var dots: [ThinkingOrbDot] = []
        for li in 0..<ThinkingOrbGeometry.through(latRings) {
            let lat = -Double.pi / 2 + (Double(li) / latRings) * Double.pi
            let cosLat = cos(lat)
            let sinLat = sin(lat)
            let lonCount = max(1, Int(ThinkingOrbGeometry.jsRound(abs(cosLat) * lonDensity)))
            for lj in 0..<lonCount {
                let lon = (Double(lj) / Double(lonCount)) * 2 * Double.pi
                let moved = applyMoves(
                    cosLat * cos(lon),
                    sinLat,
                    cosLat * sin(lon),
                    moves,
                    sc.amount,
                    sc.active
                )
                let (px, py, zr) = pt(moved.x, moved.y, moved.z)
                let depth = (zr + 1) / 2
                dots.append(ThinkingOrbDot(
                    x: px, y: py, z: zr,
                    r: (rBase + rDepth * depth + (moved.inActive ? rActive : 0)) * rs,
                    white: 0.62 - 0.54 * depth - (moved.inActive ? 0.14 : 0),
                    accent: moved.inActive ? 0.95 : (lj % 4 == 0 ? 0.28 : 0),
                    palette: Double((moved.inActive ? max(sc.active, 0) : li) % 4)
                ))
            }
        }
        return ThinkingOrbFrame(dots: dots)
    }

    static func ribbon(
        _ size: Double,
        _ t: Double,
        voice: Double,
        lanes: Int,
        segs: Double,
        ghostN: Double,
        rBase: Double,
        rDepth: Double,
        wobMul: Double,
        faceOn: Bool
    ) -> ThinkingOrbFrame {
        let cx = size / 2
        let cy = size / 2
        // Leave margin so idle wobble plus voice bends stay inside the circular control.
        let R = (size / 2) * 0.72
        let camTilt = 0.32
        // Slow yaw/tilt on the camera and sash. A zero spin froze both, and a
        // face-on circle rotating in-plane is almost invisible in pixels.
        let pt = ThinkingOrbGeometry.Projector(
            yaw: t * 0.09,
            tilt: camTilt + 0.12 * sin(t * 0.38),
            cx: cx,
            cy: cy,
            scale: 1
        )
        let rs = ThinkingOrbGeometry.radiusScale(size, 0.6)
        var dots: [ThinkingOrbDot] = []
        for i in 0..<ThinkingOrbGeometry.below(ghostN) {
            let d = ThinkingOrbGeometry.fibDir(i, ghostN)
            let (px, py, z) = pt(d.0 * R, d.1 * R, d.2 * R)
            let depth = (z / R + 1) / 2
            dots.append(ThinkingOrbDot(
                x: px, y: py, z: z, r: 0.8 * rs, white: 0.78, a: 0.1 + 0.22 * depth
            ))
        }

        let ya = t * 0.16
        let ta = faceOn
            ? -(camTilt + 0.28) + 0.10 * sin(t * 0.40)
            : 0.58 + 0.26 * sin(t * 0.28)
        let ux = cos(ya)
        let uy = 0.0
        let uz = sin(ya)
        let vx = -uz * sin(ta)
        let vy = cos(ta)
        let vz = ux * sin(ta)
        let nx = uy * vz - uz * vy
        let ny = uz * vx - ux * vz
        let nz = ux * vy - uy * vx

        let wobAmp = 0.23 * wobMul
        let voiceAmp = 0.36
        // Reserve idle wobble plus a slice of voice so silence is not pre-shrunk
        // down to an invisible deformation budget.
        let baseR = R / (1 + 0.85 * wobAmp + 0.22 * voiceAmp)
        let idlePulse = (faceOn ? 0.14 : 0.08) * sin(t * (faceOn ? 0.82 : 0.58))
        let mid = Double(lanes - 1) / 2
        dots.reserveCapacity(dots.count + lanes * ThinkingOrbGeometry.below(segs))
        for w in 0..<lanes {
            let fw = Double(w)
            let laneOff = (fw - mid) * 0.075
            let edge = abs(fw - mid) / max(1, mid)
            for k in 0..<ThinkingOrbGeometry.below(segs) {
                let a = (Double(k) / segs) * 2 * Double.pi
                let wob = (0.10 * sin(a * 2 - t * 0.48) + 0.035 * sin(a * 3 + t * 0.31)) * wobMul
                // Boost modest speech without letting full-scale RMS explode the sash.
                let visualVoice = 1 - exp(-voice * 3.2)
                let speech = visualVoice * voiceAmp * sin(a * 2 - t * 0.72)
                let combined = wob + speech
                let radial = 1 + idlePulse + combined * (faceOn ? 1.0 : 0.55)
                let off = laneOff + combined * (faceOn ? 0.45 : 1.15)
                let x = ux * cos(a) + vx * sin(a) + nx * off
                let y = uy * cos(a) + vy * sin(a) + ny * off
                let z = uz * cos(a) + vz * sin(a) + nz * off
                let l = (x * x + y * y + z * z).squareRoot()
                let rr = baseR * radial
                let (px, py, zr) = pt((x / l) * rr, (y / l) * rr, (z / l) * rr)
                let depth = (zr / R + 1) / 2
                dots.append(ThinkingOrbDot(
                    x: px, y: py, z: zr,
                    r: (rBase + rDepth * depth) * (1 - 0.25 * edge) * rs,
                    white: 0.52 - 0.44 * depth + 0.18 * edge,
                    a: 0.4 + 0.6 * depth
                ))
            }
        }
        return ThinkingOrbFrame(dots: dots)
    }
}
