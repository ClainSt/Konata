import 'package:charset/charset.dart';
import 'package:smb_connect/src/utils/encoding.dart';

/// 收录通用 SMB 协议常量、属性位及共享打开语义编码的工具常量类。
abstract class SmbConstants {
  static const int DEFAULT_PORT = 445;

  static const int DEFAULT_MAX_MPX_COUNT = 10;
  static const int DEFAULT_RESPONSE_TIMEOUT = 30000;
  static const int DEFAULT_SO_TIMEOUT = 10000; //35000;
  static const int DEFAULT_RCV_BUF_SIZE = 0xFFFF;
  static const int DEFAULT_SND_BUF_SIZE = 0xFFFF;

  static const int DEFAULT_CONN_TIMEOUT = 35000;

  static const int FLAGS_NONE = 0x00;
  static const int FLAGS_LOCK_AND_READ_WRITE_AND_UNLOCK = 0x01;
  static const int FLAGS_RECEIVE_BUFFER_POSTED = 0x02;
  static const int FLAGS_PATH_NAMES_CASELESS = 0x08;
  static const int FLAGS_PATH_NAMES_CANONICALIZED = 0x10;
  static const int FLAGS_OPLOCK_REQUESTED_OR_GRANTED = 0x20;
  static const int FLAGS_NOTIFY_OF_MODIFY_ACTION = 0x40;
  static const int FLAGS_RESPONSE = 0x80;

  static const int FLAGS2_NONE = 0x0000;
  static const int FLAGS2_LONG_FILENAMES = 0x0001;
  static const int FLAGS2_EXTENDED_ATTRIBUTES = 0x0002;
  static const int FLAGS2_SECURITY_SIGNATURES = 0x0004;
  static const int FLAGS2_SECURITY_REQUIRE_SIGNATURES = 0x0010;
  static const int FLAGS2_EXTENDED_SECURITY_NEGOTIATION = 0x0800;
  static const int FLAGS2_RESOLVE_PATHS_IN_DFS = 0x1000;
  static const int FLAGS2_PERMIT_READ_IF_EXECUTE_PERM = 0x2000;
  static const int FLAGS2_STATUS32 = 0x4000;
  static const int FLAGS2_UNICODE = 0x8000;

  static const int CAP_NONE = 0x0000;
  static const int CAP_RAW_MODE = 0x0001;
  static const int CAP_MPX_MODE = 0x0002;
  static const int CAP_UNICODE = 0x0004;
  static const int CAP_LARGE_FILES = 0x0008;
  static const int CAP_NT_SMBS = 0x0010;
  static const int CAP_RPC_REMOTE_APIS = 0x0020;
  static const int CAP_STATUS32 = 0x0040;
  static const int CAP_LEVEL_II_OPLOCKS = 0x0080;
  static const int CAP_LOCK_AND_READ = 0x0100;
  static const int CAP_NT_FIND = 0x0200;
  static const int CAP_DFS = 0x1000;
  static const int CAP_LARGE_READX = 0x4000;
  static const int CAP_LARGE_WRITEX = 0x8000;
  static const int CAP_EXTENDED_SECURITY = 0x80000000;

  // SMB 文件基础属性标志位编码定义。
  /// 只读属性标志（ATTR_READONLY）。
  static const int ATTR_READONLY = 0x01;

  /// 隐藏属性标志（ATTR_HIDDEN）。
  static const int ATTR_HIDDEN = 0x02;

  /// 系统文件属性标志（ATTR_SYSTEM）。
  static const int ATTR_SYSTEM = 0x04;

  /// 磁盘卷标属性标志（ATTR_VOLUME）。
  static const int ATTR_VOLUME = 0x08;

  /// 目录节点属性标志（ATTR_DIRECTORY）。
  static const int ATTR_DIRECTORY = 0x10;

  /// 存档属性标志（ATTR_ARCHIVE）。
  static const int ATTR_ARCHIVE = 0x20;

  // 扩展文件属性编码（其余基础属性位同上一致）。
  static const int ATTR_COMPRESSED = 0x800;
  static const int ATTR_NORMAL = 0x080;
  static const int ATTR_TEMPORARY = 0x100;

