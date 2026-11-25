# konata_design_system

## 职责边界
- Konata v3 三端同源唯一视觉设计系统底座（Windows 桌面、Android 平板、Android 手机）。
- **严格 0 Riverpod、0 业务依赖、0 桌面原生插件依赖**（仅依赖 `flutter`、`material_ui`、`cupertino_ui`、`konata_contracts`），确保业务 Feature 隔离具体 UI 框架且 Android Release 零桌面残留。

## 唯一公开出口
- `package:konata_design_system/konata_design_system.dart`

## 核心导出子模块
- **视觉与几何令牌（`tokens`）**：`KonataUiPlatform`、`KonataPalette`、`KonataBadgeColors`、`KonataPaletteContext`、`KonataAdaptiveTokens`、`KonataTheme`、`KonataPlaybackTokens`。
- **标准控件库（`widgets`）**：`AdaptiveActionHeader`、`AdaptiveCardGrid`、`AdaptiveResponsiveRow`、`AdaptiveSettingsCategory`、`AdaptiveSettingsContainer`、`BangumiScoreWordmarkBadge`、`EllipsisTextWithTooltip`、`KonataAdaptiveBackdropBlur`、`KonataWindowResizeScope`、`KonataAmbientShellBackdrop`、`KonataAuroraFieldCanvas`、`KonataCapsuleIconButton`、`KonataAudioLoopButton`、`KonataCdDiscPlaceholder`、`KonataDraggableDialog`、`KonataDraggableScrollbar`、`KonataDropdown`、`KonataDropdownOption`、`KonataGlassCapsule`、`KonataGlassDialog`、`showKonataGlassDialog`、`KonataGlassMenuItem`、`showKonataGlassMenu`、`KonataGlassSideSheet`、`showKonataGlassSideSheet`、`KonataKeepAliveTabSwitcher`、`KonataManagedImage`、`KonataManagedImageProvider`、`KonataThumbnailByteLru`、`KonataSmartCoverAlignmentCache`、`KonataSmartCoverFraming`、`KonataCoverAlignmentBuilder`、`quantizeKonataImageWidth`、`KonataOsdStrokedText`、`KonataPageHeader`、`KonataPillButton`、`KonataPopoverOptionTile`、`KonataSegmentedCapsule`、`KonataSegmentOption`、`KonataSoftTextField`、`KonataSpecBadge`、`EpisodeCategoryBadge`、`KonataSurfaceCard`、`KonataListTile`、`KonataSectionHeader`、`KonataSwitch`、`KonataToastController`、`KonataToastData`、`KonataToastScope`、`KonataToastViewport`、`showKonataToast`、`KonataVolumeControl`。
- **三端自适应外壳（`shell`）**：`KonataBottomClearanceScope`、`KonataModalLayerRegistry`、`KonataModalLayerScope`、`KonataModalRouteScope`、`KonataRootRouteObserver`、`FloatingMiniPlayerKind`、`FloatingMiniVisualState`、`FloatingMiniEdgeSide`、`AdaptiveCapsuleLayout`、`KonataNavItem`、`CapsuleNavigation`、`KonataTopNavBar`、`KonataAdaptiveShell`、`AndroidScrollCaptureBridge`。

- 全局 Toast 支持位于 Navigator Overlay 外部；关闭按钮保留语义标签与触控交互，仅在可用 Overlay 内启用 Tooltip。
