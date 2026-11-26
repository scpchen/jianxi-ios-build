import Foundation

struct DeviceCode: Equatable {
    let key: String
    let value: String
}

struct DryerDuration: Equatable, Codable {
    let minutes: Int
    let price: String
    let description: String
    let selectedByPlatform: Bool
}

struct WashMode: Equatable, Identifiable {
    let id: String
    let name: String
    let price: String
    let feature: String
    let dryerDurations: [DryerDuration]
    init(_ id: String, _ name: String, _ price: String, _ feature: String = "", _ durations: [DryerDuration] = []) {
        self.id = id; self.name = name; self.price = price; self.feature = feature; self.dryerDurations = durations
    }
}

struct Device: Equatable {
    let id: String
    let name: String
    let imei: String
    let category: String
    let shopId: String
    let orgId: String
    let remainingMinutes: Int
    let modes: [WashMode]
    let error: String
    var isDryer: Bool { category == "02" }
}

struct Quote {
    let device: Device
    let mode: WashMode
    let amount: String
    let itemsJson: String
    let tradeType: Int
    let dryerDuration: DryerDuration?
}

enum PayMethod: String, Codable, CaseIterable {
    case alipay = "13"
    case balance = "2"
    var title: String { self == .alipay ? "支付宝" : "账户余额" }
}

struct PayRoute: Equatable {
    let method: PayMethod
    let thirdChannel: String
    let outVoucherId: String
    init(_ method: PayMethod, _ thirdChannel: String = "", _ outVoucherId: String = "") {
        self.method = method; self.thirdChannel = thirdChannel; self.outVoucherId = outVoucherId
    }
    var title: String { method.title }
}

struct LocationFix {
    let latitude: Double
    let longitude: Double
}

enum OrderPhase: String, Codable {
    case creating, unconfirmed, created, paymentPending, paid, cancelled, rejected, closed, completed, refunding, refunded
    var finished: Bool {
        switch self {
        case .paid, .cancelled, .rejected, .closed, .completed, .refunding, .refunded: return true
        default: return false
        }
    }
    var title: String {
        switch self {
        case .creating: return "创建中"
        case .unconfirmed: return "结果未确认"
        case .created: return "待付款"
        case .paymentPending: return "付款确认中"
        case .paid: return "已付款"
        case .cancelled: return "已取消"
        case .rejected: return "已拒绝"
        case .closed: return "已关闭"
        case .completed: return "已完成"
        case .refunding: return "退款中"
        case .refunded: return "已退款"
        }
    }
}

struct LaundryProgress: Codable, Equatable {
    let orderId: String
    let orderNo: String
    let deviceId: String?
    let totalMinutes: Int?
    let startedAt: Double?
    let expectedEndAt: Double?
    let finishedAt: Double?
    let statusWire: Int
    let updatedAt: Double
    var running: Bool { statusWire == 2 }
    var completionConfirmed: Bool { statusWire == 3 }
    func remainingSeconds(now: Double) -> Double? {
        guard let end = expectedEndAt else { return nil }
        return max(0, end - now)
    }
    func remainingFraction(now: Double) -> Double? {
        guard let total = totalMinutes, total > 0, let remaining = remainingSeconds(now: now) else { return nil }
        return min(1, max(0, remaining / (Double(total) * 60)))
    }
}

struct LocalOrder: Codable, Equatable, Identifiable {
    let owner: String
    let deviceName: String
    let modeName: String
    let amount: String
    let payMethod: PayMethod
    var phase: OrderPhase
    var createdAt: Double
    var orderId: String
    var orderNo: String
    var syncRequested: Bool
    var thirdChannel: String?
    var outVoucherId: String?
    var category: String?
    var progress: LaundryProgress?
    var id: String { OrderHistory.key(self) }
    var isWater: Bool { category == "04" }
    var isDryer: Bool { category == "02" }
    var isLaundry: Bool { category == nil || category == "" || category == "00" || category == "01" }
    var workflowKind: String { isWater ? "water" : (isDryer ? "dryer" : "laundry") }
    init(owner: String, deviceName: String, modeName: String, amount: String, payMethod: PayMethod, phase: OrderPhase,
         createdAt: Double = Date().timeIntervalSince1970, orderId: String = "", orderNo: String = "",
         syncRequested: Bool = false, thirdChannel: String? = nil, outVoucherId: String? = nil,
         category: String? = nil, progress: LaundryProgress? = nil) {
        self.owner = owner; self.deviceName = deviceName; self.modeName = modeName; self.amount = amount
        self.payMethod = payMethod; self.phase = phase; self.createdAt = createdAt; self.orderId = orderId
        self.orderNo = orderNo; self.syncRequested = syncRequested; self.thirdChannel = thirdChannel
        self.outVoucherId = outVoucherId; self.category = category; self.progress = progress
    }
}

class ClientError: Error, LocalizedError {
    let msg: String
    init(_ msg: String) { self.msg = msg }
    var errorDescription: String? { msg }
}

final class BusinessRejected: ClientError {
    let code: Int
    let operation: String?
    init(_ code: Int, _ msg: String, _ operation: String? = nil) {
        self.code = code; self.operation = operation
        super.init(msg)
    }
    var display: String {
        if let op = operation { return "\(op)：\(msg)（错误码 \(code)）" }
        return msg
    }
}

final class SessionExpired: ClientError {
    init() { super.init("登录已过期，请重新登录") }
}

final class PointsDeductionDetected: ClientError {
    init() { super.init("平台为这笔订单应用了不支持的抵扣，已停止付款。请在原应用调整后重试") }
}

final class PointsPaymentUnconfirmed: ClientError {
    init() { super.init("无法核对订单抵扣明细，已停止付款。请刷新订单后重试") }
}

final class PaymentSubmittedUnconfirmed: ClientError {
    init() { super.init("付款请求已提交，请刷新订单查询最终状态") }
}

final class NetworkUnavailable: ClientError {
    init() { super.init("网络不可用，请检查网络后重试") }
}

final class QuoteChanged: Error {
    let quote: Quote
    init(_ quote: Quote) { self.quote = quote }
}

final class WaterStartNotSent: ClientError {}

final class WaterCommandSubmittedUnconfirmed: ClientError {
    init() { super.init("用水指令已提交，请刷新查询状态；如设备正在出水，请确认后结束用水") }
}

func money(_ raw: String) throws -> String {
    guard let value = Decimal(string: raw), !value.isNaN else { throw ClientError("金额格式异常，请刷新后重试") }
    guard value >= 0 else { throw ClientError("金额异常，请刷新后重试") }
    var input = value
    var rounded = Decimal()
    NSDecimalRound(&rounded, &input, 2, .plain)
    guard rounded == value else { throw ClientError("金额精度异常，请刷新后重试") }
    return String(format: "%.2f", NSDecimalNumber(decimal: rounded).doubleValue)
}