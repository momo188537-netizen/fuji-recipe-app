import CoreBluetooth

/// Fujifilm Bluetooth LE identifiers.
///
/// Taken from the open-source furble project (github.com/gkoh/furble,
/// lib/furble/Fujifilm*.h/.cpp), which reverse-engineered the camera's BLE
/// remote-shutter protocol. Nothing here covers camera settings yet: finding
/// that is the purpose of this probe app.
enum Fuji {
    /// Bluetooth SIG company id in manufacturer data (little-endian D8 04).
    static let companyID: UInt16 = 0x04D8

    // MARK: Advertised services
    /// Advertised by "secure" cameras (firmware from ~July 2025) in pairing mode.
    static let secureAdvService = CBUUID(string: "A9D2B304-E8D6-4902-8336-352B772D7597")
    /// Advertised by "basic" (older-firmware) cameras.
    static let crService = CBUUID(string: "AF854C2E-B214-458E-97E2-912C4ECF2CB8")
    static let xappService = CBUUID(string: "117C4142-EDD4-4C77-8696-DD18EEBB770A")

    // MARK: Pairing
    static let pairService = CBUUID(string: "91F1DE68-DFF6-466E-8B65-FF13B0F16FB8")
    static let pairChr = CBUUID(string: "ABA356EB-9633-4E60-B73F-F52516DBD671")
    static let identChr = CBUUID(string: "85B9163E-62D1-49FF-A6F5-054B4630D4A1")
    static let securePairService = CBUUID(string: "123D8F06-62A1-4935-9322-833C531EE225")
    static let secureStatusChr = CBUUID(string: "F557D96B-8284-4667-8793-B971C1DECA2A")
    static let securePrimaryService = CBUUID(string: "731893F9-744E-4899-B7E3-174106FF2B82")

    // MARK: Configuration / notifications
    static let confService = CBUUID(string: "4C0020FE-F3B6-40DE-ACC9-77D129067B14")
    static let ind1 = CBUUID(string: "A68E3F66-0FCC-4395-8D4C-AA980B5877FA")
    static let ind2 = CBUUID(string: "BD17BA04-B76B-4892-A545-B73BA1F74DAE")
    static let not1 = CBUUID(string: "F9150137-5D40-4801-A8DC-F7FC5B01DA50")
    static let ind3 = CBUUID(string: "049EC406-EF75-4205-A390-08FE209C51F0")
    static let geotagUpdate = CBUUID(string: "AD06C7B7-F41A-46F4-A29A-712055319122")
    static let not6 = CBUUID(string: "E6692C5C-B7CD-44F4-95FC-EDA07CE32560")

    static let notxService = CBUUID(string: "4E941240-D01D-46B9-A5EA-67636806830B")
    static let not4 = CBUUID(string: "BF6DC9CF-3606-4EC9-A4C8-D77576E93EA4")
    static let not5 = CBUUID(string: "75823784-FBB7-4B71-ABAE-CD9A34072E3C")
    static let not7 = CBUUID(string: "AAB609C4-94DD-4D89-BC60-665D5090B828")
    static let not8 = CBUUID(string: "2A125640-706D-4DD1-B420-C0F4AB93C361")
    static let not9 = CBUUID(string: "82A9F452-C5CE-4EF5-8203-3FC9A47F8171")
    static let not10 = CBUUID(string: "DEEF7187-3F43-4364-9E22-11A8C8A15951")
    static let geotagInterval = CBUUID(string: "C95D91AE-B247-4D6D-8661-7DD5D6A0F85B")

    static let not3Service = CBUUID(string: "804DAA8E-FFEB-4AB3-8E75-6EDD7303208D")
    static let not3 = CBUUID(string: "7170FD5A-56D9-4C19-B043-7A7047D8E1A0")
    static let unk0 = CBUUID(string: "98934B2C-756C-4632-AA2F-DCBA1BFEC824")

    // MARK: Shutter / geotag
    static let shutterService = CBUUID(string: "6514EB81-4E8F-458D-AA2A-E691336CDFAC")
    static let shutterChr = CBUUID(string: "7FCF49C6-4FF0-4777-A03D-1A79166AF7A8")
    static let geotagService = CBUUID(string: "3B46EC2B-48BA-41FD-B1B8-ED860B60D22B")
    static let geotagChr = CBUUID(string: "0F36EC14-29E5-411A-A1B6-64EE8383F090")

    /// Human-readable labels for the log.
    static let names: [CBUUID: String] = [
        secureAdvService: "安全广播服务",
        crService: "CR 服务",
        xappService: "XApp 服务",
        pairService: "配对服务",
        pairChr: "配对令牌",
        identChr: "设备名称",
        securePairService: "安全配对服务",
        secureStatusChr: "安全状态",
        securePrimaryService: "安全主服务",
        confService: "配置服务",
        ind1: "指示1", ind2: "指示2", ind3: "指示3",
        not1: "通知1", not3: "通知3", not4: "通知4", not5: "通知5",
        not6: "通知6", not7: "通知7", not8: "通知8", not9: "通知9", not10: "通知10",
        notxService: "通知服务X",
        not3Service: "通知3服务",
        unk0: "未知0",
        geotagUpdate: "定位请求",
        geotagInterval: "定位同步间隔",
        shutterService: "快门服务",
        shutterChr: "快门",
        geotagService: "定位服务",
        geotagChr: "定位数据",
    ]

    static func label(_ uuid: CBUUID) -> String {
        if let n = names[uuid] { return n }
        let s = uuid.uuidString
        return s.count > 8 ? String(s.prefix(8)) : s
    }
}

enum FujiProtocol: String {
    case secure = "新版加密协议 (secure)"
    case basic = "旧版令牌协议 (basic)"
    case unknown = "未知"
}

extension Data {
    var hex: String { map { String(format: "%02X", $0) }.joined(separator: " ") }

    /// Printable-ASCII preview, dots for everything else.
    var ascii: String {
        String(map { (0x20...0x7E).contains($0) ? Character(UnicodeScalar($0)) : "." })
    }

    init?(hexString: String) {
        let cleaned = hexString.filter { $0.isHexDigit }
        guard cleaned.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        var idx = cleaned.startIndex
        while idx < cleaned.endIndex {
            let next = cleaned.index(idx, offsetBy: 2)
            guard let b = UInt8(cleaned[idx..<next], radix: 16) else { return nil }
            bytes.append(b)
            idx = next
        }
        self.init(bytes)
    }
}

extension CBCharacteristicProperties {
    var short: String {
        var s: [String] = []
        if contains(.read) { s.append("读") }
        if contains(.write) { s.append("写") }
        if contains(.writeWithoutResponse) { s.append("写(无响应)") }
        if contains(.notify) { s.append("通知") }
        if contains(.indicate) { s.append("指示") }
        if contains(.authenticatedSignedWrites) { s.append("签名写") }
        return s.joined(separator: " ")
    }

    var canSubscribe: Bool { contains(.notify) || contains(.indicate) }
}
