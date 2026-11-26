import Foundation
import Security

struct SavedDevice: Codable, Equatable, Identifiable {
    let owner: String
    let key: String
    let value: String
    var name: String
    let category: String
    var note: String
    let savedAt: Double
    var id: String { "\(owner)|\(key)|\(value)" }
    var kind: String {
        switch category {
        case "02": return "dryer"
        case "04": return "water"
        default: return "laundry"
        }
    }
}

final class SessionVault {
    static let shared = SessionVault()
    private let defaults = UserDefaults.standard
    private let service = "dev.rain.jianxi.session"

    private func keychainSet(_ account: String, _ value: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        if value.isEmpty { return }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    private func keychainGet(_ account: String) -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let value = String(data: data, encoding: .utf8) else { return "" }
        return value
    }

    func token() -> String { keychainGet("token") }
    func phone() -> String { keychainGet("phone") }
    func owner() -> String {
        let p = phone()
        return p.isEmpty ? "" : WireProtocol.sha256(p)
    }
    func phoneLabel() -> String {
        let p = phone()
        guard p.count == 11 else { return p }
        return "\(p.prefix(3))****\(p.suffix(4))"
    }
    func loggedIn() -> Bool { !token().isEmpty && !phone().isEmpty }

    func login(phone: String, token: String) {
        keychainSet("phone", phone)
        keychainSet("token", token)
    }

    func logout() {
        keychainSet("phone", "")
        keychainSet("token", "")
    }

    private func decode<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func encode<T: Encodable>(_ value: T?, _ key: String) {
        guard let value = value, let data = try? JSONEncoder().encode(value) else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(data, forKey: key)
    }

    func order() -> LocalOrder? {
        guard !owner().isEmpty else { return nil }
        return decode(LocalOrder.self, "currentOrder.\(owner())")
    }

    func saveOrder(_ order: LocalOrder?) {
        guard !owner().isEmpty else { return }
        encode(order, "currentOrder.\(owner())")
        if let order = order {
            let merged = OrderHistory.merge(owner(), orders(), order)
            encode(merged, "orders.\(owner())")
        }
    }

    func orders() -> [LocalOrder] {
        guard !owner().isEmpty else { return [] }
        return decode([LocalOrder].self, "orders.\(owner())") ?? []
    }

    func water() -> WaterSession? {
        guard !owner().isEmpty else { return nil }
        return decode(WaterSession.self, "water.\(owner())")
    }

    func saveWater(_ session: WaterSession?) {
        guard !owner().isEmpty else { return }
        encode(session, "water.\(owner())")
    }

    func savedDevices() -> [SavedDevice] {
        guard !owner().isEmpty else { return [] }
        return (decode([SavedDevice].self, "devices.\(owner())") ?? []).filter { $0.owner == owner() }
    }

    func saveSavedDevices(_ devices: [SavedDevice]) {
        guard !owner().isEmpty else { return }
        encode(devices, "devices.\(owner())")
    }

    var consentAccepted: Bool {
        get { defaults.bool(forKey: "consentAccepted") }
        set { defaults.set(newValue, forKey: "consentAccepted") }
    }

    var appearance: String {
        get { defaults.string(forKey: "appearance") ?? "system" }
        set { defaults.set(newValue, forKey: "appearance") }
    }

    var progressReminderEnabled: Bool {
        get { defaults.bool(forKey: "progressReminderEnabled") }
        set { defaults.set(newValue, forKey: "progressReminderEnabled") }
    }
}