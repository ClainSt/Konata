# feature_settings

Konata v3 三端自适应纯设置容器与基础通用设置分区业务包。

## 职责边界

- 仅渲染各 Feature 通过 `SettingsSectionContribution` 按平台过滤注册的设置分区（桌面/平板左右双栏、手机一级分类推入二级路由+返回拦截），绝不横向导入任何其他业务 Feature。
- 内置外观主题、网络与元数据密钥/镜像测试、本机图片存储统计与精准清理、诊断日志一键导出与关于面板。
- 通过 `FeatureManifest` 注册顶层 `settings` 导航分区（权重 `40`）。
