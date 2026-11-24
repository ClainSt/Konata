/// Konata v3 受控基础 UI 原语出口（业务 Feature 严禁直接导入 `material_ui` / `cupertino_ui`）。
///
/// 通过单一受控出口收口图标集、透明色与基础路由/加载原语，确保未来底层 UI 库演进仅改本包一处。
library;

export 'package:cupertino_ui/cupertino_ui.dart' show CupertinoPageRoute;
export 'package:material_ui/material_ui.dart'
    show
        Checkbox,
        CircularProgressIndicator,
        Colors,
        Divider,
        GlobalMaterialLocalizations,
        IconButton,
        Icons,
        InputBorder,
        InputDecoration,
        LinearProgressIndicator,
        Material,
        MaterialApp,
        MaterialPageRoute,
        MaterialType,
        Scaffold,
        Slider,
        SliderTheme,
        SliderThemeData,
        TextField,
        Theme,
        ThemeData,
        ThemeMode,
        Tooltip,
        TooltipTriggerMode;
