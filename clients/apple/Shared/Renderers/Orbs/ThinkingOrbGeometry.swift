import Foundation

// Adapted from ThinkingOrbs (https://github.com/haplollc/ThinkingOrbs)
// commit e2c07bbdec4db797fb302300ef0159b1806a909f
// Original designs and engine: Jakub Antalik
// Swift port: Haplo LLC
// Voice-driven circular band and sphere deformation: Oppi adaptation
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
    /// 20 pt working-row footprint.
    case workingCompact
    /// 20 pt settings preview.
    case workingPreview
    /// 32 pt expanded/ask dictation control.
    case dictationExpanded
    /// 44 pt standard dictation control.
    case dictationStandard

    var designSize: Double {
        switch self {
        case .workingCompact: return 20
        case .workingPreview: return 20
        case .dictationExpanded: return 32
        case .dictationStandard: return 44
        }
    }

    static func working(side: Double) -> Self {
        side <= 20 ? .workingCompact : .workingPreview
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
        voiceSpectrum: VoiceSpectrumFrame = .zero,
        zSorted: Bool = true
    ) -> ThinkingOrbFrame {
        let safeSize = size.isFinite && size > 0 ? size : sizeClass.designSize
        let safeT = t.isFinite ? t : 0
        var voice = voiceSpectrum
        for k in 0..<8 { voice.bands[k] = k < 5 ? ThinkingOrbAudio.clamp(voice.bands[k]) : 0 }
        voice.flux = voice.flux.isFinite ? max(0, voice.flux) : 0
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
        fileprivate var build: @Sendable (_ size: Double, _ t: Double, _ voice: VoiceSpectrumFrame) -> ThinkingOrbFrame
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
            // Concentric dotted lanes stay readable at the actual control size.
            return circularBand(
                speed: 2.34,
                lanes: 4,
                segs: 32,
                rBase: 1.1,
                rDepth: 1.7
            )
        case (.composing, .dictationStandard):
            return circularBand(
                speed: 2.34,
                lanes: 5,
                segs: 44,
                rBase: 1.1,
                rDepth: 1.7
            )
        case (.composing, .workingCompact), (.composing, .workingPreview):
            return circularBand(
                speed: 3.12,
                lanes: 3,
                segs: 20,
                rBase: 1.15,
                rDepth: 1.7
            )
        case (.breathing, .dictationExpanded):
            return breathing(speed: 2.8, dotCount: 180)
        case (.breathing, .dictationStandard):
            return breathing(speed: 2.8, dotCount: 300)
        case (.breathing, .workingCompact), (.breathing, .workingPreview):
            return breathing(speed: 3.24, dotCount: 90)
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

    private static func circularBand(
        speed: Double,
        lanes: Int,
        segs: Int,
        rBase: Double,
        rDepth: Double
    ) -> Resolved {
        Resolved(speed: speed, rMin: 0.3) { size, t, voice in
            ThinkingOrbBuilders.circularBand(
                size,
                t,
                voice: voice,
                lanes: lanes,
                segs: segs,
                rBase: rBase,
                rDepth: rDepth
            )
        }
    }

    private static func breathing(speed: Double, dotCount: Int) -> Resolved {
        Resolved(speed: speed, rMin: 0.3) { size, t, voice in
            ThinkingOrbBuilders.breathing(size, t, voice: voice, dotCount: dotCount)
        }
    }
}

private enum ThinkingOrbBuilders {
    /// Only alpha is clock-driven in dictation, with a stable per-dot phase.
    private static func ghostTwinkle(_ index: Int, _ time: Double) -> Double {
        0.05 * sin(time * 2 * .pi * 0.3 + ThinkingOrbGeometry.hashD(Double(index), 4.1) * 2 * .pi)
    }

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
        // Fill the same 20pt slot as Game of Life instead of insetting the orb.
        let R = (size / 2) * 0.9
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
        let radius = (size / 2) * 0.9
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
        let R = (size / 2) * 0.9
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

