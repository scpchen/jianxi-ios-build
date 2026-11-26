import Foundation

enum NoPointsPayment {
    private static func type(_ value: [String: Any]) throws -> Int {
        guard let raw = value["promotionType"], !jIsBool(raw), let text = jPrimitiveText(raw),
              text.range(of: "^-?[0-9]+$", options: .regularExpression) != nil, let t = Int(text) else {
            throw PointsPaymentUnconfirmed()
        }
        return t
    }

    private static func aggregateDiscount(_ data: [String: Any]) throws -> Decimal? {
        if let s = data["discountPrice"] as? String, s.isEmpty { return nil }
        return try jDecimal(data["discountPrice"])
    }

    private static func deductionList(_ raw: Any) throws -> Int {
        guard let array = jArray(raw) else { throw PointsPaymentUnconfirmed() }
        for entry in array {
            guard let obj = jObject(entry) else { throw PointsPaymentUnconfirmed() }
            if try type(obj) == 8 { throw PointsDeductionDetected() }
        }
        return array.count
    }

    static func verifyResponse(_ data: [String: Any]) throws {
        if !jIsNull(data["promotionList"]) {
            _ = try deductionList(data["promotionList"]!)
        }
        if !jIsNull(data["promotions"]) {
            guard let array = jArray(data["promotions"]) else { throw PointsPaymentUnconfirmed() }
            func inspect(_ entry: Any, _ inheritedType: Int?) throws {
                guard let row = jObject(entry) else { throw PointsPaymentUnconfirmed() }
                var rowType = inheritedType
                if jHas(row, "promotionType") && !jIsNull(row["promotionType"]) { rowType = try type(row) }
                let flag = row["isUsed"]
                if !jIsNull(flag) {
                    guard jIsBool(flag!) else { throw PointsPaymentUnconfirmed() }
                    if rowType == 8, let n = flag as? NSNumber, n.boolValue { throw PointsDeductionDetected() }
                }
                for key in ["options", "participateList"] {
                    if jIsNull(row[key]) { continue }
                    guard let options = jArray(row[key]) else { throw PointsPaymentUnconfirmed() }
                    for option in options { try inspect(option, rowType) }
                }
            }
            for entry in array { try inspect(entry, nil) }
        }
    }

    static func verifyBill(_ data: [String: Any], _ order: LocalOrder) throws {
        if order.orderId.isEmpty && order.orderNo.isEmpty { throw PointsPaymentUnconfirmed() }
        if !order.orderId.isEmpty && jText(data, "id") != order.orderId { throw PointsPaymentUnconfirmed() }
        if !order.orderNo.isEmpty && jText(data, "orderNo") != order.orderNo { throw PointsPaymentUnconfirmed() }
        guard let payable = try jDecimal(data["payPrice"]) else { throw PointsPaymentUnconfirmed() }
        guard let expected = Decimal(string: order.amount), payable == expected else { throw PointsPaymentUnconfirmed() }
        try verifyResponse(data)

        var commission = false
        if !jIsNull(data["commissionTrade"]) {
            guard jIsBool(data["commissionTrade"]!), let n = data["commissionTrade"] as? NSNumber else {
                throw PointsPaymentUnconfirmed()
            }
            commission = n.boolValue
        }
        var deductions: Any?
        if commission {
            guard let details = jObject(data["orderCommissionVO"]) else { throw PointsPaymentUnconfirmed() }
            deductions = jIsNull(details["promotions"]) ? nil : details["promotions"]
        } else {
            deductions = jIsNull(data["promotionList"]) ? nil : data["promotionList"]
        }
        if let deductions = deductions {
            let count = try deductionList(deductions)
            if count == 0, let discount = try aggregateDiscount(data), discount > 0 { throw PointsPaymentUnconfirmed() }
            return
        }
        guard let original = try jDecimal(data["markPrice"]), original == payable else { throw PointsPaymentUnconfirmed() }
        if let discount = try aggregateDiscount(data), discount != 0 { throw PointsPaymentUnconfirmed() }
    }
}