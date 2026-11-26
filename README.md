# 简洗 iOS 移植版

基于 [简洗 Android 11.1.0（构建 49）](https://github.com/xiyuchengxu/jianxi/releases/tag/v11.1.0) 的协议与业务规则，用 SwiftUI 重写的 iOS 客户端。接口线协议兼容胖乖生活 1.144.0（versionCode 294）。

完全免费，禁止倒卖。本应用与胖乖生活官方无关。

## 功能

- 短信验证码登录（胖乖生活账号通用）
- 扫码识别设备：相机扫码、相册二维码、手动粘贴二维码内容或 IMEI
- 洗衣机 / 洗鞋机：模式选择、报价核对、单次付款
- 烘干机：模式 + 烘干时长选择、报价核对
- 饮水机：出水口选择、按用量后付费（余额 / 支付宝）、远程结束用水、账单结算
- 支付：账户余额直接扣款；支付宝通过收银台 scheme 拉起支付宝 App（无需 SDK），付款结果一律以服务端 `order/pay_status` 为准
- 安全规则与安卓版一致：不使用积分抵扣、付款前复核账单（`order/detail`）、金额/项目不一致即停止、拒绝签约类支付参数、余额付款结果未知只查询不重复扣款
- 订单：本机最近 20 条记录、刷新、取消、继续付款、洗衣进度（预计剩余时间 / 服务器确认完成）
- 常用设备收藏、重命名、删除
- 洗衣进度本地通知（区分“预计时间已到”和“已确认完成”）
- 浅色 / 深色 / 跟随系统主题
- 排错日志（最近 200 条，可导出分享）

## 相比安卓版未移植的功能

- Shizuku 后台保活、云端微信提醒（iOS 无对应机制）
- 桌面壁纸透明背景、MIUIX 主题、开屏图、控件透明度（Android 专属）
- 多语言（当前仅简体中文）
- 积分签到页
- 饮水机支付宝免密签约流程：若设备要求签约，会提示先在胖乖生活 App 完成签约
- 蓝牙设备、先用后付洗衣设备（安卓版同样不支持）

## 获取 IPA

- **直接下载**：到本仓库 [Releases](../../releases) 页面下载最新的 `Jianxi-1.0.0-unsigned.ipa`（未签名），传到 iPhone（微信文件传输 / QQ / iCloud 云盘 / 局域网均可）。
- **Fork 自动构建（无需 Mac）**：Fork 本仓库后，任意 push 或手动触发 Actions 里的 "Build IPA"，约 5–10 分钟构建完成，IPA 自动发布到你仓库的 Releases。
- **本地构建（需要 Mac）**：`brew install xcodegen` → `xcodegen generate` → 用 Xcode 打开 `Jianxi.xcodeproj` 编译，或命令行 `xcodebuild -scheme Jianxi -sdk iphoneos CODE_SIGNING_ALLOWED=NO build`。

## 安装（TrollStore）

1. 确认 iPhone 已安装 TrollStore（支持 iOS 14.0–16.6.1 的部分版本）。
2. 用 TrollStore 打开 IPA → Install。TrollStore 会自动完成伪签名，永久有效，无需重签。
3. 首次启动同意使用须知，登录胖乖账号即可使用。

未签名 IPA 也可以改用 Sideloadly / AltStore + Apple ID 自签安装（7 天有效期）。

## 目录结构

- `project.yml` — XcodeGen 工程配置（CI 自动生成 Xcode 工程）
- `Jianxi/Core` — 协议、签名、报价/账单校验、订单状态机（对照安卓版 core 包移植）
- `Jianxi/Data` — 网络层（userapi.qiekj.com）、Keychain 会话、本地存储、定位、排错日志
- `Jianxi/ViewModels/AppModel.swift` — 主状态机（对照 LaundryViewModel 移植）
- `Jianxi/UI` — SwiftUI 界面
- `.github/workflows/build-ipa.yml` — macOS 云端构建未签名 IPA

## 风险提示

- 第三方客户端存在账号风控风险，重要操作建议同时在原应用核对。
- 支付宝收银台 scheme 拉起方式依赖支付宝 App 版本行为，若拉起失败请改用余额支付；无论拉起是否成功，付款确认都以服务端查询为准，不会重复扣款。
- 登录已在真机验证；支付流程未经真实扣款回归测试（与安卓版发布口径一致，业务回归基于协议对照），首次使用建议先小额验证。

## 致谢

- [xiyuchengxu/jianxi](https://github.com/xiyuchengxu/jianxi)（简洗 Android 版，MIT）：本项目的协议分析、业务规则与状态机均移植自该项目。

## 协议

MIT（与原项目一致），见 [LICENSE](LICENSE)。
