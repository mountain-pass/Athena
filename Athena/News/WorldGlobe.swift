import SwiftUI

// MARK: - Coarse world land mask

/// 5°-resolution land mask. Each row is a latitude band (85°N → 85°S);
/// values are inclusive column ranges where column j → longitude −180 + j×5.
/// Deliberately stylized — enough to read as Earth at dotted-globe scale.
enum WorldMap {
    static let colCount = 72
    static let latTop = 85.0
    static let step = 5.0

    static let rows: [[ClosedRange<Int>]] = [
        [26...31],                                            // 85N Greenland
        [10...22, 24...32, 37...38],                          // 80N
        [8...24, 25...33, 44...46, 52...56],                  // 75N
        [0...26, 27...32, 36...71],                           // 70N
        [0...26, 27...31, 33...34, 35...71],                  // 65N
        [0...28, 29...31, 34...71],                           // 60N
        [2...28, 34...35, 36...71],                           // 55N
        [8...28, 34...35, 36...71],                           // 50N
        [10...28, 36...50, 51...71],                          // 45N
        [11...28, 34...37, 38...50, 51...71],                 // 40N
        [12...28, 35...40, 41...50, 51...70],                 // 35N
        [14...28, 34...44, 45...48, 50...56, 57...68],        // 30N
        [15...27, 34...46, 47...48, 50...56, 57...66],        // 25N
        [16...26, 34...48, 50...56, 57...64],                 // 20N
        [17...26, 34...50, 51...56, 57...64],                 // 15N
        [19...30, 34...50, 51...56, 58...64],                 // 10N
        [24...32, 34...52, 58...66],                          // 5N
        [24...33, 36...52, 58...68],                          // 0
        [24...34, 37...52, 58...68],                          // 5S
        [24...34, 38...52, 58...70],                          // 10S
        [25...34, 38...50, 52...53, 58...70],                 // 15S
        [25...34, 38...50, 52...53, 57...70],                 // 20S
        [26...33, 39...48, 57...70],                          // 25S
        [26...32, 39...46, 58...69],                          // 30S
        [27...31, 39...44, 60...68, 70...71],                 // 35S
        [27...30, 70...71],                                   // 40S
        [27...30, 70...71],                                   // 45S
        [28...30],                                            // 50S
        [28...30],                                            // 55S
        [28...30],                                            // 60S
        [0...71], [0...71], [0...71], [0...71], [0...71],      // Antarctica
    ]

    /// Is a given 5° cell land?
    static func isLand(row: Int, col: Int) -> Bool {
        guard rows.indices.contains(row) else { return false }
        let c = ((col % colCount) + colCount) % colCount
        return rows[row].contains { $0.contains(c) }
    }

    /// True when the generated high-resolution mask is present
    /// (run `python3 Scripts/make-coastline.py`).
    static let hasDetailedMask: Bool = {
        #if canImport(Foundation)
        return !LandMaskData.bits.isEmpty
        #else
        return false
        #endif
    }()

    /// Real coastlines from Natural Earth, when the generated mask exists.
    static let detailedPoints: [(lat: Double, lon: Double)] = {
        guard hasDetailedMask else { return [] }
        var points: [(Double, Double)] = []
        let step = LandMaskData.degrees
        for row in 0..<LandMaskData.rows {
            let lat = 90 - (Double(row) + 0.5) * step
            // Thin longitudes toward the poles so dot density stays even.
            let cosLat = max(0.10, cos(lat * .pi / 180))
            let stride = max(1, Int((1.0 / cosLat).rounded()))
            for col in Swift.stride(from: 0, to: LandMaskData.columns, by: stride)
            where LandMaskData.isLand(row: row, col: col) {
                points.append((lat, -180 + (Double(col) + 0.5) * step))
            }
        }
        return points
    }()

    /// Coarse fallback: (lat, lon) land points at ~2.5° resolution.
    ///
    /// The source mask is 5°; we subdivide each land cell into up to 4 points,
    /// emitting the in-between ones only when the neighbouring cell is also
    /// land. That quadruples density without fattening coastlines.
    static let landPoints: [(lat: Double, lon: Double)] = {
        var points: [(Double, Double)] = []
        let half = step / 2

        for (i, _) in rows.enumerated() {
            let lat = latTop - Double(i) * step
            // Longitudes converge at the poles — thin out so density looks even.
            let cosLat = max(0.12, cos(lat * .pi / 180))
            let lonStride = max(1, Int((1.0 / cosLat).rounded()))

            for j in 0..<colCount where isLand(row: i, col: j) {
                guard j % lonStride == 0 else { continue }
                let lon = -180 + Double(j) * step
                points.append((lat, lon))

                // Interpolated companions (only into neighbouring land).
                let eastIsLand = isLand(row: i, col: j + 1)
                let southIsLand = isLand(row: i + 1, col: j)
                if eastIsLand, lonStride == 1 {
                    points.append((lat, lon + half))
                }
                if southIsLand {
                    points.append((lat - half, lon))
                    if eastIsLand, isLand(row: i + 1, col: j + 1), lonStride == 1 {
                        points.append((lat - half, lon + half))
                    }
                }
            }
        }
        return points
    }()
}

