# 富士配方一键导入

一个 iOS App：浏览胶片模拟配方，点一下就通过**蓝牙**写进富士相机的自定义设置（C1–C7）。首个目标机型是 X-T30 III。

## 当前阶段：蓝牙探测（FujiProbe）

富士没有公开蓝牙写入设置的协议，所以第一步是做一个探测工具 `FujiProbe/`，
连上相机，记录相机的全部蓝牙服务、数据和通知，用来摸清写入配方的方式。

握手流程参考开源项目 [furble](https://github.com/gkoh/furble)（富士蓝牙快门遥控器）。

### 安装到 iPhone

1. 用 Xcode 打开 `FujiProbe/FujiProbe.xcodeproj`。
2. 左侧点项目 FujiProbe → TARGETS 里的 FujiProbe → Signing & Capabilities：
   - Team 选你的 Apple ID（免费账号也可以）。
   - 如果提示 Bundle Identifier 已被占用，把 `com.fujirecipe.probe` 改成任意唯一名字，比如 `com.你的名字.fujiprobe`。
3. iPhone 用线连 Mac，顶部设备选你的 iPhone，点 ▶ 运行。
4. 首次运行如提示"未受信任的开发者"：iPhone 设置 > 通用 > VPN 与设备管理 > 信任你的 Apple ID。
   iPhone 还需要打开 设置 > 隐私与安全性 > 开发者模式。

### 测试步骤

1. 相机：设置 > 网络/USB 设置 > 蓝牙/智能手机设置 > **配对登记**，停在这个画面。
   （如果相机已经和富士官方 App 配对过，可以先保持不动，若连不上再到相机里删除配对后重试。）
2. FujiProbe 点「开始扫描」，点出现的相机。
3. 连上后依次点：
   - 「1. 执行握手」——iPhone 可能弹出蓝牙配对请求，点「配对」；相机上如有确认也点确认。
   - 「2. 订阅全部通知」
   - 「3. 拍快照」
4. 在相机上改一个 C1 的设置（例如：编辑/保存自定义设置 > C1 > 胶片模拟换一个），再点一次「拍快照」。
5. 点「导出日志」，把 .txt 文件发过来。

只要握手成功、能拿到日志，就算这一轮成功；看不懂的内容不用管，原样发来即可。
