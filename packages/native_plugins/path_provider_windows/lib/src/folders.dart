// 遵循 Flutter 官方组件 BSD 开源许可协议（详见随包 LICENSE 文件）。

/* 沿用 Win32 KnownFolder GUID 常量命名格式，保留分析豁免 */ // ignore_for_file: non_constant_identifier_names

/* 仅暴露静态 GUID 常量集合，保留类结构豁免 */ // ignore: avoid_classes_with_only_static_members
/// 收录 Windows 官方已知文件夹对应的 GUID 引用常量集合；
/// 调用方可将本类常量属性传入 `PathProvidersWindows.getPath` 以查询对应系统目录路径。
/// 供 Windows 路径服务查询具体系统文件夹使用。
// 下列常量定义源自微软官方已知文件夹文档：
// 参考地址：`knownfolderid` 系统常量说明。
class WindowsKnownFolder {
  /// 当前用户专属的系统管理工具存储目录（控制台配置等漫游文件所在位置）。
  static String get AdminTools => '{724EF170-A42D-4FEF-9F26-B60E846FBA4F}';

  /// 光盘刻录暂存文件系统目录（待写入 CD 的文件缓冲区）。
  static String get CDBurning => '{9E52AB10-F80D-49DF-ACB8-4330F5687855}';

  /// 计算机所有用户共享的系统管理工具目录。
  static String get CommonAdminTools =>
      '{D0384E7D-BAC3-4797-8F14-CBA229B392B5}';

  /// 所有用户“开始”菜单共享的公共程序组目录。
  static String get CommonPrograms => '{0139D44E-6AFE-49F2-8690-3DAFCAE6FFB8}';

  /// 所有用户共享的“开始”菜单根目录。
  static String get CommonStartMenu => '{A4115719-D62E-491D-AA7C-E74B8BE3B067}';

  /// 所有用户开机自动启动程序所在的共享启动目录。
  static String get CommonStartup => '{82A5EA35-D9CD-47C5-9629-E15D2F714E6E}';

  /// 面向系统全部用户提供的公共文档模板目录。
  static String get CommonTemplates => '{B94237E7-57AC-4347-9151-B08C6C32D1F7}';

  /// 代表“我的电脑/此电脑”的虚拟根目录（涵盖本地磁盘、打印机及控制面板）。
  static String get ComputerFolder => '{0AC0837C-BBF8-452A-850D-79D08E667CA7}';

  /// 代表“网络连接”的虚拟目录，包含本机网络与拨号连接项。
  static String get ConnectionsFolder =>
      '{6F0CD92B-2E97-45D1-88FF-B0D186B8DEDD}';

  /// 承载系统控制面板各功能图标的虚拟文件夹。
  static String get ControlPanelFolder =>
      '{82A74AEB-AEB4-465C-A014-D097EE346D63}';

  /// 用于存储网页 Cookie 与浏览历史等互联网数据的文件系统公共目录。
  static String get Cookies => '{2B0F765D-C0E9-4171-908E-08A611B84FF6}';

  /// 代表 Windows 桌面命名空间根节点的虚拟目录。
  static String get Desktop => '{B4BFCC3A-DB2C-424C-B029-7FE99A87C641}';

  /// 代表桌面“我的文档”项目的虚拟文件夹。
  static String get Documents => '{FDD39AD0-238F-46AF-ADB4-6C85480369C7}';

  /// 供存储互联网下载内容的文件系统目录。
  static String get Downloads => '{374DE290-123F-4565-9164-39C4925E467B}';

  /// 当前用户互联网“收藏夹”存储目录。
  static String get Favorites => '{1777F761-68AD-4D8A-87BD-30B759FA33DD}';

  /// 承载系统已安装字体的虚拟目录（通常位于系统 Fonts 文件夹）。
  static String get Fonts => '{FD228CB7-AE11-4AE3-864C-16F3910AB8FE}';

  /// 用于存储网页 Cookie 与浏览历史等互联网数据的文件系统公共目录。
  static String get History => '{D9DC8A3B-B784-432E-A781-5A1130A75963}';

  /// 存储临时网页与互联网缓存文件的文件系统目录。
  static String get InternetCache => '{352481E8-33BE-4251-BA85-6007CAEDCF9D}';

  /// 代表桌面 Internet Explorer 项的虚拟目录。
  static String get InternetFolder => '{4D9F7874-4E0C-4904-967B-40B0D20C3E4B}';

  /// 面向本机非漫游应用程序数据的存储目录（Local Application Data）。
  static String get LocalAppData => '{F1B32785-6FBA-4FCF-9D55-7B8E7F157091}';

  /// 当前用户公共音乐文件存储目录（我的音乐）。
  static String get Music => '{4BD8D571-6D19-48D3-BE97-422220080E43}';

  /// 包含“网上邻居”虚拟文件夹中快捷方式对象的文件系统目录（NetHood）。
  static String get NetHood => '{C5ABBF53-E17F-4121-8900-86626FC2C973}';

  /// 代表同一工作组内其余网络计算机的虚拟文件夹。
  static String get NetworkFolder => '{D20BEEC4-5CA8-4905-AE3B-BF251EA09B53}';

