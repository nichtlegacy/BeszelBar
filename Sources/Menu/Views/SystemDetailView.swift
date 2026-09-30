import SwiftUI

struct SystemDetailView: View {
    let system: SystemRecord
    var details: SystemDetailsRecord? = nil
    var gpus: [GpuInfo] = []
    var disks: [DiskInfo] = []
    var memory: MemoryInfo? = nil

    private var cpuModel: String? {
        guard let raw = details?.cpu ?? system.info?.m else { return nil }
        return cleanCpuModel(raw)
    }

    private var cpuCores: Int? {
        details?.cores ?? system.info?.c
    }

    private var cpuThreads: Int? {
        details?.threads ?? system.info?.t
    }

    private var hostname: String? {
        details?.hostname ?? system.info?.h
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                HeaderRow(icon: "desktopcomputer", iconSize: 11) {
                    Text(hostname ?? system.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                }

                if cpuModel != nil {
                    HeaderRow(icon: "cpu") {
                        Text(cpuModel ?? "")
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                if system.info?.dt != nil || system.info?.u != nil {
                    HStack(spacing: 14) {
                        if let temp = system.info?.dt {
                            HeaderRow(icon: "thermometer.medium") {
                                Text(String(format: "%.0f°C", temp))
                                    .foregroundColor(MetricThresholds.tempColor(temp))
                            }
                        }
                        if let uptime = system.info?.u {
                            HeaderRow(icon: "clock") {
                                Text(formatUptime(uptime))
                            }
                        }
                    }
                }
            }

            Divider()
                .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 6) {
                Label("Usage", systemImage: "chart.bar.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.primary)

                if let cpu = system.cpuPercentage {
                    MetricBar(label: "CPU", icon: "cpu", value: cpu, color: MetricThresholds.usageColor(cpu), detail: cpuDetail)
                }
                if let mem = system.memoryPercentage {
                    MetricBar(label: "Memory", icon: "memorychip", value: mem, color: MetricThresholds.usageColor(mem), detail: memoryDetail)
                }
                ForEach(gpus) { gpu in
                    GpuBar(gpu: gpu)
                }
                ForEach(disks) { disk in
                    DiskBar(disk: disk)
                }
                if disks.isEmpty, let disk = system.diskPercentage {
                    MetricBar(label: "Disk", icon: "internaldrive", value: disk, color: MetricThresholds.usageColor(disk))
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(width: 240)
    }

    private var cpuDetail: String? {
        var parts: [String] = []
        if let cores = cpuCores {
            parts.append("\(cores) cores")
        }
        if let threads = cpuThreads {
            parts.append("\(threads) threads")
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }

    private var memoryDetail: String? {
        guard let memory else { return nil }
        return formatStoragePair(usedGB: memory.usedGB, totalGB: memory.totalGB)
    }

    private func formatUptime(_ seconds: Double) -> String {
        let days = Int(seconds) / 86400
        let hours = (Int(seconds) % 86400) / 3600
        if days > 0 {
            return "\(days)d \(hours)h"
        } else {
            let mins = (Int(seconds) % 3600) / 60
            return "\(hours)h \(mins)m"
        }
    }

    /// Shortens vendor CPU strings: "Intel(R) Core(TM) i7-9900K CPU @ 3.60GHz" -> "Intel Core i9-9900K"
    private func cleanCpuModel(_ raw: String) -> String {
        var model = raw
        for token in ["(R)", "(TM)", "(C)"] {
            model = model.replacingOccurrences(of: token, with: "")
        }
        if let range = model.range(of: "@\\s*[0-9.]+\\s*GHz", options: .regularExpression) {
            model = String(model[..<range.lowerBound])
        }
        model = model.replacingOccurrences(of: "\\s*\\d+[- ]Core Processor", with: "", options: .regularExpression)
        model = model.replacingOccurrences(of: "\\s+Processor$", with: "", options: .regularExpression)
        model = model.replacingOccurrences(of: "\\s+with Radeon( Graphics)?$", with: "", options: .regularExpression)
        model = model.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        if model.hasSuffix(" CPU") {
            model = String(model.dropLast(4))
        }
        return model.trimmingCharacters(in: .whitespaces)
    }
}

/// Formats GiB-based storage pairs: TB from 1 TiB up, df-style.
func formatStoragePair(usedGB: Double, totalGB: Double) -> String {
    if totalGB >= 1024 {
        return "\(formatTerabytes(usedGB / 1024)) / \(formatTerabytes(totalGB / 1024)) TB"
    }
    let used = usedGB >= 100 ? String(format: "%.0f", usedGB) : String(format: "%.1f", usedGB)
    let total = totalGB >= 100 ? String(format: "%.0f", totalGB) : String(format: "%.1f", totalGB)
    return "\(used) / \(total) GB"
}

private func formatTerabytes(_ terabytes: Double) -> String {
    if terabytes >= 10 {
        return String(format: "%.0f", terabytes)
    }
    return String(format: "%.1f", terabytes)
}

/// Header line with a fixed icon column so all rows align on one edge.
private struct HeaderRow<Content: View>: View {
    let icon: String
    var iconSize: CGFloat = 10
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: iconSize))
                .foregroundColor(.secondary)
                .frame(width: 13, alignment: .center)
            content()
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
    }
}

enum AppColors {
    static let green = Color.green
    static let orange = Color.orange
    static let red = Color.red
    static let gray = Color.gray
}

/// User-configurable color thresholds (Settings → General → THRESHOLDS).
enum MetricThresholds {
    static var usageWarnPercent: Double { stored("usageWarnPercent", default: 70) }
    static var usageCriticalPercent: Double { stored("usageCriticalPercent", default: 90) }
    static var tempWarnC: Double { stored("tempWarnC", default: 60) }
    static var tempCriticalC: Double { stored("tempCriticalC", default: 80) }

    static func usageColor(_ value: Double) -> Color {
        if value >= usageCriticalPercent { return AppColors.red }
        if value >= usageWarnPercent { return AppColors.orange }
        return AppColors.green
    }

    static func tempColor(_ temperature: Double) -> Color {
        if temperature > tempCriticalC { return .red }
        if temperature > tempWarnC { return .orange }
        return .secondary
    }

    private static func stored(_ key: String, default fallback: Double) -> Double {
        let value = UserDefaults.standard.double(forKey: key)
        return value > 0 ? value : fallback
    }
}

struct MetricBar: View {
    let label: String
    var icon: String? = nil
    let value: Double
    let color: Color
    var detail: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                HStack(spacing: 6) {
                    if let icon {
                        Image(systemName: icon)
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                            .frame(width: 12, alignment: .center)
                    }
                    Text(label)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text("\(Int(value))%")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(.primary)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.2))
                        .frame(height: 6)

                    RoundedRectangle(cornerRadius: 3)
                        .fill(color)
                        .frame(width: geometry.size.width * min(value / 100, 1.0), height: 6)
                }
            }
            .frame(height: 6)

            if let detail {
                HStack {
                    Spacer()
                    Text(detail)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary.opacity(0.8))
                }
            }
        }
    }
}