  // NT 文件访问权限位掩码常量编码。
  static const int FILE_READ_DATA = 0x00000001; // 1
  static const int FILE_WRITE_DATA = 0x00000002; // 2
  static const int FILE_APPEND_DATA = 0x00000004; // 3
  static const int FILE_READ_EA = 0x00000008; // 4
  static const int FILE_WRITE_EA = 0x00000010; // 5
  static const int FILE_EXECUTE = 0x00000020; // 6
  static const int FILE_DELETE = 0x00000040; // 7
  static const int FILE_READ_ATTRIBUTES = 0x00000080; // 8
  static const int FILE_WRITE_ATTRIBUTES = 0x00000100; // 9
  static const int DELETE = 0x00010000; // 16
  static const int READ_CONTROL = 0x00020000; // 17
  static const int WRITE_DAC = 0x00040000; // 18
  static const int WRITE_OWNER = 0x00080000; // 19
  static const int SYNCHRONIZE = 0x00100000; // 20
  static const int GENERIC_ALL = 0x10000000; // 28
  static const int GENERIC_EXECUTE = 0x20000000; // 29
  static const int GENERIC_WRITE = 0x40000000; // 30
  static const int GENERIC_READ = 0x80000000; // 31

  // 复制与重命名操作标志位掩码。
  static const int FLAGS_TARGET_MUST_BE_FILE = 0x0001;
  static const int FLAGS_TARGET_MUST_BE_DIRECTORY = 0x0002;
  static const int FLAGS_COPY_TARGET_MODE_ASCII = 0x0004;
  static const int FLAGS_COPY_SOURCE_MODE_ASCII = 0x0008;
  static const int FLAGS_VERIFY_ALL_WRITES = 0x0010;
  static const int FLAGS_TREE_COPY = 0x0020;

  // SMB1 OpenFunction 打开创建动作掩码。
  static const int OPEN_FUNCTION_FAIL_IF_EXISTS = 0x0000;
  static const int OPEN_FUNCTION_OVERWRITE_IF_EXISTS = 0x0020;

  static const int SECURITY_SHARE = 0x00;
  static const int SECURITY_USER = 0x01;

  static const int CMD_OFFSET = 4;
  static const int ERROR_CODE_OFFSET = 5;
  static const int FLAGS_OFFSET = 9;
  static const int SIGNATURE_OFFSET = 14;
  static const int TID_OFFSET = 24;
  static const int SMB1_HEADER_LENGTH = 32;

  static const int MILLISECONDS_BETWEEN_1970_AND_1601 = 11644473600000;

  static final CharEncoding DEFAULT_OEM_ENCODING = cp850; // "Cp850";

  static const int FOREVER = -1;

  /// 共享控制参数：禁止其他客户端并发打开或访问目标文件。
  static const int FILE_NO_SHARE = 0x00;

  /// 共享控制参数：禁止其他客户端并发打开或访问目标文件。
  /// 允许其他 SMB 客户端在本端持有句柄期间并发只读访问（可与其他共享位按位或组合）。
  static const int FILE_SHARE_READ = 0x01;

  /// 共享控制参数：禁止其他客户端并发打开或访问目标文件。
  /// 允许其他 SMB 客户端并发写入同一打开目标文件。
  static const int FILE_SHARE_WRITE = 0x02;

  /// 共享控制参数：禁止其他客户端并发打开或访问目标文件。
  /// 允许其他 SMB 客户端并发删除或重命名同一打开目标文件。
  static const int FILE_SHARE_DELETE = 0x04;

  /// 默认共享访问模式（允许并发读写与删除，即 `FILE_SHARE_READ | WRITE | DELETE`）。
  static const int DEFAULT_SHARING =
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE;

  /// 资源节点类型：常规文件系统文件或子目录。
  static const int TYPE_FILESYSTEM = 0x01;

  /// 资源节点类型：NetBIOS 域或工作组。
  static const int TYPE_WORKGROUP = 0x02;

  /// 资源节点类型：SMB 文件服务器主机节点。
  static const int TYPE_SERVER = 0x04;

  /// 资源节点类型：文件共享根目录。
  static const int TYPE_SHARE = 0x08;

  /// 资源节点类型：IPC 命名管道端点。
  static const int TYPE_NAMED_PIPE = 0x10;

  /// 资源节点类型：网络共享打印机资源。
  static const int TYPE_PRINTER = 0x20;

  /// 资源节点类型：网络串口/通信设备资源。
  static const int TYPE_COMM = 0x40;

  /* 文件打开控制及处置方式标志常量 */

  static const int O_RDONLY = 0x01;
  static const int O_WRONLY = 0x02;
  static const int O_RDWR = 0x03;
  static const int O_APPEND = 0x04;

  // SMB 打开行为动作掩码定义。
  // 文件不存在时自动新建文件。
  static const int O_CREAT = 0x0010;
  // 若文件已存在则令打开操作失败。
  static const int O_EXCL = 0x0020;
  // 若文件已存在则将其内容清空截断。
  static const int O_TRUNC = 0x0040;
}