  /// 当前用户公共图片与相册存储目录（我的图片）。
  static String get Pictures => '{33E28130-4E1E-4676-835A-98395C3BC3BB}';

  /// 包含“打印机”虚拟目录内快捷方式对象的目录（PrintHood）。
  static String get PrintHood => '{9274BD8D-CFD1-41C3-B35E-B13F55A758F4}';

  /// 承载本机已安装打印机列表的虚拟目录。
  static String get PrintersFolder => '{76FC4E2D-D6AD-4519-A663-37BD56068185}';

  /// 当前用户的系统配置根目录（业务应用不应直接在此层级散落文件）。
  static String get Profile => '{5E6C858F-0E22-4760-9AFE-EA3317B67173}';

  /// 面向本机所有用户共享的应用程序数据目录（公共非漫游应用配置与缓存）。
  static String get ProgramData => '{62AB5D82-FDC1-4DC3-A9DD-070D1D495D97}';

  /// 系统应用程序安装根目录（Program Files）。
  static String get ProgramFiles => '{905e63b6-c1bf-494e-b29c-65b732d3d21a}';

  /// 公共应用程序组件共享目录（Common Program Files）。
  static String get ProgramFilesCommon =>
      '{F7F1ED05-9F6D-47A2-AAAE-29D317C6F066}';

  /// 64 位系统下的本机架构公共程序组件目录链接（x64 Common Files）。
  static String get ProgramFilesCommonX64 =>
      '{6365D5A7-0F0D-45e5-87F6-0DA56B6A4F7D}';

  /// 64 位系统下对应 32 位兼容层的公共程序组件目录链接（x86 Common Files）。
  static String get ProgramFilesCommonX86 =>
      '{DE974D24-D9C6-4D3E-BF91-F4455120B917}';

  /// 64 位系统下的本机架构程序安装目录链接（Program Files）。
  static String get ProgramFilesX64 => '{6D809377-6AF0-444b-8957-A3773F02200E}';

  /// 64 位系统下对应 32 位兼容层的程序安装目录链接（Program Files x86）。
  static String get ProgramFilesX86 => '{7C5A40EF-A0FB-4BFC-874A-C0F2E0B9FA8E}';

  /// 当前用户专属“开始”菜单程序组目录。
  static String get Programs => '{A77F5D77-2E2B-44C3-A6A2-ABA601054A51}';

  /// 所有用户桌面共享展示的文件与快捷方式目录（公用桌面）。
  static String get PublicDesktop => '{C4AA340D-F20F-4863-AFEF-F87EF2E6BA25}';

  /// 所有用户共享的公用文档存储目录。
  static String get PublicDocuments => '{ED4824AF-DCE4-45A8-81E2-FC7965083634}';

  /// 所有用户共享的公用音乐文件存储目录。
  static String get PublicMusic => '{3214FAB5-9757-4298-BB61-92A9DEAA44FF}';

  /// 所有用户共享的公用图片与视频文件存储目录。
  static String get PublicPictures => '{B6EBFB86-6907-413C-9AF7-4FC2ABF07CC5}';

  /// 所有用户共享的公用视频文件存储目录。
  static String get PublicVideos => '{2400183A-6185-49FB-A2D8-4A392A602BA3}';

  /// 记录当前用户最近访问文档快捷方式的系统目录（Recent）。
  static String get Recent => '{AE50C081-EBD2-438A-8655-8A092E34987A}';

  /// 代表当前用户系统“回收站”的虚拟目录。
  static String get RecycleBinFolder =>
      '{B7534046-3ECB-4C18-BE4E-64CD4CB7D6AC}';

  /// 系统主题与本地化资源数据所在目录。
  static String get ResourceDir => '{8AD10C31-2ADB-4296-A8F7-E4701232C972}';

  /// 当前用户漫游型应用程序数据存储目录（Application Data）。
  static String get RoamingAppData => '{3EB685DB-65F9-4CF6-A03A-E3EF65729F3D}';

  /// 包含右键“发送到”菜单快捷项目的用户系统目录（SendTo）。
  static String get SendTo => '{8983036C-27C0-404B-8F08-102D10DCFD74}';

  /// 当前用户个人“开始”菜单根目录。
  static String get StartMenu => '{625B53C3-AB48-4EC1-BA1F-A1EF4146FC19}';

  /// 当前用户登录时自动运行程序的个人“启动”目录。
  static String get Startup => '{B97D20BB-F46A-4C97-BA10-5E3608430854}';

  /// Windows 核心系统目录（System32）。
  static String get System => '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}';

  /// 32 位兼容系统目录（64 位系统上通常映射为 SysWOW64）。
  static String get SystemX86 => '{D65231B0-B2F1-4857-A4CE-A8E7C6EA7D27}';

  /// 当前用户专属文档模板存储目录。
  static String get Templates => '{A63293E8-664E-48DB-A079-DF759E0509F7}';

  /// 当前用户个人视频文件存储目录（我的视频）。
  static String get Videos => '{18989B1D-99B5-455B-841C-AB7C74E4DDFC}';

  /// Windows 安装根目录或 `%SYSTEMROOT%` 环境变量对应路径。
  static String get Windows => '{F38BF404-1D43-42F2-9305-67DE0B28FC23}';
}
