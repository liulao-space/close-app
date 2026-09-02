# CloseApps — 应用关闭面板

一个 macOS 原生小工具：一个半透明毛玻璃面板，以**卡片网格**的形式列出当前所有正在运行的图形界面应用，每张卡片右上角有一个 **✕ 关闭按钮**，点击即可将应用彻底关闭。

## 使用

```bash
open CloseApps.app
```

应用已安装到 `/Applications/CloseApps.app`，可在启动台（Launchpad）或聚焦搜索（Spotlight）中直接搜索 "CloseApps" 打开。分发给他人：让对方打开 [CloseApps.dmg](CloseApps.dmg)，把 CloseApps.app 拖入 Applications 文件夹即可（未做开发者 ID 签名，他人首次打开需右键 →「打开」绕过 Gatekeeper）。

- 面板整体为**半透明毛玻璃**（`NSVisualEffectView` + `underWindowBackground` 材质），能透出桌面和背后的窗口，亮暗模式自动适配；标题栏已隐藏文字，按住面板空白处即可拖动
- 卡片为系统原生**振动材质**（`popover`），同样半透明；鼠标悬停时卡片切换为强调高亮、✕ 变红 —— 与通知中心小组件的交互一致
- 卡片自动刷新（每 2 秒 + 应用启动/退出事件实时触发），每张卡片显示应用的图标、名字和 PID，按窗口宽度自动分列
- **点击卡片右上角的 ✕**：先礼貌请求该应用退出；若 2.5 秒后仍然存活（比如卡死、弹出保存对话框不理会），自动升级为 `SIGKILL` 强制结束，保证"彻底关闭"
- **点击卡片本身**：激活（切换到）该应用
- 底部状态栏显示最近一次操作的结果；右上角"刷新"按钮可手动刷新
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
