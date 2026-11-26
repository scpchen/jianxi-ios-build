import Foundation

struct WaterOutlet: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let rate: String
    let feature: String
}

struct WaterPayRoute: Codable, Equatable {
    let wire: String
    let method: PayMethod
    let preferred: Bool
    var requiresAlipayAgreement: Bool { wire == "15" && method == .alipay }
    var title: String {
        if requiresAlipayAgreement { return "支付宝先享后付（免密）" }
        if method == .alipay { return "支付宝支付" }
        return method.title
    }
    static let balance = WaterPayRoute(wire: "2", method: .balance, preferred: false)
}

struct WaterDevice: Codable, Equatable {
    let id: String
    let name: String
    let imei: String
    let shopId: String
    let orgId: String
    let outlets: [WaterOutlet]
    let supportAppFinish: Bool
    let error: String
    let announcement: String
    let tradeMain: Int?
}

struct WaterStatus: Codable, Equatable {
    let status: Int
    let workStatus: Int
    let amount: String
    let identify: String
    var ended: Bool { status == 3 || status == 5 }
    var mine: Bool { workStatus == 2 && !ended && status != 6 }
    var available: Bool { workStatus == 1 }
}

enum WaterPhase: String, Codable {
    case starting, waiting, using, ending, settling, ended, unknown, rejected
}

struct WaterSession: Codable, Equatable {
    let owner: String
    var device: WaterDevice
    let outlet: WaterOutlet
    var phase: WaterPhase
    var orderNo: String
    var msgId: String
    var amount: String
    var identify: String
    var startedAt: Double
    var lastStatus: WaterStatus?
    var initialIdentify: String
    var observedRunning: Bool
    var payment: WaterPayRoute?
    var recovered: Bool
    var active: Bool { phase != .ended && phase != .rejected }
    init(owner: String, device: WaterDevice, outlet: WaterOutlet, phase: WaterPhase, orderNo: String = "",
         msgId: String = "", amount: String = "", identify: String = "", startedAt: Double = Date().timeIntervalSince1970,
         lastStatus: WaterStatus? = nil, initialIdentify: String = "", observedRunning: Bool = false,
         payment: WaterPayRoute? = nil, recovered: Bool = false) {
        self.owner = owner; self.device = device; self.outlet = outlet; self.phase = phase
        self.orderNo = orderNo; self.msgId = msgId; self.amount = amount; self.identify = identify
        self.startedAt = startedAt; self.lastStatus = lastStatus; self.initialIdentify = initialIdentify
        self.observedRunning = observedRunning; self.payment = payment; self.recovered = recovered
    }
}

struct WaterStart {
    let orderNo: String
    let msgId: String
    let verificationIssue: ClientError?
}

struct WaterAlipayRequirement {
    let tradeMain: Int
    let needsSigning: Bool
    let forcedByDevice: Bool
}

enum ScannedDevice {
    case laundry(Device)
    case dryer(Device)
    case water(WaterDevice)
}

enum WaterRules {
    private static func falseFlag(_ value: String) -> Bool {
        value == "" || value == "0" || value == "false"
    }

    static func paymentRoutes(_ data: Any) throws -> [WaterPayRoute] {
        guard let array = jArray(data) else { throw ClientError("饮水支付方式格式尚未适配") }
        var routes: [WaterPayRoute] = []
        for item in array {
            guard let row = jObject(item) else { continue }
            if !falseFlag(jText(row, "isThird", "0")) || !jText(row, "thirdChannel").isEmpty ||
                !["", "0"].contains(jText(row, "pgVipType", "0")) || ["0", "false"].contains(jText(row, "canChecked", "true")) {
                continue
            }
            let wire = jText(row, "method")
            var method: PayMethod?
            if wire == "2" {
                method = falseFlag(jText(row, "needOpenFlag", "0")) ? .balance : nil
            } else if ["13", "15", "103"].contains(wire) {
                method = .alipay
            }
            guard let m = method else { continue }
            let route = WaterPayRoute(wire: wire, method: m, preferred: ["1", "true"].contains(jText(row, "defaultFlag")))
            if !routes.contains(where: { $0.wire == route.wire }) { routes.append(route) }
        }
        var grouped: [PayMethod: [WaterPayRoute]] = [:]
        for route in routes { grouped[route.method, default: []].append(route) }
        let result = grouped.values.map { choices in choices.first { $0.preferred } ?? choices[0] }
        if result.isEmpty {
            let unionPay = array.contains { jObject($0).map { jText($0, "method") == "53" } ?? false }
            throw ClientError(unionPay ? "这台饮水机当前仅提供云闪付免密等未适配渠道，请先在原应用使用"
                : "这台饮水机暂未提供可用的余额或支付宝渠道，请在原应用核对支付方式")
        }
        return result
    }

    static func promotions() -> String {
        let entries = ["-6", "-7", "-8"].map { type in
            "{\"promotionId\":\"0\",\"promotionType\":\"\(type)\",\"assetId\":\"0\",\"oldPromotionId\":\"\(type == "-8" ? "0" : "")\",\"orgId\":\"0\"}"
        }
        return "[" + entries.joined(separator: ",") + "]"
    }

