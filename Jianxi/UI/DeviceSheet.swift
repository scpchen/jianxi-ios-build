import SwiftUI

struct DeviceSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.presentationMode) private var presentationMode

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    if let device = model.device {
                        laundrySection(device)
                    } else if let water = model.waterDevice {
                        waterSection(water)
                    }
                }
                .padding(16)
            }
            .navigationTitle(model.device?.isDryer == true ? "烘干机" : (model.waterDevice != nil ? "饮水机" : "洗衣设备"))
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(leading: Button("关闭") { presentationMode.wrappedValue.dismiss() })
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    private func laundrySection(_ device: Device) -> some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(device.name).font(.system(size: 18, weight: .bold))
                Text("设备编号 \(device.id) · \(device.isDryer ? "烘干机" : (device.category == "01" ? "洗鞋机" : "洗衣机"))")
                    .font(.system(size: 12)).foregroundColor(.secondary)
                if device.remainingMinutes > 0 {
                    Text("设备剩余占用约 \(device.remainingMinutes) 分钟")
                        .font(.system(size: 12)).foregroundColor(.orange)
                }
                if !device.error.isEmpty {
                    Text(device.error).font(.system(size: 12)).foregroundColor(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()

            VStack(alignment: .leading, spacing: 10) {
                Text(device.isDryer ? "选择烘干模式" : "选择洗衣模式")
                    .font(.system(size: 13, weight: .semibold)).foregroundColor(.secondary)
                ForEach(device.modes) { mode in
                    Button(action: { model.selectMode(mode) }) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(mode.name).font(.system(size: 15, weight: .medium)).foregroundColor(.primary)
                                if !mode.feature.isEmpty {
                                    Text(mode.feature).font(.system(size: 11)).foregroundColor(.secondary)
                                }
                            }
                            Spacer()
                            Text("¥\(mode.price)").font(.system(size: 15, weight: .semibold)).foregroundColor(.accentColor)
                            if model.selectedMode?.id == mode.id {
                                Image(systemName: "checkmark.circle.fill").foregroundColor(.accentColor)
                            }
                        }
                        .padding(10)
                        .background(model.selectedMode?.id == mode.id ? Color.accentColor.opacity(0.1) : Color.clear)
                        .cornerRadius(10)
                    }
                }
            }
            .card()

            if device.isDryer, let mode = model.selectedMode, !mode.dryerDurations.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("选择烘干时长").font(.system(size: 13, weight: .semibold)).foregroundColor(.secondary)
                    ForEach(mode.dryerDurations, id: \.minutes) { duration in
                        Button(action: { model.selectDuration(duration) }) {
                            HStack {
                                Text("\(duration.minutes) 分钟").font(.system(size: 15)).foregroundColor(.primary)
                                if !duration.description.isEmpty {
                                    Text(duration.description).font(.system(size: 11)).foregroundColor(.secondary)
                                }
                                Spacer()
                                Text("¥\(duration.price)").font(.system(size: 15, weight: .semibold)).foregroundColor(.accentColor)
                                if model.selectedDuration?.minutes == duration.minutes {
                                    Image(systemName: "checkmark.circle.fill").foregroundColor(.accentColor)
                                }
                            }
                            .padding(10)
                            .background(model.selectedDuration?.minutes == duration.minutes ? Color.accentColor.opacity(0.1) : Color.clear)
                            .cornerRadius(10)
                        }
                    }
                }
                .card()
            }

            if let quote = model.quote {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("确认金额").font(.system(size: 13, weight: .semibold)).foregroundColor(.secondary)
                        Spacer()
                        Text("¥\(quote.amount)").font(.system(size: 24, weight: .bold)).foregroundColor(.accentColor)
                    }
                    Text("已核对：仅含所选项目，不使用积分抵扣")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                    Divider()
                    Text("支付方式").font(.system(size: 13, weight: .semibold)).foregroundColor(.secondary)
                    ForEach(model.methods, id: \.method) { route in
                        Button(action: { model.selectPayment(route) }) {
                            HStack {
                                Image(systemName: route.method == .alipay ? "a.circle.fill" : "creditcard.fill")
                                    .foregroundColor(.accentColor)
                                Text(route.title).font(.system(size: 15)).foregroundColor(.primary)
                                Spacer()
                                if model.payMethod?.method == route.method {
                                    Image(systemName: "checkmark.circle.fill").foregroundColor(.accentColor)
                                }
                            }
                            .padding(10)
                            .background(model.payMethod?.method == route.method ? Color.accentColor.opacity(0.1) : Color.clear)
                            .cornerRadius(10)
                        }
                    }
                    Button("付款 ¥\(quote.amount)") { model.pay() }
                        .buttonStyle(PrimaryButtonStyle())
                    if model.payMethod?.method == .alipay {
                        Text("iOS 上支付宝可能被平台风控拦截；若提示交易风险，请改用账户余额，或在官方胖乖生活 App 内用「单号」找到这笔订单付款")
                            .font(.system(size: 11)).foregroundColor(.orange)
                    }
                    Text("付款前会再次复核账单与定位，金额变化会要求重新确认")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }
                .card()
            } else {
                Button(device.isDryer ? "确认模式与时长，查看金额" : "确认模式，查看金额") { model.preview() }
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
    }

    private func waterSection(_ device: WaterDevice) -> some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(device.name).font(.system(size: 18, weight: .bold))
                Text("饮水机 · 按用量后付费").font(.system(size: 12)).foregroundColor(.secondary)
                if !device.announcement.isEmpty {
                    Text(device.announcement).font(.system(size: 12)).foregroundColor(.orange)
                }
                if !device.error.isEmpty {
                    Text(device.error).font(.system(size: 12)).foregroundColor(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()

            VStack(alignment: .leading, spacing: 10) {
                Text("选择出水口").font(.system(size: 13, weight: .semibold)).foregroundColor(.secondary)
                ForEach(device.outlets) { outlet in
                    Button(action: { model.selectOutlet(outlet) }) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(outlet.name).font(.system(size: 15, weight: .medium)).foregroundColor(.primary)
                                if !outlet.rate.isEmpty {
                                    Text(outlet.rate).font(.system(size: 11)).foregroundColor(.secondary)
                                }
                            }
                            Spacer()
                            if model.selectedOutlet?.id == outlet.id {
                                Image(systemName: "checkmark.circle.fill").foregroundColor(.accentColor)
                            }
                        }
                        .padding(10)
                        .background(model.selectedOutlet?.id == outlet.id ? Color.accentColor.opacity(0.1) : Color.clear)
                        .cornerRadius(10)
                    }
                }
            }
            .card()

            if !model.waterRoutes.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("结算方式").font(.system(size: 13, weight: .semibold)).foregroundColor(.secondary)
                    ForEach(model.waterRoutes, id: \.wire) { route in
                        Button(action: { model.selectWaterPayment(route) }) {
                            HStack {
                                Text(route.title).font(.system(size: 15)).foregroundColor(.primary)
                                Spacer()
                                if model.waterPayment?.wire == route.wire {
                                    Image(systemName: "checkmark.circle.fill").foregroundColor(.accentColor)
                                }
                            }
                            .padding(10)
                            .background(model.waterPayment?.wire == route.wire ? Color.accentColor.opacity(0.1) : Color.clear)
                            .cornerRadius(10)
                        }
                    }
                }
                .card()
            }

            Button("启动饮水机") { model.startWater() }
                .buttonStyle(PrimaryButtonStyle())
            Text("按用量计费，使用后请及时结束用水并核对账单")
                .font(.system(size: 11)).foregroundColor(.secondary)
        }
    }
}
