import 'package:smb_connect/src/exceptions.dart';
import 'package:smb_connect/src/dcerpc/msrpc/lsarpc.dart';
import 'package:smb_connect/src/dcerpc/msrpc/netdfs.dart';
import 'package:smb_connect/src/dcerpc/msrpc/samr.dart';
import 'package:smb_connect/src/dcerpc/msrpc/srvsvc.dart';
import 'package:smb_connect/src/dcerpc/uuid.dart';
import 'package:smb_connect/src/utils/strings.dart';

class DcerpcBinding {
  static final Map<String, String> INTERFACES = {
    "srvsvc": srvsvcGetSyntax(),
    "lsarpc": lsarpcGetSyntax(),
    "samr": samrGetSyntax(),
    "netdfs": netdfsGetSyntax(),
    "netlogon": "12345678-1234-abcd-ef00-01234567cffb:1.0",
    "wkssvc": "6BFFD098-A112-3610-9833-46C3F87E345A:1.0",
  };

  String? proto;
  Map<String, Object>? _options;
  String server;
  String? endpoint;
  UUID? uuid;
  int _major = 0;
  int _minor = 0;

  DcerpcBinding(this.proto, this.server);

  String? getEndpoint() {
    return endpoint;
  }

  UUID? getUuid() {
    return uuid;
  }

  int getMajor() {
    return _major;
  }

  int getMinor() {
    return _minor;
  }

  void setOption(String key, Object val) {
    if (key == "endpoint") {
      endpoint = val.toString();
      String lep = endpoint!.toLowerCase();
      if (lep.startsWith("\\pipe\\")) {
        String? iface = INTERFACES[lep.substring(6)];
        if (iface != null) {
          int c, p;
          c = iface.indexOf(':');
          p = iface.indexOf('.', c + 1);
          uuid = UUID.str(iface.substring(0, c));
          _major = int.parse(iface.substring(c + 1, p));
          _minor = int.parse(iface.substring(p + 1));
          return;
        }
      }
      throw DcerpcException("Bad endpoint: $endpoint");
    }
    _options ??= {};
    _options![key] = val;
  }

  Object? getOption(String key) {
    if (key == "endpoint") {
      return endpoint;
    }
    return _options?[key];
  }

  @override
  String toString() {
    String ret = "$proto:$server[$endpoint";
    _options?.entries.forEach((entry) {
      ret += ",${entry.key}=${entry.value}";
    });
    ret += "]";
    return ret;
  }

  ///
  /// 解析 DCERPC 端点绑定字符串（如 `ncacn_np:\\server[endpoint=\pipe\srvsvc]`，缺失主机默认 `127.0.0.1`）。
  /// or
  /// or
  ///
  ///
  ///
  static DcerpcBinding parse(String str) {
    int state, mark, si;
    var arr = str.toChars();
    String? proto, key;
    DcerpcBinding? binding;

    state = mark = si = 0;
    do {
      var ch = arr[si];

      switch (state) {
        case 0:
          if (ch == ':') {
            proto = str.substring(mark, si);
            mark = si + 1;
            state = 1;
          }
          break;
        case 1:
          if (ch == '\\') {
            mark = si + 1;
            break;
          }
          state = 2;
        case 2:
          if (ch == '[') {
            String server = str.substring(mark, si).trim();
            if (server.isEmpty) {
              // 此处也可能是带方括号包裹的 IPv6 地址，须前瞻分隔符识别。
              int nexts = str.indexOf('[', si + 1);
              int nexte = str.indexOf(']', si);
              if (nexts >= 0 && nexte >= 0 && nexte == nexts - 1) {
                server = str.substring(si, nexte + 1);
                si = nexts;
              } else {
                server = "127.0.0.1";
              }
            }
            binding = DcerpcBinding(proto, server);
            mark = si + 1;
            state = 5;
          }
          break;
        case 5:
          if (ch == '=') {
            key = str.substring(mark, si).trim();
            mark = si + 1;
          } else if (ch == ',' || ch == ']') {
            String val = str.substring(mark, si).trim();
            mark = si + 1;
            key ??= "endpoint";
            if (binding != null) {
              binding.setOption(key, val);
            }
            key = null;
          }
          break;
        default:
          si = arr.length;
      }

      si++;
    } while (si < arr.length);

    if (binding == null || binding.getEndpoint() == null) {
      throw "Invalid binding URL: $str";
    }

    return binding;
  }
}
