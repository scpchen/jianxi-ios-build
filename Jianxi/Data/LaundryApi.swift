import Foundation

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

final class LaundryApi {
    private let tokenProvider: () -> String
    private let brand = "iPhone"
    private let baseUrl = "https://userapi.qiekj.com/"
    private let session: URLSession

    static let anonymousPaths: Set<String> = ["common/sms/sendCode", "user/reg"]
    static let allowedPaths: Set<String> = [
        "common/sms/sendCode", "user/reg", "goods/scan/v2", "goods/normal/details",
        "goods/normal/skus", "trade/preview/v4", "trade/create", "payChannelRoute/prePay",
        "pay/unify/prePay", "pay/unify/pay", "order/pay_status", "order/detail", "order/sync", "order/cancel",
        "appoint/checkMachineCanUse", "goods/water/unlock", "goods/water/sync", "goods/endWater", "machine/msg/sync",
        "payChannelRoute/afterPay", "payChannelRoute/addUserAfterPayChannel", "payChannelRoute/againPay",
        "order/afterPay/creating", "popup/shop", "alipay/isSign"
    ]
    static let paymentOperations: [String: String] = [
        "appoint/checkMachineCanUse": "核对设备状态失败",
        "trade/preview/v4": "核对洗衣金额失败",
        "trade/create": "创建订单失败",
        "payChannelRoute/prePay": "获取支付方式失败",
        "pay/unify/prePay": "获取支付信息失败",
        "pay/unify/pay": "余额付款未完成",
        "order/pay_status": "查询付款状态失败",
        "order/detail": "查询订单详情失败",
        "order/cancel": "取消订单失败",
        "goods/water/unlock": "启动饮水机失败",
        "goods/water/sync": "查询饮水状态失败",
        "goods/endWater": "结束用水未确认",
        "machine/msg/sync": "查询启动指令失败",
        "payChannelRoute/afterPay": "查询饮水支付方式失败",
        "payChannelRoute/addUserAfterPayChannel": "选择饮水支付方式失败",
        "payChannelRoute/againPay": "查询饮水账单支付方式失败",
        "order/afterPay/creating": "查询饮水结算失败",
        "popup/shop": "核对本设备免密授权要求失败",
        "alipay/isSign": "查询支付宝免密签约状态失败"
    ]

