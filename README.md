# CloseApps — 应用关闭面板

一个 macOS 原生小工具：半透明毛玻璃面板，以**卡片网格**列出正在运行的应用；每张卡片**下方直接显示该应用打开的窗口列表**（含标题），卡片右上角 **✕** 可将应用连同所有辅助进程**彻底关闭**。

## 使用

```bash
open CloseApps.app
```

应用已安装到 `/Applications/CloseApps.app`，可在启动台（Launchpad）或聚焦搜索（Spotlight）中直接搜索 "CloseApps" 打开。分发给他人：让对方打开 [CloseApps.dmg](CloseApps.dmg)，把 CloseApps.app 拖入 Applications 文件夹即可（未做开发者 ID 签名，他人首次打开需右键 →「打开」绕过 Gatekeeper）。

- 面板整体为**半透明毛玻璃**（`NSVisualEffectView` + `underWindowBackground` 材质），能透出桌面和背后的窗口，亮暗模式自动适配；标题栏已隐藏文字，按住面板空白处即可拖动
- 卡片为系统原生**振动材质**（`popover`），同样半透明；鼠标悬停时卡片切换为强调高亮、✕ 变红 —— 与通知中心小组件的交互一致
- 卡片自动刷新（每 2 秒 + 应用启动/退出事件实时触发），每张卡片显示应用的图标、名字和 PID，按窗口宽度自动分列
- **窗口卡片**：授权「辅助功能」后，**打开 2 个及以上窗口的应用**会在其应用卡片后面跟随显示每张窗口的大卡片（应用图标 + 窗口标题）——**点击窗口卡片打开（前置）那个具体窗口**（跨桌面自动切换、最小化自动还原），点卡片上的 ✕ 只关闭这一个窗口。只有 0/1 个窗口的应用不显示窗口卡（应用卡已覆盖）；无标题的隐藏窗口自动过滤。所有卡片同尺寸、按名称顺序**连续流式排列不留空位**
- **✕ 彻底关闭**：连同应用的所有辅助进程（微信的小程序/Helper 进程、Chrome 的 GPU/渲染进程、VS Code 的扩展宿主等）一起清理 —— 点击时先记下整个进程树，礼貌退出 2.5 秒后仍存活则对全树 SIGKILL
- **点击卡片本身**：激活该应用（等同点 Dock 图标，**在其他桌面也会自动切换过去**）
- **面板置顶**：📌 图钉按钮切换，状态记忆
- 卡片徽章显示窗口数（多窗口时 "PID x · N 窗口"）；列表每 2 秒自动刷新
- 面板整体毛玻璃 + 卡片半透明 + 悬停高亮；默认 4 列、内容超出可滚动，窗口宽度可随意拖动调整

## 首次使用需要授权

显示窗口标题需要「辅助功能」权限：打开 **系统设置 → 隐私与安全性 → 辅助功能**，勾选 CloseApps（面板顶部有横幅一键跳转）。不授权也能用，只是看不到窗口列表。注意：本应用用 ad-hoc 签名，**每次重新编译后 macOS 会视为新应用**，需要把列表里的 CloseApps 取消勾选再重新勾选一次。
- 面板自己不会出现在列表里（防止把自己关掉）；后台进程（菜单栏工具等）也不显示，只列出有窗口的常规应用

## 应用图标（Logo）

图标用 CoreGraphics 脚本生成：深色圆角底板上三张毛玻璃卡片（蓝 / 绿 / 橙圆点），右下角一枚红色关闭徽章（白色 ✕），呼应应用本身的功能。

重新生成图标并打进应用：

```bash
./tools/make_icon.sh   # 生成 assets/icon_1024.png 与 assets/AppIcon.icns
./build.sh             # build.sh 会自动把 icns 打包进 .app
```

## 重新构建 / 打包

```bash
./build.sh    # 构建项目目录下的 CloseApps.app
```

安装到本机：把 `CloseApps.app` 拖入 `/Applications`（或双击 `CloseApps.dmg` 拖入其中的 Applications 快捷方式）。生成 DMG：项目里已附带 `CloseApps.dmg`；需要重新生成时，用 `hdiutil create -volname CloseApps -srcfolder <含 .app 与 Applications 符号链接的目录> -format UDZO CloseApps.dmg`。

依赖：macOS 自带的 Swift 命令行工具（`xcode-select --install`），无第三方依赖。

## 文件结构

```
src/main.swift        全部源码（纯 AppKit，单文件：毛玻璃窗口 + 卡片网格 + 关闭逻辑）
src/Info.plist         应用描述文件
build.sh               构建脚本：编译并打包成 CloseApps.app
tools/make_icon.swift  Logo 绘制脚本（CoreGraphics）
tools/make_icon.sh     生成 iconset 并打包 .icns
assets/                图标源文件（icon_1024.png / AppIcon.icns）
CloseApps.app          构建产物
```

## 注意

- 彻底关闭相当于强制结束进程，目标应用里**未保存的内容会丢失**（关闭前会先给 2.5 秒礼貌退出时间，应用若响应退出请求可正常保存退出）
- 系统自带应用如"访达（Finder）"被关闭后会自动重新启动，属正常现象
