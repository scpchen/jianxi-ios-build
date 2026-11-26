import Foundation

enum PurchaseRules {
    static func items(_ device: Device, _ mode: WashMode, _ duration: DryerDuration?) throws -> String {
        if device.isDryer && duration == nil { throw ClientError("请选择烘干时长") }
        if !device.isDryer && duration != nil { throw ClientError("洗衣设备不能使用烘干时长") }
        if let d = duration {
            guard mode.dryerDurations.contains(where: { $0.minutes == d.minutes }), d.minutes > 0 else {
                throw ClientError("烘干时长已变化，请重新选择")
            }
        }
        let amount = duration.map { String($0.minutes) } ?? "1"
        return "[{\"goodsId\":\"\(jsonEscape(device.id))\",\"skuId\":\"\(jsonEscape(mode.id))\",\"amount\":\"\(amount)\",\"soldType\":\"1\",\"num\":\"\(amount)\",\"price\":\"\"}]"
    }

    static func goldExclusion(_ orgId: String) -> String {
        "[{\"promotionId\":\"0\",\"promotionType\":\"4\",\"assetId\":\"0\",\"oldPromotionId\":\"3482\",\"orgId\":\"\(jsonEscape(orgId))\"}]"
    }

    static func verifyQuote(_ data: [String: Any], _ device: Device, _ mode: WashMode, _ duration: DryerDuration?) throws -> Quote {
        let expectedJson = try items(device, mode, duration)
        guard let expectedArr = try JSONSerialization.jsonObject(with: Data(expectedJson.utf8)) as? [[String: Any]],
              let expected = expectedArr.first else { throw ClientError("报价缺少所选项目") }
        guard let items = jArray(data["items"]) else { throw ClientError("报价缺少所选项目") }
        guard items.count == 1 else { throw ClientError("报价包含额外商品，请先在原应用核对") }
        guard let item = jObject(items[0]) else { throw ClientError("报价项目格式尚未适配") }
        for key in ["goodsId", "skuId", "amount", "soldType", "num"] {
            if key == "num" && !device.isDryer && !jHas(item, "num") { continue }
            let fallback = key == "soldType" ? "1" : ""
            if jText(item, key, fallback) != jText(expected, key, fallback) {
                throw ClientError("报价项目与所选\(device.isDryer ? "烘干模式或时长" : "洗衣模式")不一致")
            }
        }
        try verifyPromotions(data, device.orgId)
        try NoPointsPayment.verifyResponse(data)
        var tradeType = 0
        if !jIsNull(data["tradeType"]) {
            guard let text = jPrimitiveText(data["tradeType"]), let value = Int(text) else {
                throw ClientError("报价订单类型格式尚未适配")
            }
            tradeType = value
        }
        return Quote(device: device, mode: mode, amount: try money(jText(data, "realPrice")),
                     itemsJson: expectedJson, tradeType: tradeType, dryerDuration: duration)
    }

    private static func used(_ item: [String: Any]) throws -> Bool {
        let flag = item["isUsed"]
        if jIsNull(flag) { return false }
        guard jIsBool(flag!), let n = flag as? NSNumber else { throw ClientError("报价优惠选中状态格式尚未适配") }
        return n.boolValue
    }

    private static func shape(_ value: Any?) -> String {
        if jIsNull(value) { return "空值" }
        if value is [Any] { return "数组" }
        if value is [String: Any] { return "对象" }
        if value is String { return "文本" }
        if jIsBool(value!) { return "布尔值" }
        return "数值"
    }

    private static func goldExcluded(_ item: [String: Any], _ orgId: String) -> Bool {
        jText(item, "promotionType") == "4" && jText(item, "promotionId") == "0" &&
        jText(item, "assetId") == "0" && jText(item, "oldPromotionId") == "3482" && jText(item, "orgId") == orgId
    }

    private static func verifyPromotions(_ data: [String: Any], _ orgId: String) throws {
        let raw = data["promotions"]
        if jIsNull(raw) { return }
        guard let array = jArray(raw) else { throw ClientError("报价优惠数据格式尚未适配") }
        for entry in array {
            guard let promotion = jObject(entry) else { throw ClientError("报价优惠数据格式尚未适配") }
            var promotionType = 0
            if !jIsNull(promotion["promotionType"]) {
                guard let text = jPrimitiveText(promotion["promotionType"]), let value = Int(text) else {
                    throw ClientError("报价优惠类型尚未适配")
                }
                promotionType = value
            }
            var excludesGold = false
            for key in ["options", "participateList"] {
                let options = promotion[key]
                if jIsNull(options) { continue }
                guard let optionArray = jArray(options) else {
                    throw ClientError("报价优惠选项格式尚未适配（\(key)：\(shape(options))）")
                }
                for option in optionArray {
                    guard let optionObj = jObject(option) else {
                        throw ClientError("报价优惠选项格式尚未适配（\(key)[]：\(shape(option))）")
                    }
                    if try used(optionObj) {
                        if promotionType == 8 || jText(optionObj, "promotionType") == "8" { throw PointsDeductionDetected() }
                        guard goldExcluded(optionObj, orgId) else { throw ClientError("报价附加了未选择的优惠，请先核对") }
                        excludesGold = true
                    }
                }
            }
            if try used(promotion) && promotionType == 8 { throw PointsDeductionDetected() }
            if try used(promotion) && !(promotionType == 4 && excludesGold) {
                throw ClientError("报价附加了未选择的优惠，请先核对")
            }
        }
    }

    static func verifyAlipay(_ raw: String, _ expectedAmount: String) throws {
        var args: [String: String] = [:]
        for part in raw.split(separator: "&") where part.contains("=") {
            guard let eq = part.firstIndex(of: "=") else { continue }
            guard let key = urlFormDecode(String(part[..<eq])), let value = urlFormDecode(String(part[part.index(after: eq)...])) else {
                throw ClientError("支付宝支付参数无效")
            }
            args[key] = value
        }
        guard args["method"] == "alipay.trade.app.pay" else { throw ClientError("当前返回的不是单次支付宝付款") }
        guard let bizData = args["biz_content"]?.data(using: .utf8),
              let business = try? JSONSerialization.jsonObject(with: bizData) as? [String: Any] else {
            throw ClientError("支付宝订单内容无法确认")
        }
        let forbidden: Set<String> = ["agreement_sign_params", "agreement_no", "period_rule_params", "sign_scene", "personal_product_code"]
        func containsContract(_ value: Any) -> Bool {
            if let obj = value as? [String: Any] {
                return obj.contains { key, v in forbidden.contains(key) || containsContract(v) }
            }
            if let arr = value as? [Any] { return arr.contains { containsContract($0) } }
            return false
        }
        if containsContract(business) || args.keys.contains(where: { forbidden.contains($0) }) {
            throw ClientError("付款包含签约内容，已停止")
        }
        var product = ""
        if !jIsNull(business["product_code"]) {
            guard let p = business["product_code"] as? String else { throw ClientError("支付宝支付产品码格式尚未适配") }
            product = p
        }
        if !product.isEmpty && product != "QUICK_MSECURITY_PAY" {
            let diagnostic = product.range(of: "^[A-Za-z0-9_]{1,64}$", options: .regularExpression) != nil ? product : "未知格式"
            throw ClientError("暂不支持此支付宝支付产品（产品码：\(diagnostic)）")
        }
        guard try money(jText(business, "total_amount")) == (try money(expectedAmount)) else {
            throw ClientError("支付金额与确认金额不一致")
        }
    }
}