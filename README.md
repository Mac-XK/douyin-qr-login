# 抖音远程扫码登录系统

## 这是什么

一套用于远程控制越狱 iOS 设备完成抖音扫码登录的工具。场景大概是这样的：你有一台（或多台）越狱的 iPhone/iPad 装着抖音，但设备不在手边，或者你需要批量管理多个设备的登录状态。通过这套系统，你可以在浏览器里点一下「新建登录」，设备那边就会自动弹出抖音的二维码登录页面，二维码实时回传到网页上，你用另一台手机扫一下就完成登录了。

整个项目分两部分：一个跑在服务器上的 PHP 后端 + Web 面板，一个注入到抖音里的 iOS Tweak。

---

## 项目结构

```
.
├── DYComment/              # iOS 越狱插件（Theos 工程）
│   ├── Tweak.x            # 主逻辑：远程控制 + 二维码截取 + 状态上报
│   ├── BundleSpoof.x      # Bundle ID 伪装 + 屏蔽强制升级弹窗
│   ├── Makefile            # 编译配置，目标 iOS 14.0+
│   ├── control             # Debian 包描述
│   └── DYComment.plist    # 注入目标：com.ss.iphone.ugc.Aweme
├── Server/                 # 服务端
│   ├── api.php            # 后端接口，JSON 文件存储
│   └── index.html         # Web 管理面板（单文件，无依赖）
├── DYComment.dylib         # 编译好的插件产物
└── 抖音证书登录（DD）.dylib  # 另一个 dylib，证书登录相关
```

---

## 工作原理

整个流程是一个「命令-执行-回报」的循环，服务器充当中间人：

```
浏览器（Web 面板）  <──轮询──>  PHP 后端  <──轮询──>  越狱设备（Tweak）
```

具体跑起来是这样的：

1. 你在网页上点「新建登录」，后端创建一条任务，同时往命令队列里塞一条 `start_login` 指令
2. 设备端的 Tweak 每 5 秒轮询一次后端，拿到这条指令
3. Tweak 在抖音里 present 出二维码登录页面（`AWEQRCodeLoginCoreViewController`）
4. 等二维码渲染完成后（延迟 2 秒），Tweak 截取 `qrCodeImageView` 的图片，转成 base64 上传到后端
5. 网页端每 2 秒刷新一次任务列表，拿到二维码图片后直接显示
6. 你用手机抖音扫这个二维码，设备端 hook 了 `setQrcodeState:` 方法，状态变化会实时上报
7. 扫码确认后状态变成 `success`，网页上显示登录成功

### 状态流转

```
pending → qr_loaded → scanned → success
                  ↘ expired（超时没扫）→ 点刷新 → refreshing → qr_loaded
```

Tweak 里对 `qrcodeState` 的映射：

| 值 | 含义 | 上报状态 |
|---|---|---|
| 1 | 加载中 | pending |
| 2 | 待扫码 | qr_loaded |
| 3 | 已扫码待确认 | scanned |
| 4 | 登录成功 | success |
| 5 | 登录失败 | failed |
| 6 | 二维码过期 | expired |

---

## Tweak 部分详解

### Tweak.x — 核心逻辑

这个文件大概 300 行，干的事情不复杂但细节不少：

**远程控制机制：**
- 应用启动后开一个 5 秒间隔的 NSTimer 轮询服务器
- 支持三种命令：`start_login`（弹出登录页）、`refresh`（刷新二维码）、`dismiss`（关闭登录页）
- 用两个全局字典维护 VC 和 task 的映射关系（`gActiveVCs` 和 `gTaskForVC`），通过指针地址做 key

**设备适配：**
- iPad 优先用 `AWEUserLoginFullScreenPadQRScannerViewController`（全屏扫码页，UI 更完整）
- iPhone 或 iPad fallback 时直接用 `AWEQRCodeLoginCoreViewController`
- 自动生成设备 ID，格式是 `iPad_设备名` 或 `iPhone_设备名`

**Hook 点：**
- `viewDidLoad` — 记录日志
- `loadRQCodeImage` — 二维码加载完成后截图上传（延迟 2 秒等渲染）
- `setQrcodeState:` — 状态变化时上报，对 `qr_loaded` 做了去重（因为抖音轮询时会反复设置 state=2）
- `monitorQRLoginResult:` — 登录成功时上报 success

**注意的点：**
- 二维码截取用的是直接读 `UIImageView.image` 然后转 PNG base64，不是截屏
- 刷新二维码时优先模拟点击 refreshBtn（更接近真实操作），fallback 才调 `loadRQCodeImage`
- 有个 `dy_dismissSelf` 的 `%new` 方法，给 iPhone 直接 present CoreVC 时加关闭按钮用的