// MARK: - Projection helpers

private struct Projected {
    let point: CGPoint
    let visible: Bool     // front hemisphere
    let depth: Double     // 0 (limb) … 1 (facing viewer)
}

private func project(lat: Double, lon: Double, rotation: Double,
                     tilt: Double, center: CGPoint, radius: CGFloat) -> Projected {
    let latRad = lat * .pi / 180
    let lonRad = (lon + rotation) * .pi / 180

    // Sphere → cartesian
    let x = cos(latRad) * sin(lonRad)
    let y0 = sin(latRad)
    let z0 = cos(latRad) * cos(lonRad)

    // Tilt around the X axis
    let ct = cos(tilt), st = sin(tilt)
    let y = y0 * ct - z0 * st
    let z = y0 * st + z0 * ct

    return Projected(
        point: CGPoint(x: center.x + CGFloat(x) * radius,
                       y: center.y - CGFloat(y) * radius),
        visible: z > 0,
        depth: max(0, z)
    )
}

// MARK: - Globe view

/// Tracks rotation: auto-spin, drag override, inertia, and idle resume.
///
/// Deliberately NOT an ObservableObject: it's mutated every frame from inside
/// the TimelineView body, and publishing during a view update is illegal
/// ("Publishing changes from within view updates is not allowed" → crash).
/// TimelineView already redraws each frame, so no observation is needed.
@MainActor
final class GlobeSpin {
    var rotation: Double = 0        // degrees
    var isDragging = false

    private var velocity: Double = 0           // deg/sec from a flick
    private var lastFrame: Date = .now
    private var idleSince: Date = .now
    private var dragStartRotation: Double = 0

    let autoSpeed: Double = 4.0                // deg/sec
    private let resumeDelay: TimeInterval = 3  // seconds of stillness

    /// Advances and returns the rotation — safe to call during a view update.
    func rotationAdvanced(to now: Date) -> Double {
        advance(to: now)
        return rotation
    }

    private func advance(to now: Date) {
        let dt = min(0.1, now.timeIntervalSince(lastFrame))
        lastFrame = now
        guard !isDragging else { return }

        if abs(velocity) > 0.5 {
            // Flick inertia, decaying.
            rotation += velocity * dt
            velocity *= pow(0.15, dt)          // ~85% damping per second
            idleSince = now
        } else if now.timeIntervalSince(idleSince) > resumeDelay {
            // Ease back into the ambient spin.
            let sinceResume = now.timeIntervalSince(idleSince) - resumeDelay
            let ramp = min(1, sinceResume / 1.5)
            rotation += autoSpeed * ramp * dt
        }
    }

    func beginDrag() {
        isDragging = true
        velocity = 0
        dragStartRotation = rotation
    }

    func drag(translation: CGFloat, width: CGFloat) {
        // A full width drag ≈ 180° of rotation.
        rotation = dragStartRotation + Double(translation / max(1, width)) * 180
    }

    func endDrag(predictedTranslation: CGFloat, translation: CGFloat, width: CGFloat) {
        isDragging = false
        idleSince = .now
        let overshoot = Double((predictedTranslation - translation) / max(1, width)) * 180
        velocity = max(-220, min(220, overshoot * 2.2))
    }
}

struct WorldGlobeView: View {
    let hotspots: [GeoHotspot]
    @Binding var selected: GeoHotspot?

