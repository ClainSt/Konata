/// Windows 11 原生 DWM 窗口材质类型。
enum KonataWindowMaterial {
  /// 亚克力模糊（高透光率，实时呈现壁纸色彩与光影折射，默认推荐）。
  acrylic('亚克力 (Acrylic)', '高透光模糊，实时折射桌面壁纸光影'),

  /// 云母材质（沉稳融合系统壁纸主色调）。
  mica('云母 (Mica)', '柔和融合系统壁纸主色，视觉更沉稳'),

  /// 云母 Tabbed 变体（高对比云母材质）。
  tabbed('云母变体 (Tabbed)', '高对比度云母背景变体');

  /// 创建窗口材质枚举项。
  const KonataWindowMaterial(this.label, this.subtitle);

  /// 中文显示名称。
  final String label;

  /// 中文说明副标题。
  final String subtitle;
}
