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

4. **动画：逐帧插值与 AX 写搬出主线程，改用 CVDisplayLink 驱动。**
   （`extensions/window/libwindow.m` 的 `HSAnimDriver` + `extensions/window/window.lua`）

   原来（上游 1.0.0）：Lua 在主线程上用 `timer.new(0.017, animate)` 逐帧算插值、逐帧写 AX。
   两个后果：PaperWM 的重排（一次 ≈8ms，单是 `visibleWindows()` 就 7.77ms）、窗口事件回调、
   Lua GC 都会推迟动画步进；而且 17ms 与 60Hz 的 16.67ms 不同源，步进落在刷新的哪个相位不固定。

   现在：`HSAnimDriver` 在 CVDisplayLink 的回调线程上（= 显示器刷新节拍）做插值，并在
   **同一个线程上直接发 AX 写**。Lua 只负责记账（哪些窗口在动画、目标帧是什么），集合变化时
   用 `_animSync(list)` 把整份清单交给驱动，驱动跑完一批再 `dispatch_async` 回主线程通知
   （`_animOnFinish`）。主线程一个像素都不碰。

   两处刻意的取舍：
   - 主线程的 `_animSync` / `_animCancel` 与驱动的「每窗口 AX 写」**共用一把短锁**，所以主线程
     最多等一次 AX 写（实测 ~0.4ms）。换来的是「取消之后绝不会再写回旧位置」这个确定语义 ——
     `stopAnimation(snap=true)` 紧接着要写终帧，不能被打回。
   - 进度不跨时钟假设：Lua 给出起始 `elapsed`，之后由驱动按自己量到的 delta 推进。

   宽高不变的纯位移动画，中间帧只写一次位置（上游是 size→position→size 三次），终帧始终写
   完整帧；这个判断由驱动比较 from/to 的宽高得出，不额外读 AX。

   实测（同一刺激：三次 `cycle_width`、间隔 0.2s；5ms 采样器量主线程间隔）：

   | | 旧（Lua 主线程 17ms 定时器） | 新（display-link 驱动） |
   | --- | --- | --- |
   | 主线程 >8ms 停顿 | 29 / 35 / 36 | **14 / 14 / 9** |
   | 主线程 >15ms 停顿 | 15 / 15 / 11 | **2 / 1 / 0** |
   | 最大间隔 | 26.4 / 33.6 / 33.5 ms | 34.3 / **16.8 / 12.6** ms |
   | 5ms 采样点（理想 599） | 544–545 | **585–594** |

   单窗口 0.3s 位移动画：19 次位置变化、**间隔中位数 16.6ms**（显示器周期 16.67ms）、
   终帧精确、**动画期间 Lua 侧写帧 0 次**（写操作确实搬到了驱动线程）。

   CoreVideo 上游没有链接，这里在 `Hammerspoon/Build Configs/Project-Base.xcconfig` 的
   `OTHER_LDFLAGS` 里加 `-framework CoreVideo`（没动 pbxproj）。

   已知局限：驱动线程上没有 AX 消息超时，某个 app 卡在一次 AX 写上会让**所有**窗口的动画一起停
   （主线程仍是自由的；加超时现在反而是安全的，是现成的后续旋钮）；多显示器时 CVDisplayLink
   每个显示器各回调一次（约 2× 步数，时长不受影响，AX 写量大约翻倍）；空闲时 display link 会停掉。

   ⚠️ 量过渡过程别用 `window:frame()` —— 它在动画期间返回的是**目标帧**（`getAnimationFrame`），
   要读 `_topLeft()` / `_size()` 才看得到逐帧位置。

   **试过又撤掉的两种做法**（留个教训）：
   - 「每次心跳最多重排 N 个窗口」的轮转限流（默认 3）：6 窗口下每窗口 34.0–34.1ms 一帧
     （≈29fps），放开是 16.9–17.0ms（≈59fps），观感明显变顿。而它换来的「主线程 >8ms 停顿次数」
     重复测量极不稳定（同一配置量到过 21 次和 2 次）。等于用一个测不准的收益换掉一个确定的损失。
   - `_setFrame` 里「先读一次尺寸再决定写几次」：每帧多一次 AX 读，只在尺寸不变时有收益，
     缩放类动画里是净亏。已连同上面那条一起撤掉。

   教训：**优化动画要量单窗口帧率，别只量主线程停顿次数。**

5. **把「动画在飞 / 动画结束」暴露给窗口管理器类插件。**
   （`hs.window.animationsInFlight()`、`hs.window.addAnimationsIdleCallback(fn)` / `removeAnimationsIdleCallback(fn)`）

   为什么需要：动画是逐帧写 AX 做的，每次写都会 raise `windowMoved` / `windowResized`（实测
   0.3 秒的一次动画，单窗口就发出 33 次通知）。窗口管理器若把这些事件当成「用户挪了窗口」去
   重排，就形成「写帧 → 事件 → 重排 → 又写帧」的自激环。上游只能靠「关掉监视器 +
   `animationDuration+0.02` 秒后无条件开回来」这个盲开来躲；PaperWM 侧已经改成用这两个 API
   精确判断（补丁见 nix-dotfiles 仓库的 `macos/paperwm-anim-guard.patch`）。

   顺带一个实测发现：上游 `windows.lua` 的 `moveWindow` 用了 `Timer.doAfter(...)` 却**不持有
   返回值**，而 Hammerspoon 的 timer 被 GC 时会 `stop`。隔离测过：不持有的 `doAfter` 回调
   不会触发，持有的正常；`focusWindow` 里也有一处同样写法（重聚焦保护）。**但我没有证明它在
   实际使用中造成可见故障** —— 正确插桩后重测，上游路径同样能发现外部挪动窗口并把它拉回布局。

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
当初是为了「找找上游后来怎么改动画的」。其中跟窗口动画直接相关的两笔是：

- `b362b2aa` add setFrame method that disables enhanced UI during the move
- `a31ffea7` replace lua setFrame with internal implementation

**⚠️ 更正：这两笔不是提速，照搬反而更慢。** 读实际 diff：`a31ffea7` 把 `_setFrame` 从 Lua 搬进
ObjC，落到的却是 `b362b2aa` 新写的 `HSwindow setFrame:`，而它是

```
AXUIElementCreateApplication(pid)
AXUIElementCopyAttributeValue(appElement, "AXEnhancedUserInterface", ...)   // 每次都读
if (hadEnhancedUI) AXUIElementSetAttributeValue(..., false)                 // +1 写
setSize; setTopLeft; setSize;                                              // 3 写（和上游一样）
if (hadEnhancedUI) AXUIElementSetAttributeValue(..., true)                  // +1 写
```

也就是每次调用的 AX 往返从「3 次写」变成「1 读 + 3 写 + 概率 2 写」，还多一次
`AXUIElementCreateApplication` 分配。代码注释自己写着是 **for reliability**（解决 Enhanced UI
开着时某些 app 行为不对），不是性能。而 `animate()` 是**每帧每窗口**调一次 `_setFrame` ——
直接 cherry-pick 过来动画会明显更卡。「搬进 ObjC 省掉 Lua 开销」也省不到东西：那点算术是
纳秒级，0.4ms 全在 IPC 上。所以在 `custom` 里**没有**走这条路。

当初试编过：在 Xcode 14.2 上能出产物，运行时探针也确认 backport 的代码真的被加载了
（`window_filter.lua` 2325 行 vs 原版 2310 行）。留着这个分支主要当「上游改了哪些窗口相关
东西」的索引，要用就在它上面开工。

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
