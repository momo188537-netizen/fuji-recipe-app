import CoreBluetooth
import SwiftUI
import UIKit

@main
struct FujiProbeApp: App {
    @StateObject private var ble = BLEManager()

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                Group {
                    if ble.isConnected {
                        ConnectedView()
                    } else {
                        ScanView()
                    }
                }
            }
            .environmentObject(ble)
        }
    }
}

// MARK: - Scan

struct ScanView: View {
    @EnvironmentObject var ble: BLEManager
    @State private var fujiOnly = true

    var shown: [DiscoveredDevice] {
        ble.devices
            .filter { !fujiOnly || $0.isFuji }
            .sorted { ($0.isFuji ? 1 : 0, $0.rssi) > ($1.isFuji ? 1 : 0, $1.rssi) }
    }

    var body: some View {
        List {
            Section {
                Text(ble.bluetoothState)
                Toggle("只显示富士相机", isOn: $fujiOnly)
                Button(ble.isScanning ? "停止扫描" : "开始扫描") {
                    ble.isScanning ? ble.stopScan() : ble.startScan()
                }
            } footer: {
                Text("首次连接前，先在相机上进入：设置 > 网络/USB 设置 > 蓝牙/智能手机设置 > 配对登记，停在这个画面再扫描。")
            }

            Section("设备（\(shown.count)）") {
                if shown.isEmpty {
                    Text(ble.isScanning ? "扫描中…" : "还没有发现设备").foregroundStyle(.secondary)
                }
                ForEach(shown) { d in
                    Button { ble.connect(d) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(d.name).font(.headline)
                                Spacer()
                                Text("\(d.rssi) dBm").font(.caption).foregroundStyle(.secondary)
                            }
                            if d.isFuji {
                                Text(d.protocolGuess.rawValue).font(.caption)
                            }
                            Text(d.manufacturerData?.hex ?? "无厂商数据")
                                .font(.caption2.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                    .tint(.primary)
                }
            }
        }
        .navigationTitle("FujiProbe")
        .toolbar {
            NavigationLink("日志") { LogView() }
        }
    }
}

// MARK: - Connected

struct ConnectedView: View {
    @EnvironmentObject var ble: BLEManager
    @State private var shareItem: ShareItem?

    var body: some View {
        List {
            Section {
                Text(ble.connectedDevice?.name ?? "相机")
                Text("协议：\(ble.detectedProtocol.rawValue)")
                if let busy = ble.busyLabel {
                    HStack {
                        ProgressView()
                        Text(busy).font(.caption)
                    }
                }
            }

            Section {
                Button("1. 执行握手（自动判断）") { ble.handshakeAuto() }
                Button("2. 订阅全部通知") { ble.subscribeAll() }
                Button("3. 拍快照（第 \(ble.snapshotCount + 1) 次）") { ble.takeSnapshot() }
                Button("读取全部") { ble.readAll() }
                Button("导出日志") { shareItem = ble.exportFile().map(ShareItem.init) }
                Button("断开连接", role: .destructive) { ble.disconnect() }
            } header: {
                Text("操作")
            } footer: {
                Text("拍一次快照 → 在相机上改一个设置（比如 C1 的胶片模拟）→ 再拍一次，日志会列出变化的数据。")
            }

            Section("最近日志") {
                ForEach(ble.logs.suffix(6)) { e in
                    Text(e.text).font(.caption2.monospaced()).lineLimit(3)
                }
                NavigationLink("全部日志（\(ble.logs.count) 条）") { LogView() }
            }

            ForEach(ble.services, id: \.uuid) { s in
                Section {
                    ForEach(s.characteristics ?? [], id: \.uuid) { c in
                        NavigationLink {
                            CharacteristicView(characteristic: c)
                        } label: {
                            CharacteristicRow(characteristic: c)
                        }
                    }
                } header: {
                    Text("\(Fuji.names[s.uuid] ?? "服务") \(s.uuid.uuidString)").font(.caption2)
                }
            }
        }
        .navigationTitle("已连接")
        .sheet(item: $shareItem) { item in ActivityView(items: [item.url]) }
    }
}

struct CharacteristicRow: View {
    @EnvironmentObject var ble: BLEManager
    let characteristic: CBCharacteristic

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(Fuji.label(characteristic.uuid)).font(.subheadline)
                if characteristic.isNotifying { Image(systemName: "bell.fill").font(.caption2) }
            }
            Text(characteristic.properties.short).font(.caption2).foregroundStyle(.secondary)
            if let v = ble.values[ble.key(characteristic)] {
                Text(v.hex).font(.caption2.monospaced()).lineLimit(2)
            }
        }
    }
}

struct CharacteristicView: View {
    @EnvironmentObject var ble: BLEManager
    let characteristic: CBCharacteristic
    @State private var hexInput = ""
    @State private var withResponse = true

    var body: some View {
        let c = characteristic
        let value = ble.values[ble.key(c)]
        Form {
            Section("信息") {
                Text(c.uuid.uuidString).font(.caption.monospaced()).textSelection(.enabled)
                Text("服务 \(c.service?.uuid.uuidString ?? "?")").font(.caption2.monospaced())
                Text("属性：\(c.properties.short)")
            }
            Section("当前值") {
                Text(value?.hex ?? "（未读取）").font(.caption.monospaced()).textSelection(.enabled)
                if let value { Text(value.ascii).font(.caption.monospaced()) }
                if c.properties.contains(.read) {
                    Button("读取") { ble.enqueueRead(c) }
                }
                if c.properties.canSubscribe {
                    Button(c.isNotifying ? "取消订阅" : "订阅") { ble.enqueueNotify(c, on: !c.isNotifying) }
                }
            }
            if c.properties.contains(.write) || c.properties.contains(.writeWithoutResponse) {
                Section("写入（十六进制）") {
                    TextField("例如 01 00", text: $hexInput)
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                    Toggle("需要响应", isOn: $withResponse)
                    Button("写入") {
                        if let d = Data(hexString: hexInput) {
                            ble.enqueueWrite(c, d, withResponse: withResponse)
                        } else {
                            ble.log("⚠️ 十六进制格式不对：\(hexInput)")
                        }
                    }
                }
            }
        }
        .navigationTitle(Fuji.label(c.uuid))
        .onAppear { withResponse = c.properties.contains(.write) }
    }
}

// MARK: - Log

struct LogView: View {
    @EnvironmentObject var ble: BLEManager
    @State private var shareItem: ShareItem?

    var body: some View {
        ScrollViewReader { proxy in
            List(ble.logs) { e in
                Text(e.text)
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
                    .id(e.id)
            }
            .listStyle(.plain)
            .onAppear { if let last = ble.logs.last { proxy.scrollTo(last.id, anchor: .bottom) } }
            .onChange(of: ble.logs.count) {
                if let last = ble.logs.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
        .navigationTitle("日志")
        .toolbar {
            Button("导出") { shareItem = ble.exportFile().map(ShareItem.init) }
        }
        .sheet(item: $shareItem) { item in ActivityView(items: [item.url]) }
    }
}

struct ShareItem: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
