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

    /// Flattened (lat, lon) land points, computed once.
    static let landPoints: [(lat: Double, lon: Double)] = {
        var points: [(Double, Double)] = []
        for (i, ranges) in rows.enumerated() {
            let lat = latTop - Double(i) * step
            // Thin out dots near the poles so density looks even on the sphere.
            let stride = max(1, Int(1.0 / max(0.18, cos(lat * .pi / 180))))
            var used = Set<Int>()
            for range in ranges {
                for j in range where j % stride == 0 {
                    guard !used.contains(j) else { continue }
                    used.insert(j)
                    points.append((lat, -180 + Double(j) * step))
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

struct WorldGlobeView: View {
    let hotspots: [GeoHotspot]
    @Binding var selected: GeoHotspot?
    /// Degrees per second.
    var spinSpeed: Double = 4.0

    private let tilt = 0.38   // ~22°, gives the Bailongma 3/4 view

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            GeometryReader { geo in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let rotation = t * spinSpeed
                let size = min(geo.size.width, geo.size.height)
                let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
                let radius = size * 0.42

                ZStack {
                    Canvas { ctx, _ in
                        drawAtmosphere(ctx, center: center, radius: radius)
                        drawGraticule(ctx, center: center, radius: radius, rotation: rotation)
                        drawLand(ctx, center: center, radius: radius, rotation: rotation)
                    }

                    // Hotspot targets (real SwiftUI views → hoverable/clickable)
                    ForEach(hotspots) { spot in
                        let p = project(lat: spot.place.lat, lon: spot.place.lon,
                                        rotation: rotation, tilt: tilt,
                                        center: center, radius: radius)
                        if p.visible {
                            HotspotMarker(
                                hotspot: spot,
                                isSelected: selected?.id == spot.id,
                                phase: t
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
        let dot = max(1.0, radius / 95)
        for (lat, lon) in WorldMap.landPoints {
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
