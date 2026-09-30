import Foundation
import Observation

@Observable
@MainActor
final class AppState {
    static let shared = AppState()

    var instances: [Instance] = []
    var selectedInstance: Instance?
    var selectedInstanceSystems: [SystemRecord] = []
    var systemDetails: [String: SystemDetailsRecord] = [:]
    var systemStats: [String: SystemStatsRecord] = [:]
    var containers: [String: [ContainerRecord]] = [:]
    var activeAlerts: [AlertRecord] = []
    var isLoading = false
    var errorMessage: String?
    var isConfigured = false

    private let storage = StorageManager()
    private let keychain = KeychainService.shared
    private var apiServices: [UUID: BeszelAPIService] = [:]
    private var loadTask: Task<Void, Never>?
    private var detailsTask: Task<Void, Never>?
    private var statsTask: Task<Void, Never>?
    private var alertTask: Task<Void, Never>?
    private var containerTask: Task<Void, Never>?

    private init() {
        loadInstances()
        isConfigured = !instances.isEmpty
        if selectedInstance != nil {
            loadSystems()
            loadSystemDetails()
            loadAlerts()
            loadContainers()
        }
    }

    func loadSystems() {
        guard let instance = selectedInstance else { return }

        loadTask?.cancel()
        loadTask = Task {
            isLoading = true
            errorMessage = nil

            defer { isLoading = false }

            do {
                let service = getOrCreateService(for: instance)
                let systems = try await service.fetchSystems()
                guard !Task.isCancelled else { return }
                selectedInstanceSystems = systems.sorted { $0.name < $1.name }
                loadSystemStats()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    func loadSystemDetails() {
        guard let instance = selectedInstance else { return }

        detailsTask?.cancel()
        detailsTask = Task {
            do {
                let service = getOrCreateService(for: instance)
                let details = try await service.fetchSystemDetails()
                guard !Task.isCancelled else { return }

                var mapped: [String: SystemDetailsRecord] = [:]
                for detail in details {
                    mapped[detail.system] = detail
                }
                systemDetails = mapped
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
            }
        }
    }

    func loadSystemStats() {
        guard let instance = selectedInstance else { return }

        let systemIDs = selectedInstanceSystems.map(\.id)
        guard !systemIDs.isEmpty else {
            systemStats = [:]
            return
        }

        statsTask?.cancel()
        statsTask = Task {
            do {
                let service = getOrCreateService(for: instance)
                let stats = try await service.fetchLatestSystemStats(for: systemIDs)
                guard !Task.isCancelled else { return }
                systemStats = stats
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
            }
        }
    }

    func gpus(for systemID: String) -> [GpuInfo] {
        systemStats[systemID]?.gpus ?? []
    }

    func disks(for systemID: String) -> [DiskInfo] {
        let raw = systemStats[systemID]?.disks ?? []
        let store = DiskAliasStore.shared
        let rootName = selectedInstanceSystems
            .first(where: { $0.id == systemID })?.info?.rdn

        // Disks sharing the same display name are merged into one group
        // (e.g. three array disks all named "Media" become a single row).
        var result: [DiskInfo] = []
        var groupIndexByName: [String: Int] = [:]

        for disk in raw {
            let alias = store.alias(systemID: systemID, diskID: disk.id)
            guard alias?.hidden != true else { continue }

            var name = disk.name
            if disk.isRoot, let rdn = rootName, !rdn.isEmpty {
                name = rdn
            }
            if let custom = alias?.name, !custom.isEmpty {
                name = custom
            }

            if let index = groupIndexByName[name] {
                let group = result[index]
                result[index] = DiskInfo(
                    id: group.id,
                    name: group.name,
                    usedGB: group.usedGB + disk.usedGB,
                    totalGB: group.totalGB + disk.totalGB,
                    isRoot: group.isRoot || disk.isRoot,
                    diskCount: group.diskCount + 1
                )
            } else {
                groupIndexByName[name] = result.count
                result.append(DiskInfo(
                    id: name,
                    name: name,
                    usedGB: disk.usedGB,
                    totalGB: disk.totalGB,
                    isRoot: disk.isRoot
                ))
            }
        }

        return result
    }

    /// Raw disk keys before aliasing/grouping, for the settings editor.
    func rawDiskEntries(for systemID: String) -> [(id: String, defaultName: String)] {
        let raw = systemStats[systemID]?.disks ?? []
        let rootName = selectedInstanceSystems
            .first(where: { $0.id == systemID })?.info?.rdn

        return raw.map { disk in
            var defaultName = disk.name
            if disk.isRoot, let rdn = rootName, !rdn.isEmpty {
                defaultName = rdn
            }
            return (disk.id, defaultName)
        }
    }

    func memoryInfo(for systemID: String) -> MemoryInfo? {
        systemStats[systemID]?.memory
    }

    func loadAlerts() {
        guard let instance = selectedInstance else { return }

        alertTask?.cancel()
        alertTask = Task {
            do {
                let service = getOrCreateService(for: instance)
                let alerts = try await service.fetchAlerts(filter: "enabled = true")
                guard !Task.isCancelled else { return }
                activeAlerts = alerts.filter { $0.triggered == true }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
            }
        }
    }

    func loadContainers() {
        guard let instance = selectedInstance else { return }

        containerTask?.cancel()
        containerTask = Task {
            do {
                let service = getOrCreateService(for: instance)
                let allContainers = try await service.fetchContainers()
                guard !Task.isCancelled else { return }

                var grouped: [String: [ContainerRecord]] = [:]
                for container in allContainers {
                    grouped[container.system, default: []].append(container)
                }
                containers = grouped
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
            }
        }
    }

    func selectInstance(_ instance: Instance?) {
        selectedInstance = instance
        selectedInstanceSystems = []
        systemDetails = [:]
        statsTask?.cancel()
        statsTask = nil
        systemStats = [:]
        containers = [:]
        activeAlerts = []
        loadSystems()
        loadSystemDetails()
        loadAlerts()
        loadContainers()
        storage.saveSelectedInstanceID(instance?.id)
    }

    func addInstance(_ instance: Instance) {
        keychain.saveCredential(instance.credential, for: instance.id.uuidString)

        var storedInstance = instance
        storedInstance.credential = ""
        instances.append(storedInstance)
        saveInstances()

        if selectedInstance == nil {
            selectInstance(instance)
        }
        isConfigured = true
    }

    func removeInstance(_ instance: Instance) {
        keychain.deleteCredential(for: instance.id.uuidString)
        apiServices.removeValue(forKey: instance.id)
        instances.removeAll { $0.id == instance.id }
        saveInstances()

        if selectedInstance?.id == instance.id {
            selectedInstance = instances.first
            selectedInstanceSystems = []
            systemDetails = [:]
            statsTask?.cancel()
            statsTask = nil
            systemStats = [:]
            containers = [:]
            activeAlerts = []
            if selectedInstance != nil {
                loadSystems()
                loadSystemDetails()
                loadAlerts()
                loadContainers()
            }
        }
        isConfigured = !instances.isEmpty
    }

    func updateInstance(_ instance: Instance) {
        if !instance.credential.isEmpty {
            keychain.updateCredential(instance.credential, for: instance.id.uuidString)
        }

        apiServices.removeValue(forKey: instance.id)

        if let index = instances.firstIndex(where: { $0.id == instance.id }) {
            var storedInstance = instance
            storedInstance.credential = ""
            instances[index] = storedInstance
            saveInstances()
        }

        if selectedInstance?.id == instance.id {
            selectInstance(instance)
        }
    }

    func instanceWithCredential(_ instance: Instance) -> Instance {
        var fullInstance = instance
        fullInstance.credential = keychain.loadCredential(for: instance.id.uuidString) ?? ""
        return fullInstance
    }

    private func loadInstances() {
        instances = storage.loadInstances()

        if let savedID = storage.loadSelectedInstanceID(),
           let instance = instances.first(where: { $0.id == savedID }) {
            selectedInstance = instance
        } else {
            selectedInstance = instances.first
        }
    }

    private func saveInstances() {
        storage.saveInstances(instances)
    }

    private func getOrCreateService(for instance: Instance) -> BeszelAPIService {
        if let existing = apiServices[instance.id] {
            return existing
        }

        let fullInstance = instanceWithCredential(instance)
        let service = BeszelAPIService(instance: fullInstance)
        apiServices[instance.id] = service
        return service
    }
}

struct Instance: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var name: String
    var url: String
    var email: String
    var credential: String

    init(id: UUID = UUID(), name: String, url: String, email: String, credential: String) {
        self.id = id
        self.name = name
        self.url = url
        self.email = email
        self.credential = credential
    }

    enum CodingKeys: String, CodingKey {
        case id, name, url, email
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        url = try container.decode(String.self, forKey: .url)
        email = try container.decode(String.self, forKey: .email)
        credential = ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(url, forKey: .url)
        try container.encode(email, forKey: .email)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: Instance, rhs: Instance) -> Bool {
        lhs.id == rhs.id
    }
}

struct DiskAlias: Codable, Equatable {
    var name: String = ""
    var hidden: Bool = false
}

/// Per-system disk renames and visibility, persisted to UserDefaults.
/// Needed because the Beszel hub only reports device names as keys.
@MainActor
final class DiskAliasStore: ObservableObject {
    static let shared = DiskAliasStore()

    private static let storageKey = "com.nohitdev.BeszelBar.diskAliases"
    private let defaults = UserDefaults.standard

    @Published private(set) var aliases: [String: [String: DiskAlias]] = [:]

    private init() {
        if let data = defaults.data(forKey: Self.storageKey),
           let stored = try? JSONDecoder().decode([String: [String: DiskAlias]].self, from: data) {
            aliases = stored
        }
    }

    func alias(systemID: String, diskID: String) -> DiskAlias? {
        aliases[systemID]?[diskID]
    }

    /// Stored keys for a system, including disks that are currently hidden.
    func storedDiskIDs(systemID: String) -> [String] {
        Array(aliases[systemID]?.keys ?? [:].keys).sorted()
    }

    func setAlias(_ alias: DiskAlias?, systemID: String, diskID: String) {
        if alias == nil || (alias?.name.isEmpty == true && alias?.hidden == false) {
            aliases[systemID]?[diskID] = nil
            if aliases[systemID]?.isEmpty == true {
                aliases[systemID] = nil
            }
        } else {
            aliases[systemID, default: [:]][diskID] = alias
        }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(aliases) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

final class StorageManager {
    private let defaults = UserDefaults.standard
    private let instancesKey = "com.nohitdev.BeszelBar.instances"
    private let selectedInstanceKey = "com.nohitdev.BeszelBar.selectedInstance"

    func saveInstances(_ instances: [Instance]) {
        guard let data = try? JSONEncoder().encode(instances) else { return }
        defaults.set(data, forKey: instancesKey)
    }

    func loadInstances() -> [Instance] {
        guard let data = defaults.data(forKey: instancesKey),
              let instances = try? JSONDecoder().decode([Instance].self, from: data) else {
            return []
        }
        return instances
    }

    func saveSelectedInstanceID(_ id: UUID?) {
        if let id = id {
            defaults.set(id.uuidString, forKey: selectedInstanceKey)
        } else {
            defaults.removeObject(forKey: selectedInstanceKey)
        }
    }

    func loadSelectedInstanceID() -> UUID? {
        guard let string = defaults.string(forKey: selectedInstanceKey) else { return nil }
        return UUID(uuidString: string)
    }
}
