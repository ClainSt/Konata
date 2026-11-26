---
name: konata-ui-design-system
description: >-
  Konata v3 设计系统（packages/foundation/konata_design_system）的三端同源视觉、零 Riverpod 隔离、
  自适应悬浮胶囊、可拖拽音视频小窗与零闲置动效红线。设计、迁移或审查任何 UI 组件、弹窗、抽屉、设置面板或页面布局时激活。
---

# Konata v3 三端统一设计系统与交互规范

本设计系统收口于 `packages/foundation/konata_design_system/`，完整承载 Windows 桌面、Android 平板与 Android 手机的同源视觉语言。

## 1. 硬性隔离边界

1. **0 Riverpod、0 业务、0 基础设施依赖**：设计系统仅依赖 `flutter`、`konata_contracts` 及底层基础控件库，严禁导入 `flutter_riverpod`、`konata_storage`、`engine_*` 或 `feature_*`。
2. **UI 框架隔离**：各 `packages/features/*` 页面与弹窗仅依赖 `package:flutter/widgets.dart` 与 `package:konata_design_system/konata_design_system.dart`，严禁在业务 Feature 内直接导入 `material.dart` / `material_ui` / `cupertino_ui` 或散落硬编码色值、圆角、模糊度与动画时长。
3. **唯一控件库**：毛玻璃弹窗、侧滑抽屉、弹出菜单、胶囊 Toast、圆角下拉框、可搜索下拉框、显式 `ScrollController` 可拖拽滚动条、截断悬浮 Tooltip 与规格角标全站只此一套实现。

## 2. 三端同源外壳与避让红线

1. **视觉完全同源**：Android 手机和平板 100% 复用 Windows 的色彩层级、毛玻璃、边框、圆角与排版，严禁另设独立主题或 Material 换皮。
2. **自适应导航形态**：
   - Windows 桌面保留顶栏纯文字导航与窗口透光材质（确保 `Window.hideWindowControls()` 生效，不现双套按钮）；
   - Android 仅按视口最短边实时判断：`shortestSide >= 600dp` 展示左侧安全区边缘、纵向居中、紧凑包裹的悬浮胶囊；`< 600dp` 展示底部安全区上方、横向居中、紧凑包裹的悬浮胶囊（横屏同样适用，禁撑满边缘，触控热区 >= 48dp）。
3. **统一音视频悬浮小窗**：三端取消底部宽条播放栏，统一采用安全区内可自由拖拽吸附的悬浮小窗（视频 16:9 跨页零重建实时渲染；音频圆形封面折叠态、长胶囊展开态与贴边态，轮廓进度及真实播放律动）；公共外壳统一注入安全区、导航胶囊与悬浮小窗避让。
4. **设置页自适应**：Windows 与平板左右分栏；手机一级仅显示分类与状态摘要，点击推入二级面板，返回键优先回到分类层；Android 自动过滤桌面独占设置项。

## 3. 高频零损耗与验证矩阵

1. **有限动效与零闲置 Ticker**：全屏/小窗形变采用临界阻尼弹簧（`SpringSimulation`）结束即停钟；禁止在空闲页面保留常驻闪烁/脉动动画；高频进度与拖拽坐标直连叶子 `ValueNotifier`，禁止带动整页或导航胶囊重建。
2. **四视口回归**：任何布局改动须覆盖窄屏手机（`390x780`）、横屏手机、平板双方向（`1024x700`）与桌面（`1440x900`）的组件测试，确认零溢出、零遮挡。
3. **验证命令**：
   ```powershell
   dart run tool/verify.dart guard
   dart run tool/verify.dart test packages/foundation/konata_design_system
   ```
