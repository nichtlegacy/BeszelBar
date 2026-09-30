import Foundation

struct SystemRecord: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let status: String?
    let host: String?
    let port: String?
    let info: SystemInfo?
    let v: String?
    let updated: String?
}

struct SystemInfo: Codable, Hashable {
    let h: String?
    let k: String?
    let c: Int?
    let t: Int?
    let m: String?
    let o: String?
    let os: Int?
    let u: Double?
    let v: String?
    let cpu: Double?
    let mp: Double?
    let dp: Double?
    let b: Double?
    let bb: Double?
    let l1: Double?
    let l5: Double?
    let l15: Double?
    let la: [Double]?
    let bat: [Double]?
    let g: Double?
    let dt: Double?
    let p: Bool?
    let ct: Int?
    let efs: [String: Double]?
    let rdn: String?
    let sv: [Int]?
}

extension SystemRecord {
    var displayStatus: String {
        guard let status = status?.lowercased() else { return "Unknown" }
        switch status {
        case "up", "online": return "Online"
        case "down", "offline": return "Offline"
        case "pending": return "Pending"
        default: return status.capitalized
        }
    }

    var isOnline: Bool {
        guard let status = status?.lowercased() else { return false }
        return status == "up" || status == "online"
    }

    var cpuPercentage: Double? {
        info?.cpu
    }

    var memoryPercentage: Double? {
        info?.mp
    }

    var diskPercentage: Double? {
        info?.dp
    }

    var temperature: Double? {
        info?.dt
    }
}

struct SystemStatsRecord: Identifiable, Codable {
    let id: String
    let created: String
    let system: String?
    let stats: SystemStatsDetail?
    let type: String?
}

struct SystemStatsDetail: Codable {
    let cpu: Double?
    let mp: Double?
    let dp: Double?
    let m: Double?
    let mu: Double?
    let ns: Double?
    let nr: Double?
    let d: Double?
    let du: Double?
    let g: [String: GpuData]?
    let t: [String: Double]?
    let efs: [String: FsStats]?
    let z: [String: ZfsPool]?

    enum CodingKeys: String, CodingKey {
        case cpu, mp, dp, m, mu, ns, nr, d, du, g, t, efs, z
    }
}

struct FsStats: Codable, Hashable {
    let d: Double?
    let du: Double?
}

struct ZfsPool: Codable, Hashable {
    let n: String?
    let hu: Bool?
    let hi: Bool?
    let raw: Bool?
    let d: Double?
    let du: Double?
    let h: String?
}

struct GpuData: Codable, Hashable {
    let n: String?
    let mu: Double?
    let mt: Double?
    let u: Double?
    let p: Double?
    let pp: Double?
    let e: [String: Double]?
}

struct GpuInfo: Identifiable, Hashable {
    let id: String
    let name: String
    let usage: Double
    let temperature: Double?
    let powerWatts: Double?
    let memoryUsedMB: Double?
    let memoryTotalMB: Double?
}

struct DiskInfo: Identifiable, Hashable {
    let id: String
    let name: String
    let usedGB: Double
    let totalGB: Double
    let isRoot: Bool
    var diskCount: Int = 1

    var usedPercent: Double {
        guard totalGB > 0 else { return 0 }
        return usedGB / totalGB * 100
    }
}

struct MemoryInfo: Hashable {
    let usedGB: Double
    let totalGB: Double
}

extension SystemStatsRecord {
    var memory: MemoryInfo? {
        guard let total = stats?.m, total > 0, let used = stats?.mu else { return nil }
        return MemoryInfo(usedGB: used, totalGB: total)
    }

    var gpus: [GpuInfo] {
        guard let map = stats?.g, !map.isEmpty else { return [] }
        let temperatures = stats?.t ?? [:]
        return map.keys.sorted().compactMap { key in
            guard let data = map[key] else { return nil }
            let name = (data.n?.isEmpty == false) ? data.n! : "GPU \(key)"
            return GpuInfo(
                id: key,
                name: name,
                usage: data.u ?? 0,
                temperature: temperatures[name],
                powerWatts: data.p,
                memoryUsedMB: data.mu,
                memoryTotalMB: data.mt
            )
        }
    }

