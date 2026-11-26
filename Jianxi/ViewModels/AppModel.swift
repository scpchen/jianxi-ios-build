import Foundation
import SwiftUI
import UIKit
import UserNotifications

@MainActor
final class AppModel: ObservableObject {
    @Published var consentAccepted: Bool
    @Published var loggedIn: Bool
    @Published var phoneLabel = ""
    @Published var tab = 0
    @Published var busy = false
    @Published var progressText = ""
    @Published var message: String?
    @Published var smsCooldown = 0
    @Published var device: Device?
    @Published var waterDevice: WaterDevice?
    @Published var selectedMode: WashMode?
    @Published var selectedDuration: DryerDuration?
    @Published var quote: Quote?
    @Published var methods: [PayRoute] = []
    @Published var payMethod: PayRoute?
    @Published var order: LocalOrder?
    @Published var history: [LocalOrder] = []
    @Published var savedDevices: [SavedDevice] = []
    @Published var waterSession: WaterSession?
    @Published var waterRoutes: [WaterPayRoute] = []
    @Published var selectedOutlet: WaterOutlet?
    @Published var waterPayment: WaterPayRoute?
    @Published var showDeviceSheet = false
    @Published var appearance: String
    @Published var reminderEnabled: Bool
    @Published var manualCode = ""

    let vault = SessionVault.shared
    let location = LocationProvider()
    private(set) lazy var api = LaundryApi { [vault = self.vault] in vault.token() }
    private var smsTask: Task<Void, Never>?
    private var pendingAlipayOrderNo: String?
    private var messageTask: Task<Void, Never>?

    init() {
        consentAccepted = vault.consentAccepted
        loggedIn = vault.loggedIn()
        appearance = vault.appearance
        reminderEnabled = vault.progressReminderEnabled
        if loggedIn {
            phoneLabel = vault.phoneLabel()
            order = vault.order()
            history = vault.orders()
            savedDevices = vault.savedDevices()
            waterSession = vault.water()
            if let session = waterSession, session.phase == .starting {
                waterSession?.phase = .unknown
                vault.saveWater(waterSession)
            }
        }
    }

    func acceptConsent() {
        vault.consentAccepted = true
        consentAccepted = true
    }

