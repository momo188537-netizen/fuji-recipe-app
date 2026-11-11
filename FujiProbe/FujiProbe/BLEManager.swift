import CoreBluetooth
import Foundation

struct LogEntry: Identifiable {
    let id = UUID()
    let time: Date
    let text: String
}

struct DiscoveredDevice: Identifiable {
    let id: UUID
    let peripheral: CBPeripheral
    var name: String
    var rssi: Int
    var manufacturerData: Data?
    var serviceUUIDs: [CBUUID]

    var isFuji: Bool {
        guard let d = manufacturerData, d.count >= 2 else { return false }
        return d[d.startIndex] == 0xD8 && d[d.startIndex + 1] == 0x04
    }

    var protocolGuess: FujiProtocol {
        guard isFuji else { return .unknown }
        if serviceUUIDs.contains(Fuji.secureAdvService) || serviceUUIDs.contains(Fuji.securePairService) {
            return .secure
        }
        if let d = manufacturerData, d.count == 7, d[d.startIndex + 2] == 0x02 { return .basic }
        return .unknown
    }

    /// 4-byte pairing token that "basic" cameras put in manufacturer data.
    var pairingToken: Data? {
        guard let d = manufacturerData, d.count >= 7 else { return nil }
        return d.subdata(in: (d.startIndex + 3)..<(d.startIndex + 7))
    }
}

/// Scans for, connects to and pokes at a Fujifilm camera over BLE, logging everything.
///
/// Every GATT operation goes through one serial queue so the log shows a clean
/// request → response sequence.
final class BLEManager: NSObject, ObservableObject {
    static let identity = "FujiProbe"

    @Published var bluetoothState = "初始化中…"
    @Published var isScanning = false
    @Published var devices: [DiscoveredDevice] = []
    @Published var connectedDevice: DiscoveredDevice?
    @Published var isConnected = false
    @Published var services: [CBService] = []
    @Published var values: [String: Data] = [:]
    @Published var logs: [LogEntry] = []
    @Published var busyLabel: String?
    @Published var snapshotCount = 0

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var pendingServiceDiscovery = 0

    // Serial GATT operation queue
    private struct Step {
        let label: String
        /// Starts the operation. Returns true if we must wait for a callback.
        let start: () -> Bool
    }
    private enum Wait {
        case read(String, ((Data) -> Void)?)
        case write(String)
        case notify(String)
    }
    private var steps: [Step] = []
    private var running = false
    private var waiting: Wait?
    private var timeoutItem: DispatchWorkItem?

    // Snapshots
    private var lastSnapshot: [String: Data]?
    private var building: [String: Data] = [:]

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: - Helpers

    func log(_ text: String) {
        logs.append(LogEntry(time: Date(), text: text))
        if logs.count > 5000 { logs.removeFirst(logs.count - 5000) }
        print(text)
    }

    func key(_ c: CBCharacteristic) -> String {
        "\(c.service?.uuid.uuidString ?? "?")/\(c.uuid.uuidString)"
    }

    func name(_ c: CBCharacteristic) -> String {
        "\(Fuji.label(c.uuid))[\(c.uuid.uuidString.prefix(8))]"
    }

    var allCharacteristics: [CBCharacteristic] {
        services.flatMap { $0.characteristics ?? [] }
    }

    func characteristic(_ uuid: CBUUID) -> CBCharacteristic? {
        allCharacteristics.first { $0.uuid == uuid }
    }

    // MARK: - Scanning / connecting

    func startScan() {
        guard central.state == .poweredOn else {
            log("⚠️ 蓝牙未就绪：\(bluetoothState)")
            return
        }
        devices.removeAll()
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        isScanning = true
        log("🔍 开始扫描")
    }

    func stopScan() {
        central.stopScan()
        isScanning = false
    }

    func connect(_ device: DiscoveredDevice) {
        stopScan()
        connectedDevice = device
        peripheral = device.peripheral
        services = []
        values = [:]
        lastSnapshot = nil
        snapshotCount = 0
        log("🔌 连接 \(device.name)（\(device.protocolGuess.rawValue)）")
        log("   广播厂商数据: \(device.manufacturerData?.hex ?? "无")")
        log("   广播服务: \(device.serviceUUIDs.map { $0.uuidString }.joined(separator: ", "))")
        central.connect(device.peripheral, options: nil)
    }

    func disconnect() {
        if let p = peripheral { central.cancelPeripheralConnection(p) }
    }

    // MARK: - Operation queue