### BundleSpoof.x — 伪装层

重签名或侧载后 Bundle ID 会变（比如变成 `com.xxx.Aweme`），抖音服务器会校验这个值，不一致就拒绝登录。这个文件做了全方位的伪装：

**Bundle ID 替换：**
- Hook `NSBundle` 的 `bundleIdentifier` 和 `infoDictionary`，返回值里只要包含 "Aweme" 就替换成 `com.ss.iphone.ugc.Aweme`
- Hook `NSURLRequest` / `NSMutableURLRequest` 的 header 读写方法，拦截所有可能携带 Bundle ID 的请求头字段（列了 12 种常见的 key）
- Hook `NSURLSessionConfiguration` 的 `HTTPAdditionalHeaders`，确保全局配置里的也被替换

**屏蔽升级弹窗：**
- Hook `AWEAccountForceUpgradeManager` 的 `shouldShowUpgradeAPPPanel` 直接返回 NO
- Hook `AWELoginAlertView` 的弹窗方法，拦截包含"版本过低"文字的弹窗

这两个处理是必要的，因为侧载版本号通常不是最新的，不屏蔽的话一打开就弹升级提示，登录流程走不下去。

---

## 服务端部分详解

### api.php

轻量级实现，没用数据库，所有数据存在 `data/` 目录下的 JSON 文件里：

- `tasks.json` — 任务列表
- `commands.json` — 命令队列
- `heartbeat.json` — 设备心跳（按 device_id 分开存）

写文件时用了 `flock` 加排他锁，防止并发写坏。命令超过 5 分钟自动清理。

接口一览：

| action | 调用方 | 说明 |
|--------|--------|------|
| `create_task` | 前端 | 创建任务 + 下发 start_login 命令 |
| `get_tasks` | 前端 | 获取所有任务 + 设备在线状态 |
| `refresh_qr` | 前端 | 刷新指定任务的二维码 |
| `delete_task` | 前端 | 删除任务 + 下发 dismiss 命令 |
| `get_command` | Tweak | 心跳 + 拉取待执行命令 |
| `upload_qr` | Tweak | 上传二维码图片（base64） |
| `update_status` | Tweak | 上报状态变化 |
| `ack_command` | Tweak | 确认命令已执行 |

设备在线判断：最后一次心跳距现在不超过 15 秒就算在线。

### index.html

单文件 Web 面板，没有任何外部依赖，纯 HTML + CSS + vanilla JS。UI 做得还挺精致的，深色渐变头部 + 卡片式布局，有状态徽章、加载动画、过期遮罩这些细节。

前端每 2 秒轮询一次 `get_tasks`，拿到数据后重新渲染整个卡片列表。支持多设备同时在线显示。

---

## 编译和部署

### Tweak 编译

需要 Theos 环境：

```bash
cd DYComment
make
```

产物是 `DYComment.dylib`，注入目标是 `com.ss.iphone.ugc.Aweme`（抖音主 App）。

编译配置：
- 最低支持 iOS 14.0
- 启用 ARC
- 依赖 UIKit、Foundation 框架

### 服务端部署

把 `Server/` 目录扔到任何支持 PHP 的 Web 服务器上就行。确保 `data/` 目录可写。没有数据库依赖，没有 composer 依赖，开箱即用。

部署后需要改 Tweak.x 里的 `kServerURL` 指向你的服务器地址。

---

## 其他文件

- `DYComment.dylib` — 编译好的通用二进制（arm64 + arm64e）
- `抖音证书登录（DD）.dylib` — 看文件名应该是另一个插件，用于证书方式登录，和这套扫码系统是独立的

---

## 一些实现上的取舍

1. **轮询而非长连接** — Tweak 端 5 秒轮询、前端 2 秒轮询。对于这个场景够用了，实现简单，不需要 WebSocket 服务器。代价是最多有几秒延迟。

2. **JSON 文件而非数据库** — 任务量不大的情况下完全够用，部署零门槛。加了文件锁防并发问题。

3. **base64 传图** — 二维码图片直接 base64 编码塞进 JSON。图片本身不大（PNG 二维码也就几 KB），省得搞文件上传和静态资源服务。

4. **延迟截图** — 二维码加载后等 2 秒再截取，是因为 UIImageView 的 image 设置和实际渲染之间有时间差，太快截到的可能是空的。

5. **状态去重** — 抖音内部轮询登录结果时会反复调用 `setQrcodeState:2`，不做去重的话会疯狂上报。用了两个 static 变量记录上次上报的状态和 task，相同就跳过。