struct GpuBar: View {
    let gpu: GpuInfo
    @AppStorage("gpuBarMetric") private var gpuBarMetric = "utilization"

    private var vramPercent: Double? {
        guard let used = gpu.memoryUsedMB,
              let total = gpu.memoryTotalMB, total > 0 else { return nil }
        return used / total * 100
    }

    private var showsVram: Bool {
        gpuBarMetric == "vram" && vramPercent != nil
    }

    private var barValue: Double {
        showsVram ? vramPercent! : gpu.usage
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                HStack(spacing: 6) {
                    GpuIcon(size: 11)
                        .frame(width: 12, alignment: .center)
                    Text(gpu.name)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Text("\(Int(barValue))%")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(.primary)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.2))
                        .frame(height: 6)

                    RoundedRectangle(cornerRadius: 3)
                        .fill(MetricThresholds.usageColor(barValue))
                        .frame(width: geometry.size.width * min(barValue / 100, 1.0), height: 6)
                }
            }
            .frame(height: 6)

            if let detail = detailText {
                HStack {
                    Spacer()
                    Text(detail)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary.opacity(0.8))
                }
            }
        }
    }

    private var detailText: String? {
        var parts: [String] = []
        if showsVram {
            parts.append("\(Int(gpu.usage))% util")
            if let temperature = gpu.temperature, temperature > 0 {
                parts.append(String(format: "%.0f°C", temperature))
            }
            if let power = gpu.powerWatts, power > 0 {
                parts.append(String(format: "%.0f W", power))
            }
        } else {
            if let temperature = gpu.temperature, temperature > 0 {
                parts.append(String(format: "%.0f°C", temperature))
            }
            if let power = gpu.powerWatts, power > 0 {
                parts.append(String(format: "%.0f W", power))
            }
            if let used = gpu.memoryUsedMB, let total = gpu.memoryTotalMB, total > 0 {
                parts.append("\(formatGB(used)) / \(formatGB(total)) GB")
            }
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }

    private func formatGB(_ megabytes: Double) -> String {
        let gigabytes = megabytes / 1000
        if gigabytes >= 100 {
            return String(format: "%.0f", gigabytes)
        }
        return String(format: "%.1f", gigabytes)
    }
}

struct DiskBar: View {
    let disk: DiskInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: disk.isRoot ? "internaldrive" : "externaldrive")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .frame(width: 12, alignment: .center)
                    Text(disk.name)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Text("\(Int(disk.usedPercent))%")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(.primary)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.2))
                        .frame(height: 6)

                    RoundedRectangle(cornerRadius: 3)
                        .fill(MetricThresholds.usageColor(disk.usedPercent))
                        .frame(width: geometry.size.width * min(disk.usedPercent / 100, 1.0), height: 6)
                }
            }
            .frame(height: 6)

            HStack {
                Spacer()
                Text(groupDetail)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary.opacity(0.8))
            }
        }
    }

    private var groupDetail: String {
        let pair = formatStoragePair(usedGB: disk.usedGB, totalGB: disk.totalGB)
        guard disk.diskCount > 1 else { return pair }
        return "\(pair) · \(disk.diskCount) disks"
    }
}
