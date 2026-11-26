import Foundation

enum RemoteOrderStatus: Int, CaseIterable {
    case unpaid = 0, closed = 1, inUse = 2, completed = 3, refunding = 4, refunded = 5
}

enum OrderStates {
    static func apply(_ order: LocalOrder, _ status: RemoteOrderStatus) -> LocalOrder {
        var result = order
        switch status {
        case .unpaid: break
        case .closed: result.phase = .closed
        case .inUse: result.phase = .paid; result.syncRequested = true
        case .completed: result.phase = .completed; result.syncRequested = true
        case .refunding: result.phase = .refunding; result.syncRequested = true
        case .refunded: result.phase = .refunded; result.syncRequested = true
        }
        return result
    }
}

enum LaundryProgressProtocol {
    static func parseTimestamp(_ raw: String?) -> Double? {
        guard let value = raw?.trimmingCharacters(in: .whitespaces),
              value.range(of: "^\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2}$", options: .regularExpression) != nil else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.isLenient = false
        return formatter.date(from: value)?.timeIntervalSince1970
    }

    static func parseMinutes(_ raw: String?) -> Int? {
        guard let value = raw?.trimmingCharacters(in: .whitespaces),
              value.range(of: "^\\d{1,6}$", options: .regularExpression) != nil,
              let minutes = Int(value), minutes > 0 else { return nil }
        return minutes
    }

    static func parse(_ data: [String: Any], _ order: LocalOrder, _ status: RemoteOrderStatus, _ now: Double) -> LaundryProgress? {
        if !order.isLaundry || jText(data, "orderType") == "3" { return nil }
        guard status == .inUse || status == .completed else { return nil }
        let machineId = jText(data, "machineId")
        return LaundryProgress(
            orderId: jText(data, "id").isEmpty ? order.orderId : jText(data, "id"),
            orderNo: jText(data, "orderNo").isEmpty ? order.orderNo : jText(data, "orderNo"),
            deviceId: machineId.isEmpty ? nil : machineId,
            totalMinutes: parseMinutes(jText(data, "markMinutes")),
            startedAt: parseTimestamp(jText(data, "beginTime")),
            expectedEndAt: parseTimestamp(jText(data, "completeTime")),
            finishedAt: parseTimestamp(jText(data, "finishTime")),
            statusWire: status.rawValue,
            updatedAt: now)
    }
}

enum OrderHistory {
    static let limit = 20

    static func sameOrder(_ a: LocalOrder, _ b: LocalOrder) -> Bool {
        if a.owner != b.owner || a.workflowKind != b.workflowKind { return false }
        if !a.orderId.isEmpty && !b.orderId.isEmpty && a.orderId != b.orderId { return false }
        if !a.orderNo.isEmpty && !b.orderNo.isEmpty && a.orderNo != b.orderNo { return false }
        if !a.orderId.isEmpty && a.orderId == b.orderId { return true }
        if !a.orderNo.isEmpty && a.orderNo == b.orderNo { return true }
        let aHasIdentity = !a.orderId.isEmpty || !a.orderNo.isEmpty
        let bHasIdentity = !b.orderId.isEmpty || !b.orderNo.isEmpty
        if aHasIdentity && bHasIdentity { return false }
        return a.createdAt == b.createdAt && a.deviceName == b.deviceName &&
            a.modeName == b.modeName && a.payMethod == b.payMethod && a.amount == b.amount
    }

    static func merge(_ owner: String, _ existing: [LocalOrder], _ incoming: LocalOrder?) -> [LocalOrder] {
        if owner.isEmpty { return [] }
        var result: [LocalOrder] = []
        for order in existing + (incoming.map { [$0] } ?? []) {
            if order.owner != owner { continue }
            if let index = result.firstIndex(where: { sameOrder($0, order) }) {
                let previous = result[index]
                var merged = order
                merged.createdAt = previous.createdAt
                if merged.orderId.isEmpty { merged.orderId = previous.orderId }
                if merged.orderNo.isEmpty { merged.orderNo = previous.orderNo }
                merged.thirdChannel = order.thirdChannel ?? previous.thirdChannel
                merged.outVoucherId = order.outVoucherId ?? previous.outVoucherId
                merged.category = order.category ?? previous.category
                merged.syncRequested = order.syncRequested || previous.syncRequested
                result[index] = merged
            } else {
                result.append(order)
            }
        }
        return result.sorted { a, b in
            if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
            return key(a) < key(b)
        }.prefix(limit).map { $0 }
    }

    static func key(_ order: LocalOrder) -> String {
        var identity: [String]
        if !order.orderNo.isEmpty {
            identity = ["number", order.orderNo, order.orderId]
        } else if !order.orderId.isEmpty {
            identity = ["id", order.orderId]
        } else {
            identity = ["attempt", String(order.createdAt), order.deviceName, order.modeName,
                        order.workflowKind, order.payMethod.rawValue, order.amount]
        }
        return ([order.owner, order.workflowKind] + identity).map { "\($0.count):\($0)" }.joined()
    }
}