    /// Local disks: root filesystem, extra filesystems and storage pools.
    /// Only filesystems the agent was configured to monitor are reported, so
    /// network shares never appear unless explicitly added on the agent.
    /// Pools that merely mirror a filesystem (same used bytes) are skipped.
    var disks: [DiskInfo] {
        var result: [DiskInfo] = []

        if let rootTotal = stats?.d, let rootUsed = stats?.du, rootTotal > 0 {
            result.append(DiskInfo(id: "root", name: "System", usedGB: rootUsed, totalGB: rootTotal, isRoot: true))
        }

        if let extras = stats?.efs {
            for key in extras.keys.sorted() {
                guard let fs = extras[key], let total = fs.d, total > 0, let used = fs.du else { continue }
                result.append(DiskInfo(id: key, name: key, usedGB: used, totalGB: total, isRoot: false))
            }
        }

        if let pools = stats?.z {
            for key in pools.keys.sorted() {
                guard let pool = pools[key],
                      pool.hu != true,
                      pool.raw != true,
                      let total = pool.d, total >= 4, // skip system loop images (e.g. libvirt.img)
                      let used = pool.du else { continue }
                let isDuplicate = result.contains { disk in
                    abs(disk.usedGB - used) <= max(0.25, used * 0.005)
                }
                guard !isDuplicate else { continue }
                result.append(DiskInfo(id: key, name: poolDisplayName(key: key, pool: pool), usedGB: used, totalGB: total, isRoot: false))
            }
        }

        return result
    }

    private func poolDisplayName(key: String, pool: ZfsPool) -> String {
        if let name = pool.n, !name.isEmpty {
            return name
        }
        let base = key.split(separator: ":", maxSplits: 1).last.map(String.init) ?? key
        return String(base.prefix(8))
    }
}

struct SystemDetailsRecord: Identifiable, Codable, Hashable {
    let id: String
    let system: String
    let hostname: String?
    let kernel: String?
    let cores: Int?
    let threads: Int?
    let cpu: String?
    let memory: Int64?
    let os: Int?
    let osName: String?
    let arch: String?
    let podman: Bool?
    let updated: String?

    enum CodingKeys: String, CodingKey {
        case id, system, hostname, kernel, cores, threads, cpu, memory, os
        case osName = "os_name"
        case arch, podman, updated
    }
}

enum ContainerHealth: Int, Codable, Hashable {
    case none = 0
    case starting = 1
    case healthy = 2
    case unhealthy = 3

    var displayText: String {
        switch self {
        case .none: return "No Health Check"
        case .starting: return "Starting"
        case .healthy: return "Healthy"
        case .unhealthy: return "Unhealthy"
        }
    }

    var color: String {
        switch self {
        case .none: return "secondary"
        case .starting: return "orange"
        case .healthy: return "green"
        case .unhealthy: return "red"
        }
    }
}

struct ContainerRecord: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let cpu: Double
    let memory: Double
    let net: Double
    let health: ContainerHealth
    let status: String
    let image: String
    let system: String
    let updated: Int64

    var updatedDate: Date {
        Date(timeIntervalSince1970: Double(updated) / 1000.0)
    }
}

struct ContainerStatsRecord: Identifiable, Codable {
    let id: String
    let system: String
    let name: String?
    let cpu: Double?
    let mem: Double?
    let created: String?

    var containerID: String { id }
    var containerName: String? { name }
    var memory: Double? { mem }
}

struct AlertRecord: Identifiable, Codable {
    let id: String
    let name: String
    let system: String?
    let metric: String?
    let threshold: Double?
    let enabled: Bool?
    let triggered: Bool?
    let created: String?
    let updated: String?

    var displayMetric: String {
        metric ?? "unknown"
    }

    var displayThreshold: String {
        if let t = threshold {
            return String(format: "%.0f", t)
        }
        return "-"
    }
}

struct AlertHistoryRecord: Identifiable, Codable {
    let id: String
    let alert: String
    let system: String?
    let name: String?
    let message: String?
    let value: Double?
    let threshold: Double?
    let created: String?
}

struct PocketBaseListResponse<T: Codable>: Codable {
    let page: Int
    let perPage: Int
    let totalPages: Int
    let totalItems: Int
    let items: [T]
}

struct AuthResponse: Codable {
    let token: String
}