    static func decimal(_ raw: String) throws -> String {
        guard let value = Decimal(string: raw), !value.isNaN else { throw ClientError("饮水计费数据格式异常，请刷新设备") }
        guard value >= 0, value <= Decimal(string: "1000000000")! else { throw ClientError("饮水计费数据异常，请刷新设备") }
        var input = value
        var rounded = Decimal()
        NSDecimalRound(&rounded, &input, 12, .plain)
        guard rounded == value else { throw ClientError("饮水计费数据异常，请刷新设备") }
        return NSDecimalNumber(decimal: value).stringValue
    }

    private static func objectValue(_ value: Any?) -> [String: Any]? {
        if let obj = jObject(value) { return obj }
        if let s = value as? String, let data = s.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return obj }
        return nil
    }

    static func device(_ detail: [String: Any], _ skus: Any) throws -> WaterDevice {
        guard jText(detail, "categoryCode") == "04" else { throw ClientError("请扫描饮水机二维码") }
        guard jText(detail, "isBluetooth", "0") == "0" else { throw ClientError("这台饮水机需要蓝牙连接，请先使用原应用取水") }
        guard jText(detail, "payment") == "after" else { throw ClientError("这台饮水机不是已适配的按用量后付费设备，请先使用原应用") }
        let id = jText(detail, "goodsId")
        guard !id.isEmpty else { throw ClientError("饮水机详情缺少设备编号") }
        let imei = jText(detail, "imei")
        guard !imei.isEmpty else { throw ClientError("饮水机详情缺少设备标识") }
        let orgId = jText(detail, "orgId")
        guard Int(orgId) != nil else { throw ClientError("饮水机机构编号无效，请重新扫码") }
        var data = skus
        if let obj = jObject(skus), jHas(obj, "code") { data = obj["data"] as Any }
        var array: [Any]?
        if let a = jArray(data) { array = a }
        else if let obj = jObject(data) {
            for key in ["skus", "skuList", "list"] {
                if let a = jArray(obj[key]) { array = a; break }
            }
        }
        guard let skuArray = array else { throw ClientError("饮水机出水口数据格式尚未适配") }
        let flowmeter = objectValue(detail["extAttr"]).map { Int(jText($0, "flowmeter")) } ?? nil
        var outlets: [WaterOutlet] = []
        for element in skuArray {
            guard let item = jObject(element) else { continue }
            let skuId = jText(item, "skuId")
            if skuId.isEmpty || jText(item, "scanAvailable", "true") == "false" { continue }
            let levels = objectValue(item["extAttr"]).flatMap { jArray($0["level"]) }
            let price = (levels?.first).flatMap { jObject($0) }.map { jText($0, "price") } ?? ""
            let unit = flowmeter == 1 ? "升" : (flowmeter == 0 ? "秒" : "")
            var rate = ""
            if !price.isEmpty && !unit.isEmpty {
                rate = "\(try decimal(price)) 元/\(unit)" + ((levels?.count ?? 0) > 1 ? "起（阶梯计费）" : "")
            }
            outlets.append(WaterOutlet(id: skuId, name: jText(item, "name", "出水口"), rate: rate, feature: jText(item, "feature")))
        }
        guard !outlets.isEmpty else { throw ClientError("饮水机当前没有可用出水口") }
        let tradeMain = Int(jText(detail, "tradeMain")).flatMap { $0 >= 0 ? $0 : nil }
        return WaterDevice(id: id, name: jText(detail, "name", "饮水机"), imei: imei, shopId: jText(detail, "shopId"),
                           orgId: orgId, outlets: outlets, supportAppFinish: jText(detail, "supportAppUserFinish") == "true",
                           error: jText(detail, "deviceErrorMsg"), announcement: jText(detail, "announcementContent"), tradeMain: tradeMain)
    }

    static func status(_ data: Any) throws -> WaterStatus {
        guard let value = jObject(data) else { throw ClientError("饮水状态尚未确认，请稍后刷新") }
        guard let status = Int(jText(value, "status")), (0...6).contains(status) else { throw ClientError("饮水状态格式尚未适配") }
        guard let work = Int(jText(value, "workStatus", "0")), (0...3).contains(work) else { throw ClientError("饮水设备占用状态格式尚未适配") }
        let rawAmount = jText(value, "amount")
        let amount = rawAmount.isEmpty ? "" : try decimal(rawAmount)
        return WaterStatus(status: status, workStatus: work, amount: amount, identify: jText(value, "identify"))
    }

    static func apply(_ session: WaterSession, _ status: WaterStatus) -> WaterSession {
        let runningSeen = session.observedRunning || session.phase == .using || session.phase == .ending || status.mine
        let freshResult = runningSeen || (!status.identify.isEmpty &&
            (status.identify != session.initialIdentify || status.identify == session.orderNo))
        let phase: WaterPhase
        if status.status == 6 || status.workStatus == 3 {
            phase = .unknown
        } else if status.ended && !freshResult {
            phase = (session.phase == .starting || session.phase == .waiting) ? .waiting : .unknown
        } else if status.ended {
            let positive = !status.amount.isEmpty && (Decimal(string: status.amount) ?? 0) > 0
            phase = positive ? .settling : .ended
        } else if status.mine {
            phase = session.phase == .ending ? .ending : .using
        } else {
            phase = (session.phase == .starting || session.phase == .waiting) ? .waiting : .unknown
        }
        var result = session
        result.phase = phase
        result.lastStatus = status
        result.amount = status.amount
        result.observedRunning = runningSeen
        if !status.identify.isEmpty { result.identify = status.identify }
        return result
    }
}