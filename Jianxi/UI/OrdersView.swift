import SwiftUI

struct OrdersView: View {
    @EnvironmentObject var model: AppModel
    @State private var now = Date()
    private let timer = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let session = model.waterSession {
                    waterCard(session)
                }
                if let order = model.order, !order.phase.finished {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("当前订单").font(.system(size: 13, weight: .semibold)).foregroundColor(.secondary)
                        OrderCard(order: order, now: now, highlighted: true)
                    }
                }
                if model.history.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "tray")
                            .font(.system(size: 36))
                            .foregroundColor(.secondary)
                        Text("暂无订单记录")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 50)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("订单记录（本机最近 \(OrderHistory.limit) 条）")
                            .font(.system(size: 13, weight: .semibold)).foregroundColor(.secondary)
                        ForEach(model.history) { order in
                            OrderCard(order: order, now: now, highlighted: false)
                        }
                    }
                }
            }
            .padding(16)
        }
        .navigationTitle("订单")
        .onReceive(timer) { value in now = value }
        .onAppear {
            if let order = model.order, !order.phase.finished {
                model.refreshOrder(order, silent: true)
            }
            if model.waterSession?.active == true {
                model.refreshWater(silent: true)
            }
        }
    }

    private func waterPhaseText(_ phase: WaterPhase) -> String {
        switch phase {
        case .starting: return "启动指令发送中"
        case .waiting: return "已提交，等待设备出水"
        case .using: return "正在用水"
        case .ending: return "正在结束用水"
        case .settling: return "用水结束，等待结算"
        case .ended: return "本次用水已结束"
        case .unknown: return "状态未确认，请刷新"
        case .rejected: return "启动被拒绝"
        }
    }

    private func waterCard(_ session: WaterSession) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(session.device.name).font(.system(size: 16, weight: .semibold))
                Spacer()
                Text(waterPhaseText(session.phase))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(session.phase == .using ? .green : .orange)
            }
            Text("出水口：\(session.outlet.name)").font(.system(size: 12)).foregroundColor(.secondary)
            if !session.amount.isEmpty {
                Text("当前计费：¥\(session.amount)").font(.system(size: 14, weight: .medium))
            }
            HStack(spacing: 10) {
                if session.active {
                    Button("刷新状态") { model.refreshWater() }
                        .buttonStyle(SecondaryButtonStyle())
                    if session.phase == .using || session.phase == .ending {
                        Button("结束用水") { model.endWater() }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                } else {
                    Button("清除记录") { model.dismissWaterSession() }
                        .buttonStyle(SecondaryButtonStyle())
                }
            }
        }
        .card()
    }
}

struct OrderCard: View {
    @EnvironmentObject var model: AppModel
    let order: LocalOrder
    let now: Date
    let highlighted: Bool

    private var phaseColor: Color {
        switch order.phase {
        case .paid: return .green
        case .completed: return .blue
        case .created, .paymentPending, .creating, .unconfirmed: return .orange
        case .rejected, .closed, .cancelled: return .secondary
        default: return .purple
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(order.deviceName).font(.system(size: 16, weight: .semibold))
                Spacer()
                Text(order.phase.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(phaseColor)
            }
            Text("\(order.modeName) · \(order.payMethod.title) · ¥\(order.amount)")
                .font(.system(size: 13)).foregroundColor(.secondary)
            Text(formatTime(order.createdAt))
                .font(.system(size: 11)).foregroundColor(.secondary)
            if let progress = order.progress {
                progressView(progress)
            }
            if !order.orderNo.isEmpty {
                Text("单号 \(order.orderNo)").font(.system(size: 10)).foregroundColor(.secondary)
            }
            HStack(spacing: 10) {
                if !order.orderId.isEmpty || !order.orderNo.isEmpty {
                    Button("刷新") { model.refreshOrder(order) }
                        .buttonStyle(SecondaryButtonStyle())
                }
                if !order.phase.finished && !order.orderNo.isEmpty && (order.phase == .created || order.phase == .paymentPending) {
                    Button("继续付款") { model.resumePayment(order) }
                        .buttonStyle(SecondaryButtonStyle())
                }
                if !order.phase.finished && !order.orderId.isEmpty && !order.isWater {
                    Button("取消订单") { model.cancelOrder(order) }
                        .buttonStyle(SecondaryButtonStyle())
                }
            }
        }
        .card()
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(highlighted ? Color.accentColor.opacity(0.6) : Color.clear, lineWidth: 1.5)
        )
    }

    private func progressView(_ progress: LaundryProgress) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if progress.completionConfirmed {
                Label("服务器已确认完成", systemImage: "checkmark.seal.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.blue)
            } else if progress.running {
                if let fraction = progress.remainingFraction(now: now.timeIntervalSince1970) {
                    ProgressView(value: 1 - fraction)
                }
                if let remaining = progress.remainingSeconds(now: now.timeIntervalSince1970) {
                    Text(remaining > 0 ? "预计剩余 \(formatRemaining(remaining))" : "预计时间已到，以设备实际状态为准")
                        .font(.system(size: 12))
                        .foregroundColor(remaining > 0 ? .primary : .orange)
                }
                if let end = progress.expectedEndAt {
                    Text("预计完成 \(formatTime(end))")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }
            }
        }
    }
}