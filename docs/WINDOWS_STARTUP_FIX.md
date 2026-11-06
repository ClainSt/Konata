# Windows 启动修复与自适应界面验收（2026-11-05）

Windows 无法打开已实际复现：SQLite user_version=12，但 works 已包含 bangumi_ids、bangumi_link_info、cover_edit_json、character_order。无条件重复 ALTER TABLE 导致启动异常，窗口未显示。升级现在先检查 PRAGMA table_info，只补缺失列；临时库覆盖旧库无新列、部分新列、全部新列及重复打开，修复前新增两例失败，修复后三例通过。

按用户随后明确指示，清空 CCPlayer 专用应用数据（包含库、进度、配置、缓存、日志、备份）及 Windows 构建缓存，未继续保留旧库。程序重新生成全新空库。Windows 凭证存储前缀从误用的 NipaPlay.Personal.SecureStorage. 改为 CCPlayer.SecureStorage.，不再跨应用读取旧凭证。

全量重建后核对实际 EXE：文件名 CCPlayer.exe，ProductName/FileDescription 均为 CCPlayer；从 EXE 提取出的内嵌图标为现有角色图标，不是 Flutter 标志。正常原生启动已出现标题为 CCPlayer 的窗口及可访问设置内容；隐藏测试启动会保持窗口隐藏，不能拿隐藏启动的 MainWindowHandle=0 判定应用仍崩溃。

后续按设备空间调整设置：Windows 恢复独立弹窗和左右栏；Android 手机一级页只有外观、刮削服务、关于，进入二级页显示控件；Android 平板可用宽度至少 840 时使用左右栏。搜索收起/展开均在同一固定高度工具栏，窄屏直接将计数区域替换为输入框，不增加第二行。已验证 390/1100 宽度、放大字体下开关搜索时工具栏矩形不变。

元数据编辑：ID 信息和关联输入框间留出 24px；标签中括号说明移至下方多行辅助文字。按钮文字不再使用 FittedBox 独立缩小；保持 14px 与统一圆角，长文字允许换行，所有同行按钮等宽等高，并随字体缩放共同增加高度。封面导入本地图片去掉挤占空间的装饰图标，保持完整文字。

当前完整回归 159 通过、1 项联网测试默认跳过；静态分析无问题。窗口原生验证通过，Android 真机交互仍需设备复测。新 Windows 包包含完整 DLL 与 data 目录，应整体解压后运行，不要只复制 EXE。

最终确认：Windows 恢复独立弹窗左右布局；手机因空间受限使用分类与二级页；平板宽屏使用左右栏。最终修复版已从 release/CCPlayer-Windows-x64-Latest/CCPlayer.exe 原生启动，窗口标题 CCPlayer，空库显示“0 部作品 / 请先添加媒体源”。用户正在操作原生窗口时，停止额外自动点击，避免干扰。文件名与产品信息、内嵌角色图标均已核验。

最终交付：release/CCPlayer-Windows-x64.zip（约37.6 MB，完整便携目录），release/CCPlayer-Android-arm64-release.apk（约38 MB）。按用户指示执行的旧应用数据清空已完成，未再次清空用户之后新产生的配置。当前完整回归159项通过，静态分析无问题。