    /// Oppi's full-sphere Breathing, rather than the original face-on ring.
    /// Fixed material directions, with five distinct radial spectral modes.
    /// No clock term changes position or radius.
    static func breathing(
        _ size: Double,
        _ t: Double,
        voice: VoiceSpectrumFrame,
        dotCount: Int
    ) -> ThinkingOrbFrame {
        let R = size * 0.39
        let rs = ThinkingOrbGeometry.radiusScale(size, 0.6)
        let bands = voice.bands
        let onset = Double(min(1, voice.flux / 30))
        var dots: [ThinkingOrbDot] = []
        dots.reserveCapacity(dotCount)
        for i in 0..<dotCount {
            let d = ThinkingOrbGeometry.fibDir(i, Double(dotCount))
            let y = d.1
            let y2 = y * y
            let p2 = (3 * y2 - 1) / 2
            let p3 = (5 * y2 * y - 3 * y) / 2
            let p4 = (35 * y2 * y2 - 30 * y2 + 3) / 8
            let roughness = 2 * ThinkingOrbGeometry.hashD(Double(i), 9.3) - 1
            // Higher bands stay close to the chest mode so pitch is
            // visible at 32/44 pt, not a faint roughness on a swell.
            let displacement = 0.32 * Double(bands[0])
                + 0.28 * Double(bands[1]) * p2
                + 0.26 * Double(bands[2]) * p3
                + 0.24 * Double(bands[3]) * p4
                + 0.22 * Double(bands[4]) * roughness
            let depth = (d.2 + 1) / 2
            let dotRadius = (1.0 + 1.7 * depth) * rs
            // Reserve the rendered radius before limiting a material point's
            // radial travel. Only excursions that would clip are shortened;
            // directions, idle geometry, and the five spectral modes stay put.
            // Metal converts coordinates to Float; leave subpixel rounding room.
            let roundingInset = 2 * Double(Float(size).ulp)
            let canvasRadius = max(0, size / 2 - dotRadius - roundingInset) / max(abs(d.0), abs(d.1))
            let radius = min(R * (0.94 + min(0.36, max(-0.36, displacement))), canvasRadius)
            dots.append(ThinkingOrbDot(
                x: size / 2 + d.0 * radius,
                y: size / 2 - d.1 * radius,
                z: d.2 * radius,
                r: dotRadius,
                white: 0.58 - 0.5 * depth,
                a: min(1, 0.3 + 0.7 * depth + (i % 5 == 0 ? ghostTwinkle(i, t) : 0)),
                accent: min(1, 0.45 + 0.2 * depth + 0.3 * onset),
                palette: Double(min(3, i * 4 / dotCount))
            ))
        }
        return ThinkingOrbFrame(dots: dots)
    }

    /// Front-facing annulus. Depth shades the rounded band, never projects it
    /// into a tilted sash. Every lane shares the same radial displacement.
    static func circularBand(
        _ size: Double,
        _ t: Double,
        voice: VoiceSpectrumFrame,
        lanes: Int,
        segs: Int,
        rBase: Double,
        rDepth: Double
    ) -> ThinkingOrbFrame {
        let rs = ThinkingOrbGeometry.radiusScale(size, 0.6)
        let bands = voice.bands
        let onset = Double(min(1, voice.flux / 30))
        var dots: [ThinkingOrbDot] = []
        dots.reserveCapacity(lanes * segs)
        for lane in 0..<lanes {
            let across = Double(lane) / Double(lanes - 1)
            let edge = abs(2 * across - 1)
            let arch = sqrt(max(0, 1 - edge * edge))
            for segment in 0..<segs {
                let angle = Double(segment) / Double(segs) * 2 * .pi
                // Bass expands the whole band; upper bands add progressively
                // finer, smaller standing ripples. Even modes preserve the
                // center. No phase/angle/lane lag can wring or cross the lanes.
                let displacement = 0.050 * Double(bands[0])
                    + 0.028 * Double(bands[1]) * (0.6 + 0.4 * cos(2 * angle))
                    + 0.018 * Double(bands[2]) * cos(4 * angle)
                    + 0.012 * Double(bands[3]) * cos(6 * angle)
                    + 0.010 * Double(bands[4]) * cos(8 * angle)
                // For the entire [0,1]^5 cube, displacement is in [-.040,.118].
                // Centers therefore stay in [.190,.468] * size. The remaining
                // .032 * size exceeds the largest onset dot at 20/32/44 pt,
                // including finalize's .3pt minimum and Float rounding.
                let radius = size * (0.23 + 0.12 * across + displacement)
                let depth = 0.25 + 0.55 * arch + 0.1 * sin(angle)
                let index = lane * segs + segment
                dots.append(ThinkingOrbDot(
                    x: size / 2 + cos(angle) * radius,
                    y: size / 2 - sin(angle) * radius,
                    z: (2 * depth - 1) * size * 0.04,
                    r: (rBase + rDepth * depth) * (1 - 0.25 * edge) * rs * (1 + 0.2 * onset),
                    white: 0.52 - 0.44 * depth + 0.18 * edge,
                    a: 0.4 + 0.6 * depth + (index % 5 == 0 ? ghostTwinkle(index, t) : 0),
                    accent: 0.65 - 0.2 * edge,
                    palette: Double(min(3, lane * 4 / lanes))
                ))
            }
        }
        return ThinkingOrbFrame(dots: dots)
    }
}