    private func enqueue(_ step: Step) {
        steps.append(step)
        if !running { next() }
    }

    private func next() {
        timeoutItem?.cancel()
        timeoutItem = nil
        while !steps.isEmpty {
            let step = steps.removeFirst()
            running = true
            busyLabel = step.label
            if step.start() {
                let item = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.log("⏱ 超时：\(step.label)")
                    self.waiting = nil
                    self.next()
                }
                timeoutItem = item
                DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: item)
                return
            }
        }
        running = false
        busyLabel = nil
    }

    private func clearQueue() {
        steps.removeAll()
        waiting = nil
        running = false
        busyLabel = nil
        timeoutItem?.cancel()
        timeoutItem = nil
    }

    func enqueueRead(_ c: CBCharacteristic, then handler: ((Data) -> Void)? = nil) {
        enqueue(Step(label: "读取 \(name(c))") { [weak self] in
            guard let self, let p = self.peripheral else { return false }
            self.waiting = .read(self.key(c), handler)
            p.readValue(for: c)
            return true
        })
    }

    func enqueueWrite(_ c: CBCharacteristic, _ data: Data, withResponse: Bool? = nil) {
        let wr = withResponse ?? c.properties.contains(.write)
        enqueue(Step(label: "写入 \(name(c))") { [weak self] in
            guard let self, let p = self.peripheral else { return false }
            self.log("→ 写入 \(self.name(c)) [\(data.count)B] \(data.hex) \(wr ? "" : "(无响应)")")
            p.writeValue(data, for: c, type: wr ? .withResponse : .withoutResponse)
            if wr {
                self.waiting = .write(self.key(c))
                return true
            }
            return false
        })
    }

    func enqueueNotify(_ c: CBCharacteristic, on: Bool = true) {
        enqueue(Step(label: "\(on ? "订阅" : "取消订阅") \(name(c))") { [weak self] in
            guard let self, let p = self.peripheral else { return false }
            guard c.properties.canSubscribe else {
                self.log("· 跳过 \(self.name(c))：不支持通知")
                return false
            }
            self.waiting = .notify(self.key(c))
            p.setNotifyValue(on, for: c)
            return true
        })
    }

    private func enqueueNote(_ text: String) {
        enqueue(Step(label: text) { [weak self] in
            self?.log(text)
            return false
        })
    }

    // MARK: - Fujifilm handshake (from furble)

    var detectedProtocol: FujiProtocol {
        if services.contains(where: { $0.uuid == Fuji.securePairService }) { return .secure }
        if services.contains(where: { $0.uuid == Fuji.pairService }) { return .basic }
        return connectedDevice?.protocolGuess ?? .unknown
    }

    func handshakeAuto() {
        switch detectedProtocol {
        case .secure: handshakeSecure()
        case .basic: handshakeBasic()
        case .unknown:
            log("⚠️ 无法判断协议，先尝试新版")
            handshakeSecure()
        }
    }

    private func requireChar(_ uuid: CBUUID) -> CBCharacteristic? {
        let c = characteristic(uuid)
        if c == nil { log("⚠️ 没找到特征 \(Fuji.label(uuid)) \(uuid.uuidString)") }
        return c
    }

    func handshakeBasic() {
        enqueueNote("🤝 开始旧版握手")
        guard let token = connectedDevice?.pairingToken else {
            log("⚠️ 广播里没有配对令牌，请让相机进入「配对登记」画面后重新扫描")
            return
        }
        if let c = requireChar(Fuji.pairChr) { enqueueWrite(c, token, withResponse: true) }
        if let c = requireChar(Fuji.identChr) { enqueueWrite(c, Data(Self.identity.utf8), withResponse: true) }
        for u in [Fuji.ind1, Fuji.ind2, Fuji.not1, Fuji.geotagUpdate, Fuji.ind3] {
            if let c = requireChar(u) { enqueueNotify(c) }
        }
        enqueueNote("🤝 旧版握手步骤已全部发送")
    }

    func handshakeSecure() {
        enqueueNote("🤝 开始新版握手（iPhone 可能弹出配对请求，请点「配对」）")
        if let status = requireChar(Fuji.secureStatusChr) {
            enqueueRead(status) { [weak self] data in
                guard let self else { return }
                guard data.count == 4 else {
                    self.log("⚠️ 状态值长度不是 4：\(data.hex)")
                    return
                }
                var ack = data
                ack[ack.startIndex + 3] = 0x20
                // Must be the very next operation.
                self.steps.insert(Step(label: "回应状态") { [weak self] in
                    guard let self, let p = self.peripheral else { return false }
                    self.log("→ 回应状态 \(ack.hex)")
                    self.waiting = .write(self.key(status))
                    p.writeValue(ack, for: status, type: .withResponse)
                    return true
                }, at: 0)
            }
        }
        if let c = requireChar(Fuji.identChr) { enqueueWrite(c, Data(Self.identity.utf8), withResponse: true) }
        let subs = [Fuji.ind1, Fuji.ind2, Fuji.not1, Fuji.geotagUpdate, Fuji.not4, Fuji.not5,
                    Fuji.not6, Fuji.not7, Fuji.not8, Fuji.not9, Fuji.not10, Fuji.geotagInterval]
        for u in subs {
            if let c = requireChar(u) { enqueueNotify(c) }
        }
        if let c = requireChar(Fuji.geotagInterval) {
            enqueueWrite(c, Data([0x0A, 0x00]), withResponse: true)
        }
        enqueueNote("🤝 新版握手步骤已全部发送")
    }

    // MARK: - Exploration tools

    func subscribeAll() {
        let targets = allCharacteristics.filter { $0.properties.canSubscribe && !$0.isNotifying }
        enqueueNote("🔔 订阅全部（\(targets.count) 个）")
        targets.forEach { enqueueNotify($0) }
    }

    func readAll() {
        let readable = allCharacteristics.filter { $0.properties.contains(.read) }
        enqueueNote("📖 读取全部（\(readable.count) 个）")
        readable.forEach { enqueueRead($0) }
    }

    /// Reads every readable characteristic; from the second snapshot on, logs what changed.
    func takeSnapshot() {
        snapshotCount += 1
        let n = snapshotCount
        let readable = allCharacteristics.filter { $0.properties.contains(.read) }
        enqueueNote("📸 快照 #\(n) 开始（\(readable.count) 个可读特征）")
        building = [:]
        for c in readable {
            let k = key(c)
            enqueueRead(c) { [weak self] data in self?.building[k] = data }
        }
        enqueue(Step(label: "对比快照") { [weak self] in
            self?.finishSnapshot(n)
            return false
        })
    }

    private func finishSnapshot(_ n: Int) {
        defer {
            lastSnapshot = building
            building = [:]
        }
        guard let prev = lastSnapshot else {
            log("📸 快照 #\(n) 完成。改动相机上的一个设置后再拍一次，就能看到哪些数据变了。")
            return
        }
        var changes = 0
        for k in Set(prev.keys).union(building.keys).sorted() {
            let a = prev[k], b = building[k]
            if a != b {
                changes += 1
                let label = allCharacteristics.first { key($0) == k }.map { name($0) } ?? k
                log("Δ \(label)\n   之前: \(a?.hex ?? "无")\n   现在: \(b?.hex ?? "无")")
            }
        }
        log("📸 快照 #\(n) 对比完成：\(changes) 处变化")
    }

    // MARK: - Export

    func exportText() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        var out = "FujiProbe 日志\n导出时间: \(f.string(from: Date()))\n"
        if let d = connectedDevice {
            out += "设备: \(d.name)\n协议判断: \(detectedProtocol.rawValue)\n"
            out += "厂商数据: \(d.manufacturerData?.hex ?? "无")\n"
            out += "广播服务: \(d.serviceUUIDs.map { $0.uuidString }.joined(separator: ", "))\n"
        }
        out += "\n===== GATT 表 =====\n"
        for s in services {
            out += "服务 \(s.uuid.uuidString) \(Fuji.names[s.uuid] ?? "")\n"
            for c in s.characteristics ?? [] {
                out += "  特征 \(c.uuid.uuidString) \(Fuji.names[c.uuid] ?? "") [\(c.properties.short)]"
                if c.isNotifying { out += " 已订阅" }
                out += "\n"
                if let v = values[key(c)] { out += "    值: \(v.hex)  |\(v.ascii)|\n" }
                for d in c.descriptors ?? [] {
                    out += "    描述符 \(d.uuid.uuidString) \(String(describing: d.value ?? ""))\n"
                }
            }
        }
        out += "\n===== 日志 =====\n"
        for e in logs { out += "\(f.string(from: e.time))  \(e.text)\n" }
        return out
    }

    func exportFile() -> URL? {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FujiProbe-\(f.string(from: Date())).txt")
        do {
            try exportText().write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            log("✗ 导出失败：\(error.localizedDescription)")
            return nil
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: bluetoothState = "蓝牙已就绪"
        case .poweredOff: bluetoothState = "蓝牙已关闭"
        case .unauthorized: bluetoothState = "没有蓝牙权限（去 设置 > FujiProbe 打开）"
        case .unsupported: bluetoothState = "此设备不支持蓝牙 LE"
        case .resetting: bluetoothState = "蓝牙重置中"
        default: bluetoothState = "蓝牙状态未知"
        }
        log("ℹ️ \(bluetoothState)")
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let mfr = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        let svcs = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String
            ?? peripheral.name ?? "（无名称）"
        if let i = devices.firstIndex(where: { $0.id == peripheral.identifier }) {
            devices[i].rssi = RSSI.intValue
            devices[i].name = name
            if let mfr { devices[i].manufacturerData = mfr }
            if !svcs.isEmpty { devices[i].serviceUUIDs = svcs }
        } else {
            let d = DiscoveredDevice(id: peripheral.identifier, peripheral: peripheral, name: name,
                                     rssi: RSSI.intValue, manufacturerData: mfr, serviceUUIDs: svcs)
            devices.append(d)
            if d.isFuji {
                log("📷 发现富士设备 \(name)，\(d.protocolGuess.rawValue)，厂商数据 \(mfr?.hex ?? "")")
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        isConnected = true
        log("✅ 已连接，正在发现服务…")
        peripheral.delegate = self
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log("✗ 连接失败：\(error?.localizedDescription ?? "未知原因")")
        isConnected = false
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        log("🔌 已断开\(error.map { "：\($0.localizedDescription)" } ?? "")")
        clearQueue()
        isConnected = false
        services = []
    }
}

// MARK: - CBPeripheralDelegate

extension BLEManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { log("✗ 发现服务失败：\(error.localizedDescription)") }
        let list = peripheral.services ?? []
        services = list
        pendingServiceDiscovery = list.count
        log("🧭 发现 \(list.count) 个服务")
        for s in list { peripheral.discoverCharacteristics(nil, for: s) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error { log("✗ 服务 \(service.uuid) 特征发现失败：\(error.localizedDescription)") }
        for c in service.characteristics ?? [] { peripheral.discoverDescriptors(for: c) }
        services = peripheral.services ?? []
        pendingServiceDiscovery -= 1
        if pendingServiceDiscovery == 0 {
            log("🧭 GATT 发现完成：\(services.count) 个服务，\(allCharacteristics.count) 个特征，协议：\(detectedProtocol.rawValue)")
            for s in services {
                log("服务 \(s.uuid.uuidString) \(Fuji.names[s.uuid] ?? "")")
                for c in s.characteristics ?? [] {
                    log("   特征 \(c.uuid.uuidString) \(Fuji.names[c.uuid] ?? "") [\(c.properties.short)]")
                }
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverDescriptorsFor characteristic: CBCharacteristic,
                    error: Error?) {}

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let k = key(characteristic)
        var isRead = false
        if case .read(let wk, _)? = waiting, wk == k { isRead = true }
        if let error {
            log("✗ \(isRead ? "读取" : "通知")失败 \(name(characteristic))：\(error.localizedDescription)")
        } else if let v = characteristic.value {
            values[k] = v
            log("← \(isRead ? "读取" : "通知") \(name(characteristic)) [\(v.count)B] \(v.hex)  |\(v.ascii)|")
        }
        if case .read(let wk, let handler)? = waiting, wk == k {
            waiting = nil
            if error == nil, let v = characteristic.value { handler?(v) }
            next()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        let k = key(characteristic)
        if let error {
            log("✗ 写入失败 \(name(characteristic))：\(error.localizedDescription)")
        } else {
            log("✓ 写入成功 \(name(characteristic))")
        }
        if case .write(let wk)? = waiting, wk == k {
            waiting = nil
            next()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        let k = key(characteristic)
        if let error {
            log("✗ 订阅失败 \(name(characteristic))：\(error.localizedDescription)")
        } else {
            log("🔔 \(characteristic.isNotifying ? "已订阅" : "已取消订阅") \(name(characteristic))")
        }
        objectWillChange.send()
        if case .notify(let wk)? = waiting, wk == k {
            waiting = nil
            next()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        log("⚠️ 相机修改了服务：\(invalidatedServices.map { $0.uuid.uuidString }.joined(separator: ", "))，重新发现")
        peripheral.discoverServices(nil)
    }
}
