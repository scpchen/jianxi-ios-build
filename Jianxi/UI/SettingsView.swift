import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        List {
            Section(header: Text("账号")) {
                HStack {
                    Text("登录账号")
                    Spacer()
                    Text(model.phoneLabel).foregroundColor(.secondary)
                }
                Button(action: { model.logout() }) {
                    Text("退出登录").foregroundColor(.red)
                }
            }
            Section(header: Text("外观")) {
                Picker("主题", selection: Binding(get: { model.appearance }, set: { model.setAppearance($0) })) {
                    Text("跟随系统").tag("system")
                    Text("浅色").tag("light")
                    Text("深色").tag("dark")
                }
                .pickerStyle(SegmentedPickerStyle())
            }
            Section(header: Text("提醒"), footer: Text("洗衣进度以服务器状态为准；通知区分“预计时间已到”和“已确认完成”。iOS 后台刷新受限，请回到 App 刷新订单获取最新状态。")) {
                Toggle("洗衣进度提醒", isOn: Binding(get: { model.reminderEnabled }, set: { model.setReminderEnabled($0) }))
            }
            Section(header: Text("排错")) {
                NavigationLink("排错日志", destination: DiagnosticsView())
            }
            Section(header: Text("关于"), footer: Text("简洗 iOS 移植版 1.0.0 · 基于简洗 Android 11.1.0（构建 49）协议移植\n原项目 github.com/xiyuchengxu/jianxi · MIT 协议\n完全免费，禁止倒卖。本应用与胖乖生活官方无关。")) {
                HStack {
                    Text("版本")
                    Spacer()
                    Text("1.0.0 (iOS)").foregroundColor(.secondary)
                }
                HStack {
                    Text("协议兼容")
                    Spacer()
                    Text("胖乖生活 1.144.0").foregroundColor(.secondary)
                }
            }
        }
        .listStyle(InsetGroupedListStyle())
        .navigationTitle("设置")
    }
}

struct DiagnosticsView: View {
    @State private var entries = DiagnosticsLog.shared.snapshot()
    @State private var showShare = false

    var body: some View {
        List {
            if entries.isEmpty {
                Text("暂无记录").foregroundColor(.secondary)
            }
            ForEach(entries) { entry in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(entry.operation).font(.system(size: 13, weight: .medium))
                        Spacer()
                        Text(entry.status)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(entry.status == "SUCCESS" ? .green : .orange)
                    }
                    Text("\(formatTime(entry.time.timeIntervalSince1970)) · \(entry.durationMs)ms\(entry.errorCode.map { " · 错误码 \($0)" } ?? "")")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle("排错日志")
        .navigationBarItems(trailing: Button("导出") { showShare = true })
        .onAppear { entries = DiagnosticsLog.shared.snapshot() }
        .sheet(isPresented: $showShare) {
            ShareSheet(items: [DiagnosticsLog.shared.exportText()])
        }
    }
}