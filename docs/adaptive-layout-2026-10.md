# 屏幕适配与操作体验

## 设计方案

主题为皮克敏日常助手，保留叶绿色和地图主视觉。主操作 `#287D46`，深绿文字 `#173D27`，淡绿 `#E7F1E5`，白色 `#FFFFFF`，浅底 `#F6FAF3`，提醒色 `#B66A17`。深色模式由语义颜色和自适应色处理。文字使用 San Francisco / 系统中文字体，标题与正文跟随 Dynamic Type，数值等宽。

手机优先保持地图可操作，操作面板可收起且保留主操作；宽窗口把操作放进右侧栏。正文左对齐，资料页限制阅读宽度，按钮至少 44 点触控高度。

```
手机                      宽窗口
[ 模式 / 状态 ]           [ 模式 / 状态 ]
[ 搜索        ]           [ 搜索       | 操作说明 ]
[ 地图        ]           [ 地图       | 选项     ]
[ 可收起选项  ]           [            | 开始     ]
[ 开始 / 恢复 ]           [            | 恢复定位 ]
```

方案审视：去掉首页六个实际重复跳转的方格，保留地图、连接和记录三个直接入口。保留游戏场景的绿色与今日步数信息；减少装饰阴影和花纹。地图状态详情改为独立页面，避免展开后遮挡地图搜索。

## Implemented in 0.1.5 (6)

- Measured top safe-area content replaces the map's fixed 122-point offset. The search/banner height is also measured before sizing the bottom panel.
- Phones begin with secondary options collapsed. Wide windows use a side panel, with primary actions first; iPad split windows follow their actual available width.
- Content-sized scroll areas prevent oversized panels on ordinary screens and make actions reachable at accessibility sizes. Search focus hides the phone panel until the keyboard closes.
- Route start/stop and restore-location controls are separate. GPX import is beside the empty-route tools. A keyboard Done button dismisses coordinate/goal entry.
- Connection diagnostics open in a scrollable sheet. At accessibility sizes, the compact status keeps its title while details remain available in the sheet.
- Dashboard columns adapt to available width and become one column at accessibility sizes. Three distinct shortcuts replace six overlapping destinations. System fonts, semantic colors, and deeper button backgrounds improve text readability.
- Pairing content has a readable maximum width, an inset action bar, and a copy-code action. Settings place pairing and VPN near the top; deleting HealthKit steps requires confirmation in the app.
- The joystick offers VoiceOver direction adjustment and pause, and its release animation respects Reduce Motion.
- Added English and Traditional Chinese translations for new controls and pairing state text.

## Verification

- Existing runtime suite: 52 tests passed. Includes location hold after stopping, authorization/network/grace-period cases, coordinate conversion and GPX parsing.
- Unsigned device Release archive: all three production bundles use version 0.1.5, build 6.
- Native layout harness: 17 scenarios plus 2 scrolled states, covering 320, 375, 430, 667 and 1024-point widths; portrait/landscape; normal, accessibility3 and accessibility5 type; light/dark.
- Visual review caught and fixed the expanding blank panel, clipped primary labels at the largest type size, and unreachable overflow without scrolling.
- In the simulator's interactive route fixture, tapping the options control changed its accessibility value from collapsed to expanded. Start invoked the callback and changed the action to Stop; Stop returned it to Start.
- The route preview uses a local placeholder canvas and fixture options. Home and pairing use production views with fixture services. This verifies layout and shared component interaction, not live MapKit, authorization, HealthKit, or iOS 27 pairing.
- Actual iPhone/iPad installation, iOS 27 pairing, file-provider GPX selection, VoiceOver on a device, and physical joystick behavior still need device validation. Existing Rust library linker/debug-symbol warnings remain; no Swift compilation errors occurred.

See `Tools/LayoutPreview/README.md` for reproduction instructions. Images are saved under `artifacts/layout-0.1.5/`.
