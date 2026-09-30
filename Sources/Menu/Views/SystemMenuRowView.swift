import SwiftUI

struct SystemMenuRowView: View {
    let system: SystemRecord
    var gpus: [GpuInfo] = []
    @AppStorage("showStatsInMenu") private var showStatsInMenu = true

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(color: statusColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(system.name.isEmpty ? system.id : system.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)

                if showStatsInMenu, hasStats {
                    HStack(spacing: 4) {
                        if let cpu = system.cpuPercentage {
                            StatPill(value: "\(Int(cpu))%", icon: "cpu")
                        }
                        if let mem = system.memoryPercentage {
                            StatPill(value: "\(Int(mem))%", icon: "memorychip")
                        }
                        if !gpus.isEmpty {
                            StatPill(value: "\(Int(maxGpuUsage))%") {
                                GpuIcon()
                            }
                        }
                        if let disk = system.diskPercentage {
                            StatPill(value: "\(Int(disk))%", icon: "internaldrive")
                        }
                    }
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary.opacity(0.4))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    private var maxGpuUsage: Double {
        gpus.map(\.usage).max() ?? 0
    }

    private var hasStats: Bool {
        system.cpuPercentage != nil
            || system.memoryPercentage != nil
            || system.diskPercentage != nil
            || !gpus.isEmpty
    }

    private var statusColor: Color {
        guard let status = system.status?.lowercased() else { return .gray }
        switch status {
        case "up", "online": return .green
        case "down", "offline": return .red
        case "pending": return .orange
        default: return .gray
        }
    }
}

struct StatusDot: View {
    let color: Color

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.2))
                .frame(width: 12, height: 12)
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
        }
    }
}

struct StatPill: View {
    let value: String
    private let icon: AnyView

    init(value: String, icon: String) {
        self.value = value
        self.icon = AnyView(Image(systemName: icon))
    }

    init(value: String, icon: () -> some View) {
        self.value = value
        self.icon = AnyView(icon())
    }

    var body: some View {
        HStack(spacing: 4) {
            icon
                .font(.system(size: 10, weight: .medium))
            Text(value)
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundColor(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.secondary.opacity(0.12))
        .clipShape(Capsule())
    }
}

/// Graphics card icon (SF Symbols has no GPU symbol): bracket, card, fan, vents.
struct GpuIcon: View {
    var size: CGFloat = 11

    var body: some View {
        GpuIconShape()
            .stroke(style: StrokeStyle(lineWidth: max(0.7, 1.7 * size / 24), lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
    }
}

struct GpuIconShape: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 24
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * s, y: rect.minY + y * s)
        }
        var path = Path()
        // mounting bracket
        path.move(to: point(3, 3.5))
        path.addLine(to: point(3, 20.5))
        // card body
        path.addRoundedRect(
            in: CGRect(x: rect.minX + 5 * s, y: rect.minY + 5 * s, width: 17 * s, height: 14 * s),
            cornerSize: CGSize(width: 1.5 * s, height: 1.5 * s)
        )
        // fan
        path.addEllipse(in: CGRect(x: rect.minX + 13 * s, y: rect.minY + 9 * s, width: 6 * s, height: 6 * s))
        // vents
        for y: CGFloat in [8.5, 12, 15.5] {
            path.move(to: point(8, y))
            path.addLine(to: point(11, y))
        }
        return path
    }
}