    @State private var spin = GlobeSpin()
    private let tilt = 0.38   // ~22°, gives the Bailongma 3/4 view

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
            GeometryReader { geo in
                let rotation = spin.rotationAdvanced(to: timeline.date)
                let size = min(geo.size.width, geo.size.height)
                let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
                let radius = size * 0.42

                ZStack {
                    Canvas { ctx, _ in
                        drawAtmosphere(ctx, center: center, radius: radius)
                        drawGraticule(ctx, center: center, radius: radius, rotation: rotation)
                        drawLand(ctx, center: center, radius: radius, rotation: rotation)
                    }
                    // Drag anywhere on the globe to spin it; it resumes its
                    // ambient rotation a few seconds after you let go.
                    .contentShape(Circle())
                    .gesture(
                        DragGesture(minimumDistance: 2)
                            .onChanged { value in
                                if !spin.isDragging { spin.beginDrag() }
                                spin.drag(translation: value.translation.width,
                                          width: geo.size.width)
                            }
                            .onEnded { value in
                                spin.endDrag(
                                    predictedTranslation: value.predictedEndTranslation.width,
                                    translation: value.translation.width,
                                    width: geo.size.width)
                            }
                    )

                    // Hotspot targets (real SwiftUI views → hoverable/clickable)
                    ForEach(hotspots) { spot in
                        let p = project(lat: spot.place.lat, lon: spot.place.lon,
                                        rotation: rotation, tilt: tilt,
                                        center: center, radius: radius)
                        if p.visible {
                            HotspotMarker(
                                hotspot: spot,
                                isSelected: selected?.id == spot.id,
                                phase: timeline.date.timeIntervalSinceReferenceDate
                            ) {
                                selected = (selected?.id == spot.id) ? nil : spot
                            }
                            .position(p.point)
                            .opacity(0.35 + p.depth * 0.65)
                        }
                    }
                }
            }
        }
    }

    // MARK: Drawing

    private func drawAtmosphere(_ ctx: GraphicsContext, center: CGPoint, radius: CGFloat) {
        let rect = CGRect(x: center.x - radius, y: center.y - radius,
                          width: radius * 2, height: radius * 2)
        // Soft glow
        ctx.fill(Path(ellipseIn: rect.insetBy(dx: -radius * 0.06, dy: -radius * 0.06)),
                 with: .radialGradient(
                    Gradient(colors: [Theme.blue.opacity(0.12), .clear]),
                    center: center, startRadius: radius * 0.85, endRadius: radius * 1.12))
        // Ocean disc
        ctx.fill(Path(ellipseIn: rect),
                 with: .radialGradient(
                    Gradient(colors: [Color(hex: 0x0E2036).opacity(0.95),
                                      Color(hex: 0x06101C).opacity(0.98)]),
                    center: CGPoint(x: center.x - radius * 0.25, y: center.y - radius * 0.3),
                    startRadius: 0, endRadius: radius * 1.3))
        ctx.stroke(Path(ellipseIn: rect), with: .color(Theme.blue.opacity(0.25)), lineWidth: 1)
    }

    private func drawGraticule(_ ctx: GraphicsContext, center: CGPoint,
                               radius: CGFloat, rotation: Double) {
        let color = GraphicsContext.Shading.color(Theme.blue.opacity(0.10))
        // Latitude rings
        for lat in stride(from: -60.0, through: 60.0, by: 30.0) {
            var path = Path()
            var started = false
            for lon in stride(from: -180.0, through: 180.0, by: 4.0) {
                let p = project(lat: lat, lon: lon, rotation: rotation, tilt: tilt,
                                center: center, radius: radius)
                guard p.visible else { started = false; continue }
                if started { path.addLine(to: p.point) } else { path.move(to: p.point); started = true }
            }
            ctx.stroke(path, with: color, lineWidth: 0.5)
        }
        // Meridians
        for lon in stride(from: -180.0, to: 180.0, by: 30.0) {
            var path = Path()
            var started = false
            for lat in stride(from: -90.0, through: 90.0, by: 4.0) {
                let p = project(lat: lat, lon: lon, rotation: rotation, tilt: tilt,
                                center: center, radius: radius)
                guard p.visible else { started = false; continue }
                if started { path.addLine(to: p.point) } else { path.move(to: p.point); started = true }
            }
            ctx.stroke(path, with: color, lineWidth: 0.5)
        }
    }

    private func drawLand(_ ctx: GraphicsContext, center: CGPoint,
                          radius: CGFloat, rotation: Double) {
        let detailed = WorldMap.hasDetailedMask
        let points = detailed ? WorldMap.detailedPoints : WorldMap.landPoints
        let dot = max(0.9, radius / (detailed ? 150 : 95))
        for (lat, lon) in points {
            let p = project(lat: lat, lon: lon, rotation: rotation, tilt: tilt,
                            center: center, radius: radius)
            guard p.visible else { continue }
            let size = dot * (0.55 + p.depth * 0.75)
            let opacity = 0.18 + p.depth * 0.72
            ctx.fill(
                Path(ellipseIn: CGRect(x: p.point.x - size / 2, y: p.point.y - size / 2,
                                       width: size, height: size)),
                with: .color(Theme.green.opacity(opacity))
            )
        }
    }
}

// MARK: - Hotspot marker

private struct HotspotMarker: View {
    let hotspot: GeoHotspot
    let isSelected: Bool
    let phase: Double
    let action: () -> Void

    @State private var hovering = false

    private var pulse: Double {
        // Staggered per place so they don't blink in unison.
        let offset = Double(abs(hotspot.place.name.hashValue % 100)) / 100
        return (sin((phase + offset * 3) * 2.2) + 1) / 2
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                // Expanding ping ring
                Circle()
                    .stroke(Theme.red.opacity(0.5 * (1 - pulse)), lineWidth: 1.5)
                    .frame(width: 10 + 22 * pulse, height: 10 + 22 * pulse)
                // Target rings
                Circle()
                    .stroke(Theme.red.opacity(0.85), lineWidth: 1.2)
                    .frame(width: 12, height: 12)
                Circle()
                    .fill(Theme.red)
                    .frame(width: 5, height: 5)
                if hovering || isSelected {
                    Text("\(hotspot.place.name) · \(hotspot.items.count)")
                        .font(Theme.mono(9, weight: .semibold))
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Theme.bg.opacity(0.92))
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(Theme.red.opacity(0.6), lineWidth: 0.5))
                        .foregroundStyle(Theme.text)
                        .fixedSize()
                        .offset(y: -20)
                }
            }
            .frame(width: 34, height: 34)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .scaleEffect(isSelected ? 1.25 : 1)
        .animation(.spring(duration: 0.25), value: isSelected)
    }
}
