# custom 分支（基于上游 1.0.0）

个人分支，基于 **1.0.0** —— 最后一个能在 macOS 12 Monterey 上跑的版本
（1.1.0+ 硬链接了 macOS 13 才进 Foundation 的 `Foundation.URLRequest` 类型元数据，
在 12.6 上 dyld 加载即失败：`Symbol not found: _$s10Foundation10URLRequestVMn`）。

## 相对 1.0.0 的改动

1. **能在 Xcode 14.2 上编译。** 12.6 能装的最新 Xcode 就是 14.2（14.3+ 要求 macOS 13）。
   上游用 Xcode 15.3 构建，clang 15 认识 `-Wdeprecated-non-prototype`；clang 14 不认识，
   而 `timer` 那个 target 把它当错误，编译直接中断：
   ```
   error: unknown warning option '-Wno-deprecated-non-prototype' [-Werror,-Wunknown-warning-option]
   ```
   在 `Hammerspoon/Build Configs/Project-Base.xcconfig` 的 `WARNING_CFLAGS` 最前面加了
   `-Wno-unknown-warning-option`，让 clang 忽略所有不认识的 `-Wno-*`，一次解决这类差异。

2. **关掉 scheme 里的 sanitizer。** `Hammerspoon.xcscheme`（TestAction / LaunchAction）与
   `Release.xcscheme`（TestAction）原来都开了 ASAN + UBSAN
   （`enableAddressSanitizer` / `enableASanStackUseAfterReturn` / `enableUBSanitizer`）。
   开着的话产物会链接 `libclang_rt.asan_osx_dynamic.dylib` 并把 asan/ubsan 两个 dylib
   打包进 app（实测 63M），而**官方发布的 1.0.0 并没有**（`otool -L` 对比过）——
   跑得慢、内存高，检测到问题还会直接 abort，不适合日用。已全部改成 `"NO"`。
   注意：这些属性**不是构建设置**（`-showBuildSettings` 里查不到
   `ENABLE_ADDRESS_SANITIZER`），命令行覆盖无效，只能改 scheme 文件。

3. **Release 配置的签名默认值改成本地自签名证书。** 上游写死了
   `CODE_SIGN_IDENTITY = Developer ID Application` + `DEVELOPMENT_TEAM = VQCYSNZB89`
   （维护者的证书），本机没有，编 Release 会失败。三个 Release xcconfig
   （`Hammerspoon/Build Configs/Hammerspoon-Release.xcconfig`、`Project-Release.xcconfig`、
   `LuaSkin/LuaSkin-Release.xcconfig`）都改成 `CODE_SIGN_IDENTITY = Internal Code Signing`、
   `DEVELOPMENT_TEAM =`（空），原值留在注释里；要正式签名时在命令行覆盖即可。

4. **动画里的写帧优化（`extensions/window/window.lua`）。** 上游每帧每窗口固定 3 次 AX 写
   （size → position → size）。本分支在动画开始时比较起止宽高：只位移的那类动画，
   中间帧只写一次位置，每帧省 2 次 AX 写；终帧仍写完整帧。**单窗口刷新率与上游完全一致**，
   判断只用已经读到的实际帧，不额外读 AX。

   曾经还有第二处改动「每次心跳最多重排 N 个窗口」的轮转限流（默认 3），已**废弃并移除**。
   它的实测代价：6 窗口下每窗口 34.0–34.1ms 一帧（≈29fps），放开限流是 16.9–17.0ms（≈59fps），
   观感明显变顿。它换来的收益（主线程 >8ms 停顿次数）重复测量极不稳定 —— 同一配置量到过
   21 次和 2 次。等于用一个测不准的收益换掉一个确定的损失。
   教训：**优化动画时别只量主线程停顿次数，要量单窗口帧率。**

## 怎么编

```bash
cd <这个仓库>
xcodebuild -workspace Hammerspoon.xcworkspace -scheme Hammerspoon -configuration Release \
  -derivedDataPath build build
open build/Build/Products/Release/Hammerspoon.app
```

- Debug 同理（`-configuration Debug`）。
- `Pods/` 已随仓库提交，**不需要** `pod install`。

## 两个坑

- **不要用 `scripts/rebuild.sh`。** 它里面有 `killall Hammerspoon` + `open`：如果 Hammerspoon
  正是你的窗口管理器（本机就是，跑 PaperWM），它会把你正在用的实例直接杀掉。只用上面的
  `xcodebuild`，产物落在 `build/`，何时替换 `/Applications/Hammerspoon.app` 自己决定。
- **签名：本分支默认用本地自签名证书 `Internal Code Signing`**（三个 Release xcconfig 都设了）。
  好处是签名身份固定 → **重编后辅助功能授权不会掉**；ad-hoc 签名则二进制一变就被 macOS
  当成新 app，每次重编都要重新授权。
  证书免费，自己生成即可：**钥匙串访问 → 证书助理 → 创建证书…**（名称 `Internal Code Signing`、
  身份类型「自签名根证书」、证书类型「代码签名」），建好后双击它 → 信任 → 把「代码签名」
  设为「始终信任」，再用 `security find-identity -v -p codesigning` 确认能看到它。
  换到没建该证书的机器时，在命令行覆盖成 ad-hoc 即可：
  `xcodebuild ... CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= build`

## 另一个分支：`backport-trial-1.1.0`（素材库，不要直接用）

把上游 `1.0.0..1.1.0` 里挑出来的 31 笔提交放在一起（顶端 `45961392`，基底 1.0.0）。
它不是给日用的，是备着以后想「真正压低每帧的 AX 往返」时取材用。其中跟窗口动画
直接相关的两笔是：

- `b362b2aa` add setFrame method that disables enhanced UI during the move
- `a31ffea7` replace lua setFrame with internal implementation

这两笔把「取帧 / 写帧」从 Lua 搬进 ObjC —— 那才是正路；在 Lua 侧做限流之类的取巧
已经证明是错的（见上面第 4 条）。当初试编过：在 Xcode 14.2 上能出产物，运行时探针也
确认 backport 的代码真的被加载了（`window_filter.lua` 2325 行 vs 原版 2310 行）。
**没有合进 `custom`**，要用就在这个分支上开工。

排除在外的坑（都别跟）：

- `b3ca3cf7`（hs.wifi 弃用修复）用了 macOS 13 才有的 `CWWiFiClient.interfaceNames`，
  在 12.6 上编不过。已确认它不在本分支里。
- 上游那段区间里的 4 笔 pod 升级会把 Sentry 8.32 升到 8.52 —— 那正是 1.1.0 在 12.6 上
  dyld 加载失败（`Symbol not found: _$s10Foundation10URLRequestVMn`）的根源。已排除。
- `e303ca7c` 把 deployment target 抬到 13.0，也排除。

一个小提醒：这个分支是在当时那版 `custom` 上开出来的，签名还是 ad-hoc 那版
（`4e03e91a` 的自签名证书在它之后）—— 直接编的话，重编一次就会掉辅助功能授权。

## 说明

本分支的改动只为「在本机 12.6 + Xcode 14.2 上编译并日用」，不打算回上游。