    init(token: @escaping () -> String) {
        self.tokenProvider = token
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        config.httpShouldSetCookies = false
        self.session = URLSession(configuration: config, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }

    private func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._*")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    private func dataTask(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: request) { data, response, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let data = data, let response = response {
                    continuation.resume(returning: (data, response))
                } else {
                    continuation.resume(throwing: URLError(.badServerResponse))
                }
            }
            task.resume()
        }
    }

    func post(_ path: String, _ fields: [String: String], risk: (Device, LocationFix)? = nil) async throws -> Any {
        guard Self.allowedPaths.contains(path) else { throw ClientError("不支持的业务接口") }
        let anonymous = Self.anonymousPaths.contains(path)
        let authorization = anonymous ? "" : tokenProvider()
        let timestamp = String(Int64(Date().timeIntervalSince1970 * 1000))
        var formPairs = fields.map { "\(formEncode($0.key))=\(formEncode($0.value))" }
        if !authorization.isEmpty { formPairs.append("token=\(formEncode(authorization))") }
        var request = URLRequest(url: URL(string: baseUrl + path)!)
        request.httpMethod = "POST"
        request.httpBody = Data(formPairs.joined(separator: "&").utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue(WireProtocol.version, forHTTPHeaderField: "Version")
        request.setValue(WireProtocol.channel, forHTTPHeaderField: "channel")
        request.setValue(brand, forHTTPHeaderField: "phoneBrand")
        request.setValue("", forHTTPHeaderField: "deviceId")
        request.setValue(timestamp, forHTTPHeaderField: "timestamp")
        request.setValue(WireProtocol.sign("/\(path)", authorization, timestamp), forHTTPHeaderField: "sign")
        request.setValue("QEUser/\(WireProtocol.version) (com.qiekj.user; build:294; Android; userChannel:android_app) OkHttp/4.12.0", forHTTPHeaderField: "User-Agent")
        if let (device, fix) = risk {
            request.setValue(device.imei, forHTTPHeaderField: "imei")
            request.setValue(device.category, forHTTPHeaderField: "categoryCode")
            request.setValue(String(fix.latitude), forHTTPHeaderField: "lat")
            request.setValue(String(fix.longitude), forHTTPHeaderField: "lng")
            request.setValue(timestamp, forHTTPHeaderField: "orderRiskTimestamp")
            request.setValue(WireProtocol.riskSign("/\(path)", authorization, timestamp, device.imei, device.category, fix), forHTTPHeaderField: "orderRiskSign")
        }
        let started = Date()
        var status = "INVALID_RESPONSE"
        var errorCode: Int?
        defer {
            if Self.paymentOperations[path] != nil {
                DiagnosticsLog.shared.record(path, status, Int(Date().timeIntervalSince(started) * 1000), errorCode)
            }
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await dataTask(request)
        } catch let error as ClientError {
            throw error
        } catch {
            status = "NETWORK_ERROR"
            throw NetworkUnavailable()
        }
        guard let http = response as? HTTPURLResponse else {
            status = "INVALID_RESPONSE"
            throw ClientError("服务器返回格式变化，暂时无法处理")
        }
        if http.statusCode == 401 && !anonymous {
            status = "SESSION_EXPIRED"
            throw SessionExpired()
        }
        if http.statusCode == 403 {
            status = "REJECTED"
            errorCode = 403
            throw BusinessRejected(403, "本次请求被平台拒绝，请稍后重试（403）", Self.paymentOperations[path])
        }
        guard (200..<300).contains(http.statusCode) else {
            status = "HTTP_ERROR"
            errorCode = http.statusCode
            throw ClientError("服务暂时不可用（\(http.statusCode)）")
        }
        guard data.count <= 2_000_000 else { throw ClientError("服务器返回内容过大") }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ClientError("服务器返回格式变化，暂时无法处理")
        }
        guard let code = Int(jText(root, "code")) else { throw ClientError("服务器响应缺少有效状态码") }
        if code != 0 {
            errorCode = code
            let message = String(jText(root, "msg", "请求失败（\(code)）").prefix(180))
            if !anonymous && (code == 401 || ["未登录", "登录已过期", "登录失效", "请重新登录"].contains(message)) {
                status = "SESSION_EXPIRED"
                throw SessionExpired()
            }
            status = "REJECTED"
            if code == 2128 && path == "goods/normal/skus" {
                throw BusinessRejected(code, "此设备存在未支付订单，请先在原应用处理")
            }
            throw BusinessRejected(code, message, Self.paymentOperations[path])
        }
        status = "SUCCESS"
        return root["data"] ?? NSNull()
    }

    func sendCode(_ phone: String) async throws {
        _ = try await post("common/sms/sendCode", ["phone": phone, "template": "reg"])
    }

    func login(_ phone: String, _ code: String) async throws -> String {
        let result = try await post("user/reg", ["channel": WireProtocol.channel, "phone": phone, "verify": code])
        guard let obj = jObject(result) else { throw ClientError("登录响应缺少会话信息") }
        let token = jText(obj, "token")
        guard !token.isEmpty else { throw ClientError("登录响应缺少会话信息") }
        return token
    }

    private func deviceDetails(_ code: DeviceCode) async throws -> ([String: Any], [String: Any]) {
        let scanResult = try await post("goods/scan/v2", [code.key: code.value])
        guard let scan = jObject(scanResult) else { throw ClientError("设备识别响应格式尚未适配") }
        if jText(scan, "jumpToAlipayFlag2") == "true" {
            throw ClientError("此二维码需要通过支付宝扫码，请使用支付宝扫描原二维码")
        }
        let scanId = jText(scan, "id")
        guard !scanId.isEmpty else { throw ClientError("设备识别响应缺少编号") }
        let detailResult = try await post("goods/normal/details", ["goodsId": scanId])
        guard var detail = jObject(detailResult) else { throw ClientError("设备详情格式尚未适配") }
        if jText(detail, "goodsId").isEmpty { detail["goodsId"] = scanId }
        if jText(detail, "categoryCode").isEmpty { detail["categoryCode"] = jText(scan, "categoryCode") }
        return (scan, detail)
    }

    func scanDevice(_ code: DeviceCode) async throws -> ScannedDevice {
        let (scan, detail) = try await deviceDetails(code)
        let category = jText(detail, "categoryCode", jText(scan, "categoryCode"))
        if category == "04" {
            let skus = try await post("goods/normal/skus", ["goodsId": jText(detail, "goodsId")])
            return .water(try WaterRules.device(detail, skus))
        }
        if category == "02" { return .dryer(try await dryerDevice(scan, detail)) }
        return .laundry(try await laundryDevice(scan, detail))
    }

    private func laundryDevice(_ scan: [String: Any], _ detail: [String: Any]) async throws -> Device {
        let scanId = jText(scan, "id")
        let id = jText(detail, "goodsId", scanId)
        guard !id.isEmpty else { throw ClientError("设备详情缺少编号") }
        let category = jText(detail, "categoryCode", jText(scan, "categoryCode"))
        guard category == "00" || category == "01" else { throw ClientError("当前版本仅支持洗衣机和洗鞋机") }
        if jText(detail, "isBluetooth", "0") == "1" { throw ClientError("此设备需要蓝牙启动，当前版本暂不支持") }
        if jText(detail, "payment") == "after" { throw ClientError("此设备使用先用后付，当前版本暂不支持") }
        let imei = jText(detail, "imei")
        guard !imei.isEmpty else { throw ClientError("设备详情缺少标识，请先在原应用核对设备") }
        let skuResponse = try await post("goods/normal/skus", ["goodsId": id])
        let modes = try parseModes(skuResponse)
        guard !modes.isEmpty else { throw ClientError("当前设备没有可用的洗衣模式，请确认设备类型") }
        return Device(id: id, name: jText(detail, "name", "洗衣机"), imei: imei, category: category,
                      shopId: jText(detail, "shopId"), orgId: jText(detail, "orgId"),
                      remainingMinutes: Int(jText(detail, "remainTime", "0")) ?? 0, modes: modes,
                      error: jText(detail, "deviceErrorMsg"))
    }

    private func dryerDevice(_ scan: [String: Any], _ detail: [String: Any]) async throws -> Device {
        let id = jText(detail, "goodsId", jText(scan, "id"))
        guard !id.isEmpty else { throw ClientError("设备详情缺少编号") }
        guard jText(detail, "categoryCode", jText(scan, "categoryCode")) == "02" else { throw ClientError("请扫描烘干机二维码") }
        if jText(detail, "isBluetooth", "0") == "1" { throw ClientError("此设备需要蓝牙启动，当前版本暂不支持") }
        if jText(detail, "payment") == "after" { throw ClientError("此设备使用先用后付，当前版本暂不支持") }
        let imei = jText(detail, "imei")
        guard !imei.isEmpty else { throw ClientError("设备详情缺少标识，请先在原应用核对设备") }
        let skuResponse = try await post("goods/normal/skus", ["goodsId": id])
        let modes = try parseDryerModes(skuResponse)
        guard !modes.isEmpty else { throw ClientError("当前烘干机没有可用模式或时长，请在原应用核对") }
        return Device(id: id, name: jText(detail, "name", "烘干机"), imei: imei, category: "02",
                      shopId: jText(detail, "shopId"), orgId: jText(detail, "orgId"),
                      remainingMinutes: Int(jText(detail, "remainTime", "0")) ?? 0, modes: modes,
                      error: jText(detail, "deviceErrorMsg"))
    }

    private func skuArray(_ response: Any, _ label: String) throws -> [Any] {
        var data = response
        if let obj = jObject(response), jHas(obj, "code") { data = obj["data"] as Any }
        if let array = jArray(data) { return array }
        if let obj = jObject(data) {
            for key in ["skus", "skuList", "list"] {
                if let array = jArray(obj[key]) { return array }
            }
        }
        throw ClientError("\(label)数据格式尚未适配，请保留二维码供后续验证")
    }

    func parseModes(_ response: Any) throws -> [WashMode] {
        let array = try skuArray(response, "洗衣模式")
        var modes: [WashMode] = []
        for element in array {
            guard let item = jObject(element) else { continue }
            if jText(item, "scanAvailable", "true") == "false" { continue }
            let id = jText(item, "skuId")
            if id.isEmpty { continue }
            modes.append(WashMode(id, jText(item, "name", "洗衣模式"), try money(jText(item, "price")), jText(item, "feature")))
        }
        return modes
    }

    private func jsonObjectValue(_ value: Any?) -> [String: Any]? {
        if let obj = jObject(value) { return obj }
        if let s = value as? String, let data = s.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return obj }
        return nil
    }

    func parseDryerModes(_ response: Any) throws -> [WashMode] {
        let array = try skuArray(response, "烘干模式")
        var modes: [WashMode] = []
        for element in array {
            guard let item = jObject(element) else { continue }
            if jText(item, "scanAvailable", "true") == "false" { continue }
            let id = jText(item, "skuId")
            if id.isEmpty { continue }
            guard let attr = jsonObjectValue(item["extAttr"]) else { throw ClientError("烘干时长数据格式尚未适配") }
            guard let rawPrices = jArray(attr["perPrice"]) else { throw ClientError("烘干时长数据格式尚未适配") }
            var durations: [DryerDuration] = []
            for priceElement in rawPrices {
                guard let price = jObject(priceElement) else { throw ClientError("烘干时长选项格式尚未适配") }
                let status: Bool
                if let raw = price["status"], !jIsNull(raw) { status = try jStrictBool(raw) } else { status = false }
                if !status { continue }
                guard let minutes = Int(jText(price, "time")), (1...1440).contains(minutes) else {
                    throw ClientError("烘干时长格式异常，请在原应用核对")
                }
                let rawPrice = jText(price, "price")
                let amount = try money(rawPrice.isEmpty ? "0" : rawPrice)
                let selected: Bool
                if let raw = price["selected"], !jIsNull(raw) { selected = try jStrictBool(raw) } else { selected = false }
                durations.append(DryerDuration(minutes: minutes, price: amount, description: jText(price, "desc"), selectedByPlatform: selected))
            }
            durations.sort { $0.minutes > $1.minutes }
            if durations.isEmpty { continue }
            let selected = durations.first { $0.selectedByPlatform } ?? durations[0]
            modes.append(WashMode(id, jText(item, "name", "烘干模式"), selected.price, jText(item, "feature"), durations))
        }
        return modes
    }

    func machineModeAvailable(_ mode: WashMode) async throws -> Bool {
        let available = try await post("appoint/checkMachineCanUse", ["skuId": mode.id])
        guard jIsBool(available), let n = available as? NSNumber else { throw ClientError("设备可用状态格式尚未适配") }
        return n.boolValue
    }

    func quote(_ device: Device, _ mode: WashMode) async throws -> Quote {
        try await quotePurchase(device, mode, nil)
    }

    func quoteDryer(_ device: Device, _ mode: WashMode, _ duration: DryerDuration) async throws -> Quote {
        try await quotePurchase(device, mode, duration)
    }

    private func quotePurchase(_ device: Device, _ mode: WashMode, _ dryerDuration: DryerDuration?) async throws -> Quote {
        if device.isDryer && dryerDuration == nil { throw ClientError("请重新选择可用烘干时长") }
        if !device.isDryer && dryerDuration != nil { throw ClientError("洗衣设备不支持烘干时长") }
        var currentDevice = device
        var currentMode = mode
        var currentDuration: DryerDuration?
        if device.isDryer {
            let modes = try parseDryerModes(await post("goods/normal/skus", ["goodsId": device.id]))
            guard let found = modes.first(where: { $0.id == mode.id }) else { throw ClientError("烘干模式已下架，请重新识别设备") }
            currentMode = found
            guard let d = found.dryerDurations.first(where: { $0.minutes == dryerDuration!.minutes }) else {
                throw ClientError("所选烘干时长已不可用，请重新选择")
            }
            currentDuration = d
            currentDevice = Device(id: device.id, name: device.name, imei: device.imei, category: device.category,
                                   shopId: device.shopId, orgId: device.orgId, remainingMinutes: device.remainingMinutes,
                                   modes: modes, error: device.error)
        } else {
            guard device.modes.contains(mode) else { throw ClientError("所选模式已变化，请重新识别设备") }
        }
        guard try await machineModeAvailable(currentMode) else { throw ClientError("此设备模式暂不可用，请刷新设备后重试") }
        var fields: [String: String] = [
            "items": try PurchaseRules.items(currentDevice, currentMode, currentDuration),
            "promotions": "[]",
            "isAutoSelectPromotion": "0"
        ]
        if !currentDevice.orgId.isEmpty {
            fields["forbiddenPromotions"] = PurchaseRules.goldExclusion(currentDevice.orgId)
        }
        let result = try await post("trade/preview/v4", fields)
        guard let data = jObject(result) else { throw ClientError("报价响应格式尚未适配") }
        return try PurchaseRules.verifyQuote(data, currentDevice, currentMode, currentDuration)
    }

    func channels(_ quote: Quote) async throws -> [PayRoute] {
        let device = quote.device
        guard Int(device.orgId) != nil else { throw ClientError("设备机构编号无效，请重新扫码识别设备") }
        let result = try await post("payChannelRoute/prePay", [
            "imei": device.imei, "goodsId": device.id, "hitAd": "0", "payPrice": quote.amount,
            "useTicket": "0", "shopId": device.orgId, "combineOrderStatus": "false", "confirmSelectedStatus": "false"
        ])
        guard let array = jArray(result) else { throw ClientError("支付渠道响应格式尚未适配") }
        var supported: [PayRoute] = []
        for item in array {
            guard let channel = jObject(item) else { continue }
            if jText(channel, "autoPayState", "0") == "1" { continue }
            guard let method = PayMethod(rawValue: jText(channel, "method")) else { continue }
            supported.append(PayRoute(method, jText(channel, "thirdChannel"), jText(channel, "outVoucherId")))
        }
        var grouped: [PayMethod: [PayRoute]] = [:]
        for route in supported { grouped[route.method, default: []].append(route) }
        let result2 = grouped.values.map { routes in
            routes.first { $0.thirdChannel.isEmpty && $0.outVoucherId.isEmpty } ?? routes[0]
        }
        guard !result2.isEmpty else { throw ClientError("此设备暂未提供可用的单次支付渠道") }
        return result2
    }

    func create(_ quote: Quote, _ fix: LocationFix) async throws -> (id: String, number: String, issue: ClientError?) {
        let result = try await post("trade/create", [
            "items": quote.itemsJson,
            "promotions": PurchaseRules.goldExclusion(quote.device.orgId)
        ], risk: (quote.device, fix))
        guard let data = jObject(result) else { throw ClientError("订单返回内容不完整，请核对订单后再继续") }
        let id = jText(data, "orderId")
        let no = jText(data, "tradeNo")
        var issue: ClientError?
        do { try NoPointsPayment.verifyResponse(data) } catch let error as ClientError { issue = error }
        if id.isEmpty && no.isEmpty {
            throw issue ?? ClientError("订单返回内容不完整，请核对订单后再继续")
        }
        if issue == nil && (id.isEmpty || no.isEmpty) {
            issue = ClientError("订单返回内容不完整，请核对订单后再继续")
        }
        return (id, no, issue)
    }

    private func verifyPaymentWithoutPoints(_ order: LocalOrder) async throws {
        let fields: [String: String]
        if !order.orderId.isEmpty { fields = ["orderId": order.orderId] }
        else if !order.orderNo.isEmpty { fields = ["orderNo": order.orderNo] }
        else { throw ClientError("订单编号不完整，请先在原应用核对") }
        let detail = try await post("order/detail", fields)
        guard let data = jObject(detail) else { throw PointsPaymentUnconfirmed() }
        try NoPointsPayment.verifyBill(data, order)
    }

    func prepay(_ order: LocalOrder) async throws -> String {
        try await verifyPaymentWithoutPoints(order)
        var fields: [String: String] = [
            "orderNo": order.orderNo,
            "payType": order.payMethod.rawValue,
            "againFlag": order.phase == .paymentPending ? "1" : "0"
        ]
        if let third = order.thirdChannel, !third.isEmpty { fields["thirdChannel"] = third }
        if let voucher = order.outVoucherId, !voucher.isEmpty { fields["outVoucherId"] = voucher }
        let result = try await post("pay/unify/prePay", fields)
        guard let data = jObject(result) else { throw ClientError("未取得支付参数，请查询订单状态") }
        try NoPointsPayment.verifyResponse(data)
        let payload = jText(data, "prepayParam")
        guard !payload.isEmpty else { throw ClientError("未取得支付参数，请查询订单状态") }
        return payload
    }

    func balancePay(_ order: LocalOrder, beforeSubmit: () -> Void) async throws {
        try await verifyPaymentWithoutPoints(order)
        beforeSubmit()
        do {
            let result = try await post("pay/unify/pay", ["orderNo": order.orderNo, "payType": "2"])
            if let obj = jObject(result) { try NoPointsPayment.verifyResponse(obj) }
        } catch let error as BusinessRejected {
            throw error
        } catch let error as SessionExpired {
            throw error
        } catch let error as PointsDeductionDetected {
            throw error
        } catch let error as PointsPaymentUnconfirmed {
            throw error
        } catch {
            throw PaymentSubmittedUnconfirmed()
        }
    }

    func paid(_ order: LocalOrder) async throws -> Bool {
        let data = try await post("order/pay_status", ["orderNo": order.orderNo, "payType": order.payMethod.rawValue])
        guard jIsBool(data), let n = data as? NSNumber else { throw ClientError("支付状态格式尚未适配") }
        return n.boolValue
    }

    func orderDetails(_ order: LocalOrder) async throws -> (status: RemoteOrderStatus, progress: LaundryProgress?) {
        let fields: [String: String]
        if !order.orderId.isEmpty { fields = ["orderId": order.orderId] }
        else if !order.orderNo.isEmpty { fields = ["orderNo": order.orderNo] }
        else { throw ClientError("订单编号不完整，请先在原应用核对") }
        let response = try await post("order/detail", fields)
        guard let data = jObject(response) else { throw ClientError("订单详情格式尚未适配，请先在原应用核对") }
        let matches = !order.orderId.isEmpty ? jText(data, "id") == order.orderId : jText(data, "orderNo") == order.orderNo
        guard matches else { throw ClientError("订单详情编号不一致，请先在原应用核对") }
        if !order.orderNo.isEmpty && !jText(data, "orderNo").isEmpty && jText(data, "orderNo") != order.orderNo {
            throw ClientError("订单详情编号不一致，请先在原应用核对")
        }
        if let previousDevice = order.progress?.deviceId, !jText(data, "machineId").isEmpty,
           jText(data, "machineId") != previousDevice {
            throw ClientError("订单设备信息变化，请先在原应用核对")
        }
        guard let code = Int(jText(data, "orderStatus")), let status = RemoteOrderStatus(rawValue: code) else {
            throw ClientError("订单状态格式尚未适配，请先在原应用核对")
        }
        return (status, LaundryProgressProtocol.parse(data, order, status, Date().timeIntervalSince1970))
    }

    func sync(_ order: LocalOrder) async throws {
        _ = try await post("order/sync", ["orderNo": order.orderNo, "payType": order.payMethod.rawValue])
    }

    func cancel(_ order: LocalOrder) async throws {
        let result = try await post("order/cancel", ["orderId": order.orderId])
        guard result is String else { throw ClientError("取消结果尚未确认，请刷新订单") }
    }

    func waterPaymentRoutes(_ device: WaterDevice) async throws -> [WaterPayRoute] {
        let data = try await post("payChannelRoute/afterPay", [
            "imei": device.imei, "useTicket": "0", "shopId": device.orgId, "goodsCategory": "04"
        ])
        return try WaterRules.paymentRoutes(data)
    }

    func refreshWaterDevice(_ device: WaterDevice) async throws -> WaterDevice {
        let detail = try await post("goods/normal/details", ["goodsId": device.id])
        guard let obj = jObject(detail) else { throw ClientError("饮水机详情格式尚未适配") }
        return try WaterRules.device(obj, await post("goods/normal/skus", ["goodsId": device.id]))
    }

    func waterStatus(_ outlet: WaterOutlet) async throws -> WaterStatus {
        try WaterRules.status(await post("goods/water/sync", ["skuId": outlet.id]))
    }

    func waterAlipayRequirement(_ device: WaterDevice) async throws -> WaterAlipayRequirement {
        let account = tokenProvider()
        let current = device.tradeMain != nil ? device : try await refreshWaterDevice(device)
        guard current.id == device.id && current.imei == device.imei && current.orgId == device.orgId && current.shopId == device.shopId else {
            throw ClientError("饮水机信息已变化，请重新扫码确认")
        }
        guard let tradeMain = current.tradeMain, tradeMain >= 0 else {
            throw ClientError("设备未提供商户签约信息，请重新扫码或在胖乖核对")
        }
        guard !current.shopId.isEmpty && !current.id.isEmpty else { throw ClientError("设备信息不完整，请重新扫码确认") }
        guard tokenProvider() == account else { throw ClientError("登录账户已变化，请重新确认用水") }
        let data = try await post("popup/shop", [
            "shopId": current.shopId, "goodsId": current.id, "tradeMain": String(tradeMain), "multipleSwitch": "2"
        ])
        guard tokenProvider() == account else { throw ClientError("登录账户已变化，请重新确认用水") }
        var popups: [Any] = []
        if !jIsNull(data) {
            guard let array = jArray(data) else { throw ClientError("本设备免密授权要求尚未确认，请刷新后重试") }
            popups = array
        }
        var forcedByDevice = false
        var signingMerchants: [Int] = []
        for row in popups {
            guard let item = jObject(row) else { throw ClientError("本设备免密授权要求格式尚未适配") }
            guard let type = Int(jText(item, "popupType")) else { throw ClientError("本设备免密授权要求格式尚未适配") }
            if type != 1 && type != 4 { continue }
            let force = item["isForceUse"]
            let forceValue: Int
            if jIsNull(force) { forceValue = 0 }
            else {
                guard let v = Int(jText(item, "isForceUse")) else { throw ClientError("平台返回的设备授权要求尚未确认") }
                forceValue = v
            }
            if type == 1 && forceValue == 1 { forcedByDevice = true }
            let merchant: Int
            if jIsNull(item["tradeMain"]) { merchant = tradeMain }
            else {
                guard let m = Int(jText(item, "tradeMain")), m >= 0 else { throw ClientError("平台返回的商户签约信息尚未确认") }
                merchant = m
            }
            if !signingMerchants.contains(merchant) { signingMerchants.append(merchant) }
        }
        guard signingMerchants.count <= 1 else { throw ClientError("平台返回多个商户签约要求，请在胖乖核对后重试") }
        let needsSigning: Bool
        if forcedByDevice {
            needsSigning = true
        } else {
            let signed = try await post("alipay/isSign", [:])
            guard tokenProvider() == account else { throw ClientError("登录账户已变化，请重新确认用水") }
            guard jIsBool(signed), let n = signed as? NSNumber else { throw ClientError("支付宝免密签约状态尚未确认，请刷新后重试") }
            needsSigning = !n.boolValue
        }
        return WaterAlipayRequirement(tradeMain: signingMerchants.first ?? tradeMain, needsSigning: needsSigning, forcedByDevice: forcedByDevice)
    }

    func startWater(_ device: WaterDevice, _ outlet: WaterOutlet, _ fix: LocationFix, _ payment: WaterPayRoute) async throws -> WaterStart {
        let account = tokenProvider()
        do {
            let routes = try await waterPaymentRoutes(device)
            guard routes.contains(where: { $0.wire == payment.wire && $0.method == payment.method }) else {
                throw ClientError("饮水支付渠道已变化，请刷新后重新选择")
            }
            guard tokenProvider() == account else { throw ClientError("登录账户已变化，请重新确认用水") }
            if payment.requiresAlipayAgreement {
                let requirement = try await waterAlipayRequirement(device)
                if requirement.needsSigning {
                    throw WaterStartNotSent("此饮水机要求支付宝先享后付（免密）签约，请先在胖乖生活 App 完成签约后再使用简洗")
                }
            }
            guard tokenProvider() == account else { throw ClientError("登录账户已变化，请重新确认用水") }
            let selected = try await post("payChannelRoute/addUserAfterPayChannel", ["method": payment.wire])
            if !jIsNull(selected) && jPrimitiveText(selected) == nil {
                throw ClientError("饮水支付方式确认响应格式尚未适配，请刷新后重试")
            }
            guard tokenProvider() == account else { throw ClientError("登录账户已变化，请重新确认用水") }
        } catch let error as SessionExpired {
            throw error
        } catch let error as BusinessRejected {
            throw error
        } catch let error as WaterStartNotSent {
            throw error
        } catch let error as ClientError {
            throw WaterStartNotSent(error.msg)
        }
        let riskDevice = Device(id: device.id, name: device.name, imei: device.imei, category: "04",
                                shopId: device.shopId, orgId: device.orgId, remainingMinutes: 0, modes: [], error: "")
        let result = try await post("goods/water/unlock", [
            "skuId": outlet.id, "promotions": WaterRules.promotions()
        ], risk: (riskDevice, fix))
        guard let value = jObject(result) else { throw ClientError("饮水启动结果尚未确认，请刷新状态") }
        let msgId = jText(value, "msgId")
        var issue: ClientError?
        do { try NoPointsPayment.verifyResponse(value) } catch { issue = WaterCommandSubmittedUnconfirmed() }
        if issue == nil && msgId.isEmpty { issue = WaterCommandSubmittedUnconfirmed() }
        return WaterStart(orderNo: jText(value, "orderNo"), msgId: msgId, verificationIssue: issue)
    }

    func waterCommandAccepted(_ msgId: String) async throws -> Bool {
        let result = try await post("machine/msg/sync", ["msgId": msgId])
        guard let obj = jObject(result) else { return false }
        return jText(obj, "state").uppercased() == "OK"
    }

    func endWater(_ device: WaterDevice) async throws {
        let result = try await post("goods/endWater", ["goodsId": device.id])
        guard jIsBool(result), let n = result as? NSNumber, n.boolValue else {
            throw ClientError("结束用水结果尚未确认，请检查设备并刷新状态")
        }
    }

    func waterSettlement(_ session: WaterSession) async throws -> LocalOrder? {
        guard !session.identify.isEmpty else { throw ClientError("饮水结算编号尚未确认，请稍后刷新") }
        let response = try await post("order/afterPay/creating", ["orderNo": session.identify])
        if jIsNull(response) { return nil }
        guard let obj = jObject(response) else { throw ClientError("饮水结算数据格式尚未适配") }
        let id = jText(obj, "orderId")
        if id.isEmpty { return nil }
        let detail = try await post("order/detail", ["orderId": id])
        guard let data = jObject(detail) else { throw ClientError("饮水账单详情尚未确认") }
        guard jText(data, "id") == id && !jText(data, "orderNo").isEmpty else { throw ClientError("饮水账单编号不一致") }
        let method: PayMethod
        switch jText(data, "payType") {
        case "2": method = .balance
        case "13", "15", "103": method = .alipay
        default: throw ClientError("饮水账单支付方式尚未适配，请在原应用核对")
        }
        let expected: PayMethod? = session.payment?.method ?? (!session.recovered ? .balance : nil)
        if let expected = expected, method != expected { throw ClientError("饮水账单支付方式发生变化，请先在原应用核对") }
        guard let code = Int(jText(data, "orderStatus")), let status = RemoteOrderStatus(rawValue: code) else {
            throw ClientError("饮水账单状态尚未适配")
        }
        let order = LocalOrder(owner: session.owner, deviceName: session.device.name, modeName: session.outlet.name,
                               amount: try money(jText(data, "payPrice")), payMethod: method, phase: .created,
                               createdAt: session.startedAt, orderId: id, orderNo: jText(data, "orderNo"),
                               syncRequested: true, category: "04")
        return OrderStates.apply(order, status)
    }

    func waterBillPaymentRoute(_ order: LocalOrder) async throws -> LocalOrder {
        if !order.isWater || order.payMethod != .alipay { return order }
        let data = try await post("payChannelRoute/againPay", ["orderNo": order.orderNo, "confirmSelectedStatus": "false"])
        guard let array = jArray(data) else { throw ClientError("饮水账单支付渠道格式尚未适配") }
        let route = array.first { item in
            guard let it = jObject(item) else { return false }
            return jText(it, "method") == PayMethod.alipay.rawValue &&
                ["0", "false"].contains(jText(it, "isThird", "0")) &&
                jText(it, "thirdChannel").isEmpty && jText(it, "outVoucherId").isEmpty &&
                ["0", "false"].contains(jText(it, "autoPayState", "0")) &&
                !["0", "false"].contains(jText(it, "canChecked", "true"))
        }
        guard route != nil else { throw ClientError("这笔饮水账单暂未提供支付宝单次支付渠道，请在原应用完成支付后刷新") }
        var result = order
        result.thirdChannel = ""
        result.outVoucherId = ""
        return result
    }
}