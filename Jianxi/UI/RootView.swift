import SwiftUI

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ZStack {
            Group {
                if !model.consentAccepted {
                    ConsentView()
                } else if !model.loggedIn {
                    LoginView()
                } else {
                    MainTabs()
                }
            }
            if model.busy {
                BusyOverlay(text: model.progressText)
            }
            if let message = model.message {
                VStack {
                    Spacer()
                    ToastView(text: message)
                        .padding(.bottom, 90)
                }
                .transition(.opacity)
                .zIndex(2)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.message)
    }
}

struct ConsentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Text("简洗")
                .font(.system(size: 40, weight: .bold))
            Text("iOS 移植版 · 胖乖生活第三方客户端")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                Text("· 本应用为开源社区二改客户端，与胖乖生活官方无关，完全免费，禁止倒卖。")
                Text("· 使用你的胖乖生活账号登录，洗衣、烘干、饮水与支付均通过原平台接口完成。")
                Text("· 付款前会复核账单，发现积分抵扣或无法核实明细时会停止付款。")
                Text("· 第三方客户端存在账号风控风险，重要操作建议同时在原应用核对。")
                Text("· 需要相机（扫码）、定位（付款风控）与通知（进度提醒）权限。")
            }
            .font(.system(size: 14))
            .card()
            .padding(.horizontal, 20)
            Button("同意并继续") { model.acceptConsent() }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.horizontal, 20)
            Spacer()
        }
    }
}

struct MainTabs: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        TabView(selection: $model.tab) {
            NavigationView { HomeView() }
                .navigationViewStyle(StackNavigationViewStyle())
                .tabItem { Image(systemName: "house.fill"); Text("首页") }
                .tag(0)
            NavigationView { OrdersView() }
                .navigationViewStyle(StackNavigationViewStyle())
                .tabItem { Image(systemName: "list.bullet.rectangle"); Text("订单") }
                .tag(1)
            NavigationView { SettingsView() }
                .navigationViewStyle(StackNavigationViewStyle())
                .tabItem { Image(systemName: "gearshape.fill"); Text("设置") }
                .tag(2)
        }
        .sheet(isPresented: $model.showDeviceSheet) {
            DeviceSheet()
                .environmentObject(model)
        }
    }
}

struct LoginView: View {
    @EnvironmentObject var model: AppModel
    @State private var phone = ""
    @State private var code = ""

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Text("登录胖乖生活账号")
                .font(.system(size: 24, weight: .bold))
            Text("使用手机号和短信验证码登录，账号与原应用通用")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
            VStack(spacing: 12) {
                TextField("手机号", text: $phone)
                    .keyboardType(.numberPad)
                    .padding(12)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(12)
                HStack(spacing: 10) {
                    TextField("短信验证码", text: $code)
                        .keyboardType(.numberPad)
                        .padding(12)
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(12)
                    Button(model.smsCooldown > 0 ? "\(model.smsCooldown)s" : "获取验证码") {
                        model.sendCode(phone)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(model.smsCooldown > 0)
                }
            }
            .padding(.horizontal, 24)
            Button("登录") { model.login(phone, code) }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.horizontal, 24)
            Spacer()
            Spacer()
        }
    }
}