    func notice(_ text: String) {
        message = text
        messageTask?.cancel()
        messageTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            self?.message = nil
        }
    }

    private func handle(_ error: Error) {
        switch error {
        case let error as SessionExpired:
            expireLocalSession(error.msg)
        case let error as BusinessRejected:
            notice(error.display)
        case let error as QuoteChanged:
            quote = error.quote
            notice("价格已更新，请重新确认")
        case let error as ClientError:
            notice(error.msg)
        case is CancellationError:
            break
        default:
            notice("操作未完成，请稍后重试")
        }
    }

    private func work(_ progress: String, _ task: @escaping () async throws -> Void) {
        if busy { return }
        busy = true
        progressText = progress
        Task {
            do { try await task() } catch { handle(error) }
            busy = false
            progressText = ""
        }
    }

    func sendCode(_ phone: String) {
        guard phone.range(of: "^1[3-9]\\d{9}$", options: .regularExpression) != nil else {
            notice("请输入正确的手机号"); return
        }
        guard smsCooldown == 0 else { return }
        work("正在发送验证码") {
            try await self.api.sendCode(phone)
            self.notice("验证码已发送")
            self.smsCooldown = 60
            self.smsTask?.cancel()
            self.smsTask = Task {
                for _ in 0..<60 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if Task.isCancelled { return }
                    self.smsCooldown = max(0, self.smsCooldown - 1)
                }
            }
        }
    }

    func login(_ phone: String, _ code: String) {
        guard phone.range(of: "^1[3-9]\\d{9}$", options: .regularExpression) != nil,
              code.range(of: "^\\d{4,8}$", options: .regularExpression) != nil else {
            notice("请填写手机号和短信验证码"); return
        }
        work("正在登录") {
            let token = try await self.api.login(phone, code)
            self.vault.login(phone: phone, token: token)
            self.smsTask?.cancel()
            self.smsCooldown = 0
            self.loggedIn = true
            self.phoneLabel = self.vault.phoneLabel()
            self.order = self.vault.order()
            self.history = self.vault.orders()
            self.savedDevices = self.vault.savedDevices()
            self.waterSession = self.vault.water()
            if let session = self.waterSession, session.phase == .starting {
                self.waterSession?.phase = .unknown
                self.vault.saveWater(self.waterSession)
            }
            self.tab = 0
        }
    }

    func logout() {
        if busy { return }
        smsTask?.cancel()
        vault.logout()
        loggedIn = false
        phoneLabel = ""
        device = nil; waterDevice = nil; selectedMode = nil; selectedDuration = nil
        quote = nil; methods = []; payMethod = nil
        order = nil; history = []; savedDevices = []
        waterSession = nil; waterRoutes = []; selectedOutlet = nil; waterPayment = nil
        pendingAlipayOrderNo = nil
        showDeviceSheet = false
        tab = 0
    }

    private func expireLocalSession(_ text: String) {
        logout()
        notice(text)
    }

    private func saveOrder(_ value: LocalOrder?) {
        vault.saveOrder(value)
        order = value
        history = vault.orders()
    }

    private func saveWater(_ value: WaterSession?) {
        vault.saveWater(value)
        waterSession = value
    }

    func scan(_ raw: String) {
        guard loggedIn else { notice("请先登录"); return }
        do {
            let code = try DeviceCodes.parse(raw)
            selectDeviceCode(code)
        } catch { handle(error) }
    }

    func submitManualCode() {
        let text = manualCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { notice("请输入二维码内容或设备编号"); return }
        if text.contains("=") || text.contains("?") {
            scan(text)
        } else {
            selectDeviceCode(DeviceCode(key: "IMEI", value: text))
        }
    }

    private func resetDeviceState() {
        device = nil; waterDevice = nil; selectedMode = nil; selectedDuration = nil
        quote = nil; methods = []; payMethod = nil
        waterRoutes = []; selectedOutlet = nil; waterPayment = nil
    }

    func selectDeviceCode(_ code: DeviceCode, expectedName: String? = nil) {
        guard loggedIn else { notice("请先登录"); return }
        let owner = vault.owner()
        let token = vault.token()
        work("正在识别设备") {
            let scanned = try await self.api.scanDevice(code)
            guard self.loggedIn && self.vault.owner() == owner && self.vault.token() == token else { return }
            self.resetDeviceState()
            var name = ""
            var category = ""
            switch scanned {
            case .laundry(let d), .dryer(let d):
                self.device = d
                self.selectedMode = d.modes.first
                self.selectedDuration = d.modes.first?.dryerDurations.first(where: { $0.selectedByPlatform }) ?? d.modes.first?.dryerDurations.first
                name = d.name; category = d.category
                if !d.error.isEmpty { self.notice(d.error) }
            case .water(let d):
                self.waterDevice = d
                self.selectedOutlet = d.outlets.first
                name = d.name; category = "04"
                if !d.error.isEmpty { self.notice(d.error) }
                let routes = try await self.api.waterPaymentRoutes(d)
                guard self.vault.owner() == owner && self.vault.token() == token else { return }
                self.waterRoutes = routes
                self.waterPayment = routes.first { $0.method == .balance } ?? routes.first
            }
            self.rememberDevice(code, name: expectedName ?? name, category: category)
            self.manualCode = ""
            self.showDeviceSheet = true
        }
    }

    private func rememberDevice(_ code: DeviceCode, name: String, category: String) {
        let owner = vault.owner()
        var devices = vault.savedDevices()
        let record = SavedDevice(owner: owner, key: code.key, value: code.value, name: name,
                                 category: category, note: "", savedAt: Date().timeIntervalSince1970)
        if let index = devices.firstIndex(where: { $0.key == code.key && $0.value == code.value }) {
            var existing = devices[index]
            let note = existing.note
            existing = record
            existing.note = note
            devices[index] = existing
        } else {
            devices.append(record)
        }
        vault.saveSavedDevices(devices)
        savedDevices = vault.savedDevices()
    }

    func selectSavedDevice(_ record: SavedDevice) {
        selectDeviceCode(DeviceCode(key: record.key, value: record.value), expectedName: record.note.isEmpty ? record.name : record.note)
    }

    func deleteSavedDevice(_ record: SavedDevice) {
        var devices = vault.savedDevices()
        devices.removeAll { $0.id == record.id }
        vault.saveSavedDevices(devices)
        savedDevices = vault.savedDevices()
    }

    func renameSavedDevice(_ record: SavedDevice, note: String) {
        var devices = vault.savedDevices()
        if let index = devices.firstIndex(where: { $0.id == record.id }) {
            devices[index].note = note
            vault.saveSavedDevices(devices)
            savedDevices = vault.savedDevices()
        }
    }

    func selectMode(_ mode: WashMode) {
        if busy { return }
        selectedMode = mode
        selectedDuration = mode.dryerDurations.first { $0.selectedByPlatform } ?? mode.dryerDurations.first
        quote = nil; methods = []; payMethod = nil
    }

    func selectDuration(_ duration: DryerDuration) {
        if busy { return }
        selectedDuration = duration
        quote = nil; methods = []; payMethod = nil
    }

    func selectPayment(_ route: PayRoute) {
        if busy { return }
        payMethod = route
    }

    func preview() {
        guard let device = device, let mode = selectedMode else { return }
        let duration = selectedDuration
        work("正在确认价格") {
            let quote: Quote
            if device.isDryer {
                guard let d = duration else { throw ClientError("请选择烘干时长") }
                quote = try await self.api.quoteDryer(device, mode, d)
            } else {
                quote = try await self.api.quote(device, mode)
            }
            let methods = try await self.api.channels(quote)
            self.quote = quote
            self.methods = methods
            self.payMethod = methods.first
        }
    }

    func pay() {
        if waterSession?.active == true { notice("请先结束并确认本次饮水，再创建新的订单"); return }
        guard let quote = quote, let route = payMethod else { return }
        guard location.permitted else {
            location.requestPermission()
            notice("付款前需要定位，用于确认设备所在位置，请授权后重试")
            return
        }
        let owner = vault.owner()
        work("正在核对订单") {
            if let current = self.order, !current.phase.finished { throw ClientError("请先处理未完成订单") }
            let fix = try await self.location.current()
            let fresh: Quote
            if quote.device.isDryer {
                guard let d = quote.dryerDuration else { throw ClientError("请选择烘干时长") }
                fresh = try await self.api.quoteDryer(quote.device, quote.mode, d)
            } else {
                fresh = try await self.api.quote(quote.device, quote.mode)
            }
            if fresh.amount != quote.amount || fresh.itemsJson != quote.itemsJson || fresh.tradeType != quote.tradeType {
                throw QuoteChanged(fresh)
            }
            var attempt = LocalOrder(owner: owner, deviceName: quote.device.name, modeName: quote.mode.name,
                                     amount: quote.amount, payMethod: route.method, phase: .creating,
                                     thirdChannel: route.thirdChannel, outVoucherId: route.outVoucherId,
                                     category: quote.device.category)
            self.saveOrder(attempt)
            let created: (id: String, number: String, issue: ClientError?)
            do {
                created = try await self.api.create(fresh, fix)
            } catch let error as BusinessRejected {
                attempt.phase = .rejected
                self.saveOrder(attempt)
                throw error
            } catch let error as SessionExpired {
                attempt.phase = .rejected
                self.saveOrder(attempt)
                throw error
            } catch {
                attempt.phase = .unconfirmed
                self.saveOrder(attempt)
                self.showDeviceSheet = false
                self.tab = 1
                throw error
            }
            attempt.orderId = created.id
            attempt.orderNo = created.number
            attempt.phase = .created
            self.saveOrder(attempt)
            self.showDeviceSheet = false
            self.tab = 1
            if let issue = created.issue { throw issue }
            try await self.startOrResume(attempt)
        }
    }

    private func startOrResume(_ order: LocalOrder) async throws {
        if order.phase == .created {
            do {
                try await startPayment(order)
            } catch let error as BusinessRejected {
                let paid = (try? await api.paid(order)) ?? false
                if paid { try await confirmPaid(order) } else { throw error }
            }
            return
        }
        guard order.phase == .paymentPending else { throw ClientError("订单状态尚未确认，请先核对订单") }
        if try await api.paid(order) {
            try await confirmPaid(order)
            return
        }
        if order.payMethod == .balance {
            notice("余额付款结果仍在确认，请刷新订单查询，不会重复扣款")
            return
        }
        try await startPayment(order)
    }

    private func startPayment(_ order: LocalOrder) async throws {
        let payable = try await api.waterBillPaymentRoute(order)
        if payable != order { saveOrder(payable) }
        if order.payMethod == .balance {
            progressText = "正在提交余额付款"
            var pending = payable
            pending.phase = .paymentPending
            try await api.balancePay(payable) { [vault] in vault.saveOrder(pending) }
            saveOrder(pending)
            try await poll(pending)
        } else {
            progressText = "正在获取支付信息"
            let payload = try await api.prepay(payable)
            try PurchaseRules.verifyAlipay(payload, order.amount)
            var pending = payable
            pending.phase = .paymentPending
            saveOrder(pending)
            pendingAlipayOrderNo = pending.orderNo
            let encoded = payload.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
            let scheme = "alipays://platformapi/startApp?appId=20000125&orderSuffix=\(encoded)"
            if let url = URL(string: scheme), UIApplication.shared.canOpenURL(url) {
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
                notice("已跳转支付宝收银台，完成付款后返回简洗自动查询结果")
            } else {
                notice("未检测到支付宝 App，请安装支付宝，或改用余额支付后在订单中继续付款")
            }
        }
    }

    func alipayReturned() {
        guard let orderNo = pendingAlipayOrderNo,
              let current = order, current.orderNo == orderNo, !current.phase.finished else { return }
        pendingAlipayOrderNo = nil
        work("正在查询付款结果") {
            try await self.poll(current)
        }
    }

    func resumePayment(_ requested: LocalOrder) {
        guard let target = promote(requested), !target.orderNo.isEmpty, !target.phase.finished else { return }
        work("正在核对付款状态") {
            let current = try await self.synchronizeOrderState(target)
            if current.phase.finished {
                self.noticeOrderState(current)
            } else {
                try await self.startOrResume(current)
            }
        }
    }

    private func promote(_ requested: LocalOrder) -> LocalOrder? {
        guard loggedIn, requested.owner == vault.owner() else { return nil }
        if let current = order, OrderHistory.sameOrder(current, requested) { return current }
        if let found = history.first(where: { OrderHistory.sameOrder($0, requested) }) {
            if let current = order, !current.phase.finished && !OrderHistory.sameOrder(current, found) {
                notice("请先处理未完成订单")
                return nil
            }
            saveOrder(found)
            return found
        }
        return nil
    }

    private func poll(_ order: LocalOrder) async throws {
        for index in 0..<5 {
            if try await api.paid(order) {
                try await confirmPaid(order)
                return
            }
            if index < 4 { try await Task.sleep(nanoseconds: 2_000_000_000) }
        }
        let current = try await synchronizeOrderState(order)
        if current.phase.finished { noticeOrderState(current) }
        else { notice("付款结果仍在确认，请稍后刷新订单") }
    }

    private func confirmPaid(_ order: LocalOrder) async throws {
        var paid = order
        paid.phase = .paid
        saveOrder(paid)
        if paid.isWater {
            paid.syncRequested = true
            saveOrder(paid)
            notice("饮水账单付款已确认")
            return
        }
        if !paid.syncRequested {
            paid.syncRequested = true
            saveOrder(paid)
            do {
                try await api.sync(paid)
                notice(paid.isDryer ? "付款已确认，已请求启动烘干机，请查看设备状态" : "付款已确认，已请求同步设备，请查看机器是否启动")
            } catch {
                notice(paid.isDryer ? "付款已确认；烘干启动结果待核实，请查看设备" : "付款已确认；设备同步结果待核实，请查看洗衣机")
            }
        } else {
            notice(paid.isDryer ? "付款已确认，请查看烘干机运行状态" : "付款已确认，请查看洗衣机运行状态")
        }
    }

    func cancelOrder(_ requested: LocalOrder) {
        guard let target = promote(requested) else { return }
        if target.isWater { notice("这是已用水的结算账单，请核对金额后支付"); return }
        guard !target.orderId.isEmpty, !target.phase.finished else { return }
        work("正在取消订单") {
            let current = try await self.synchronizeOrderState(target)
            if current.phase.finished { self.noticeOrderState(current); return }
            if try await self.api.paid(current) { try await self.confirmPaid(current); return }
            do {
                try await self.api.cancel(current)
            } catch let error as BusinessRejected {
                if error.code == 3122 {
                    if let latest = try? await self.synchronizeOrderState(current), latest.phase.finished {
                        self.noticeOrderState(latest)
                        return
                    }
                }
                throw error
            }
            var cancelled = current
            cancelled.phase = .cancelled
            self.saveOrder(cancelled)
            self.cancelReminder(cancelled)
            self.notice("订单已取消")
        }
    }

    func refreshOrder(_ requested: LocalOrder, silent: Bool = false) {
        guard let target = promote(requested) else { return }
        guard !target.orderId.isEmpty || !target.orderNo.isEmpty else {
            notice("上一次下单结果未确认，请先在原应用核对订单")
            return
        }
        if silent {
            Task {
                do { _ = try await self.synchronizeOrderState(target) } catch { }
            }
            return
        }
        work("正在查询订单") {
            let current = try await self.synchronizeOrderState(target)
            self.noticeOrderState(current)
        }
    }

    private func synchronizeOrderState(_ order: LocalOrder) async throws -> LocalOrder {
        let details = try await api.orderDetails(order)
        var current = OrderStates.apply(order, details.status)
        let wasRunning = order.progress?.running ?? false
        current.progress = details.progress
        if current != order { saveOrder(current) }
        updateReminder(current, wasRunning: wasRunning)
        return current
    }

    private func noticeOrderState(_ order: LocalOrder) {
        switch order.phase {
        case .closed: notice("订单已关闭，可以返回首页重新选择模式")
        case .completed: notice("订单已完成")
        case .refunding: notice("订单正在退款，请在原应用查看进度")
        case .refunded: notice("订单已退款，请核对到账情况")
        case .paid:
            notice(order.isWater ? "饮水账单付款已确认" : (order.isDryer ? "烘干订单付款已确认，请查看机器状态" : "付款已确认，请查看洗衣机运行状态"))
        case .cancelled: notice("订单已取消")
        default: notice("尚未确认付款，可稍后再次查询")
        }
    }

    func selectOutlet(_ outlet: WaterOutlet) {
        if busy { return }
        selectedOutlet = outlet
    }

    func selectWaterPayment(_ route: WaterPayRoute) {
        if busy { return }
        waterPayment = route
    }

    func startWater() {
        guard let device = waterDevice, let outlet = selectedOutlet, let payment = waterPayment else { return }
        guard location.permitted else {
            location.requestPermission()
            notice("启动饮水机需要定位，请授权后重试")
            return
        }
        let owner = vault.owner()
        work("正在启动饮水机") {
            if self.waterSession?.active == true { throw ClientError("请先确认上一次饮水的状态") }
            guard device.outlets.contains(outlet) && device.error.isEmpty else { throw ClientError("饮水机当前不可用，请刷新设备") }
            let fix = try await self.location.current()
            let fresh = try await self.api.refreshWaterDevice(device)
            guard fresh.id == device.id && fresh.imei == device.imei && fresh.orgId == device.orgId &&
                    fresh.shopId == device.shopId && fresh.error.isEmpty &&
                    fresh.outlets.first(where: { $0.id == outlet.id }) == outlet else {
                throw ClientError("饮水机状态或计费标准已更新，请重新扫码确认")
            }
            let status = try await self.api.waterStatus(outlet)
            guard status.available else { throw ClientError("饮水机正在使用或状态尚未确认，请先刷新状态") }
            var attempt = WaterSession(owner: owner, device: fresh, outlet: outlet, phase: .starting,
                                       lastStatus: status, initialIdentify: status.identify, payment: payment)
            self.saveWater(attempt)
            let result: WaterStart
            do {
                result = try await self.api.startWater(fresh, outlet, fix, payment)
            } catch let error as WaterStartNotSent {
                attempt.phase = .rejected
                self.saveWater(attempt)
                throw error
            } catch let error as BusinessRejected {
                attempt.phase = .rejected
                self.saveWater(attempt)
                throw error
            } catch let error as SessionExpired {
                attempt.phase = .rejected
                self.saveWater(attempt)
                throw error
            } catch {
                attempt.phase = .unknown
                self.saveWater(attempt)
                throw error
            }
            attempt.phase = result.verificationIssue == nil ? .waiting : .unknown
            attempt.orderNo = result.orderNo
            attempt.msgId = result.msgId
            self.saveWater(attempt)
            self.showDeviceSheet = false
            self.tab = 1
            if let issue = result.verificationIssue { throw issue }
            self.notice("用水指令已提交，请刷新确认出水状态")
        }
    }

    func refreshWater(silent: Bool = false) {
        guard let session = waterSession, session.active else { return }
        let owner = vault.owner()
        let action: () async throws -> Void = {
            let status = try await self.api.waterStatus(session.outlet)
            guard self.vault.owner() == owner else { return }
            var current = WaterRules.apply(session, status)
            if !current.msgId.isEmpty && (current.phase == .waiting || current.phase == .unknown) {
                let accepted = (try? await self.api.waterCommandAccepted(current.msgId)) ?? false
                if accepted && current.phase == .waiting {
                    self.notice("设备已确认接收启动指令")
                }
            }
            if current.phase == .settling {
                if let bill = try await self.api.waterSettlement(current) {
                    self.saveOrder(bill)
                    current.phase = .ended
                    self.notice("饮水已结算，请在订单中核对账单")
                }
            }
            self.saveWater(current)
            if current.phase == .ended { self.notice("本次用水已结束") }
        }
        if silent {
            Task { try? await action() }
        } else {
            work("正在查询饮水状态") { try await action() }
        }
    }

    func endWater() {
        guard let session = waterSession, session.active else { return }
        work("正在结束用水") {
            let latest = try await self.api.waterStatus(session.outlet)
            var current = WaterRules.apply(session, latest)
            self.saveWater(current)
            if latest.ended { self.notice("设备已停止出水"); return }
            guard latest.mine else { throw ClientError("尚未确认这是你的用水会话，请先刷新状态") }
            guard session.device.supportAppFinish else { throw ClientError("这台设备不支持远程结束，请按饮水机上的停止键") }
            current.phase = .ending
            self.saveWater(current)
            try await self.api.endWater(session.device)
            self.notice("结束用水指令已发送，请刷新确认")
        }
    }

    func dismissWaterSession() {
        guard let session = waterSession, !session.active else { return }
        saveWater(nil)
    }

    func setAppearance(_ value: String) {
        appearance = value
        vault.appearance = value
    }

    var colorScheme: ColorScheme? {
        switch appearance {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    func setReminderEnabled(_ value: Bool) {
        reminderEnabled = value
        vault.progressReminderEnabled = value
        if value {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
                Task { @MainActor in
                    if !granted {
                        self.reminderEnabled = false
                        self.vault.progressReminderEnabled = false
                        self.notice("未获得通知权限，请在系统设置中允许简洗通知")
                    }
                }
            }
        } else {
            UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        }
    }

    private func updateReminder(_ order: LocalOrder, wasRunning: Bool) {
        guard reminderEnabled, order.isLaundry || order.isDryer else { return }
        let center = UNUserNotificationCenter.current()
        let identifier = "progress-\(order.orderNo.isEmpty ? order.orderId : order.orderNo)"
        if order.progress?.completionConfirmed == true {
            center.removePendingNotificationRequests(withIdentifiers: [identifier])
            if wasRunning {
                let content = UNMutableNotificationContent()
                content.title = "简洗"
                content.body = "服务器已确认订单完成，请取衣"
                content.sound = .default
                center.add(UNNotificationRequest(identifier: "done-\(identifier)", content: content,
                                                 trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)))
            }
            return
        }
        if let progress = order.progress, progress.running, let end = progress.expectedEndAt {
            let interval = end - Date().timeIntervalSince1970
            guard interval > 5 else { return }
            let content = UNMutableNotificationContent()
            content.title = "简洗"
            content.body = "洗衣预计完成时间已到，请查看设备状态（以设备实际状态为准）"
            content.sound = .default
            center.removePendingNotificationRequests(withIdentifiers: [identifier])
            center.add(UNNotificationRequest(identifier: identifier, content: content,
                                             trigger: UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)))
        }
    }

    private func cancelReminder(_ order: LocalOrder) {
        let identifier = "progress-\(order.orderNo.isEmpty ? order.orderId : order.orderNo)"
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
    }
}