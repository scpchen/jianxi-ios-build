import Foundation
import CryptoKit

func jObject(_ value: Any?) -> [String: Any]? {
    value as? [String: Any]
}

func jArray(_ value: Any?) -> [Any]? {
    value as? [Any]
}

func jIsNull(_ value: Any?) -> Bool {
    value == nil || value is NSNull
}

func jIsBool(_ value: Any) -> Bool {
    guard let n = value as? NSNumber else { return false }
    return CFGetTypeID(n) == CFBooleanGetTypeID()
}

func jPrimitiveText(_ value: Any?) -> String? {
    guard let value = value, !(value is NSNull) else { return nil }
    if let s = value as? String { return s }
    if let n = value as? NSNumber {
        if jIsBool(n) { return n.boolValue ? "true" : "false" }
        return n.stringValue
    }
    return nil
}

func jText(_ obj: [String: Any], _ key: String, _ fallback: String = "") -> String {
    jPrimitiveText(obj[key]) ?? fallback
}

func jHas(_ obj: [String: Any], _ key: String) -> Bool {
    obj[key] != nil
}

func jStrictBool(_ value: Any?) throws -> Bool {
    guard let value = value, !(value is NSNull) else { throw ClientError("布尔状态格式尚未适配") }
    if jIsBool(value), let n = value as? NSNumber { return n.boolValue }
    if let s = value as? String, s == "true" || s == "false" { return s == "true" }
    throw ClientError("布尔状态格式尚未适配")
}

func jInt(_ obj: [String: Any], _ key: String, default fallback: Int? = nil) throws -> Int {
    let raw = obj[key]
    if jIsNull(raw) {
        if let f = fallback { return f }
        throw ClientError("字段 \(key) 格式尚未适配")
    }
    guard let text = jPrimitiveText(raw), !(jIsBool(raw!)), let value = Int(text) else {
        throw ClientError("字段 \(key) 格式尚未适配")
    }
    return value
}

func jDecimal(_ value: Any?) throws -> Decimal? {
    if jIsNull(value) { return nil }
    guard let raw = jPrimitiveText(value), !jIsBool(value!) else { throw PointsPaymentUnconfirmed() }
    guard raw.count <= 64, raw.range(of: "^[0-9]+(\\.[0-9]+)?$", options: .regularExpression) != nil,
          let d = Decimal(string: raw) else { throw PointsPaymentUnconfirmed() }
    return d
}

func jsonEscape(_ s: String) -> String {
    var out = ""
    for c in s.unicodeScalars {
        switch c {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default:
            if c.value < 0x20 { out += String(format: "\\u%04x", c.value) } else { out.unicodeScalars.append(c) }
        }
    }
    return out
}

func urlFormDecode(_ s: String) -> String? {
    s.replacingOccurrences(of: "+", with: " ").removingPercentEncoding
}

enum WireProtocol {
    static let version = "1.144.0"
    static let channel = "android_app"
    static let clientConstant = "nFU9pbG8YQoAe1kFh+E7eyrdlSLglwEJeA0wwHB1j5o="

    static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func sign(_ path: String, _ token: String, _ timestamp: String) -> String {
        sha256("appSecret=\(clientConstant)&channel=\(channel)&timestamp=\(timestamp)&token=\(token)&version=\(version)&\(path)")
    }

    static func riskSign(_ path: String, _ token: String, _ timestamp: String, _ imei: String, _ category: String, _ fix: LocationFix) -> String {
        sha256("appSecret=\(clientConstant)&categoryCode=\(category)&channel=\(channel)&imei=\(imei)&lat=\(fix.latitude)&lng=\(fix.longitude)&timestamp=\(timestamp)&token=\(token)&version=\(version)&\(path)")
    }
}

enum DeviceCodes {
    static func parse(_ raw: String) throws -> DeviceCode {
        guard raw.count <= 4096 else { throw ClientError("二维码内容过长") }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var query = trimmed
        if let idx = trimmed.firstIndex(of: "?") {
            query = String(trimmed[trimmed.index(after: idx)...])
        }
        if let idx = query.firstIndex(of: "#") {
            query = String(query[..<idx])
        }
        var matches: [(String, String)] = []
        for part in query.split(separator: "&") where part.contains("=") {
            guard let eq = part.firstIndex(of: "=") else { continue }
            let rawKey = String(part[..<eq])
            let rawValue = String(part[part.index(after: eq)...])
            guard let key = urlFormDecode(rawKey), let value = urlFormDecode(rawValue) else {
                throw ClientError("二维码编码无效")
            }
            if key == "IMEI" || key == "NQT" || key == "SN" { matches.append((key, value)) }
        }
        guard matches.count == 1 else { throw ClientError("请使用包含 IMEI、SN 或 NQT 的设备二维码") }
        let (key, value) = matches[0]
        guard value.range(of: "^[A-Za-z0-9_.-]{4,96}$", options: .regularExpression) != nil else {
            throw ClientError("设备编号格式异常")
        }
        return DeviceCode(key: key, value: value)
    }
}