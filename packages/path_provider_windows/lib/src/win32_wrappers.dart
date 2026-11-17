// 遵循 Flutter 官方组件 BSD 开源许可协议（详见随包 LICENSE 文件）。

// 以下 FFI 类型与导出函数直接映射对应 Windows 系统 Win32 API 签名。
/* Win32 原生绑定命名遵循系统头文件规范，保留文档与常量命名豁免 */ // ignore_for_file: public_member_api_docs, constant_identifier_names

import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'guid.dart';

typedef BOOL = Int32;
typedef BYTE = Uint8;
typedef DWORD = Uint32;
typedef UINT = Uint32;
typedef HANDLE = IntPtr;
typedef HMODULE = HANDLE;
typedef HRESULT = Int32;
typedef LPCVOID = Pointer<NativeType>;
typedef LPCWSTR = Pointer<Utf16>;
typedef LPDWORD = Pointer<DWORD>;
typedef LPWSTR = Pointer<Utf16>;
typedef LPVOID = Pointer<NativeType>;
typedef PUINT = Pointer<UINT>;
typedef PWSTR = Pointer<Pointer<Utf16>>;
typedef WCHAR = Uint16;

const int NULL = 0;

// Windows 扩展路径最大字符长度常量定义。
const int MAX_PATH = 260;

// 常见 Win32 `HRESULT` 状态码常量。
/* Win32 C 接口参数沿用匈牙利命名 */ // ignore: non_constant_identifier_names
final int E_FAIL = 0x80004005.toSigned(32);
/* Win32 C 接口参数沿用匈牙利命名 */ // ignore: non_constant_identifier_names
final int E_INVALIDARG = 0x80070057.toSigned(32);

// 判断 Win32 `HRESULT` 是否失败的辅助宏等价函数。
/* Win32 C 接口参数沿用匈牙利命名 */ // ignore: non_constant_identifier_names
bool FAILED(int hr) => hr < 0;

// Win32 `KNOWN_FOLDER_FLAG` 已知目录查询标志位枚举。
const int KF_FLAG_DEFAULT = 0x00000000;

final DynamicLibrary _dllKernel32 = DynamicLibrary.open('kernel32.dll');
final DynamicLibrary _dllVersion = DynamicLibrary.open('version.dll');
final DynamicLibrary _dllShell32 = DynamicLibrary.open('shell32.dll');

// 绑定 Win32 `SHGetKnownFolderPath` 系统目录路径查询函数。
typedef _FFITypeSHGetKnownFolderPath = HRESULT Function(
    Pointer<GUID>, DWORD, HANDLE, PWSTR);
typedef FFITypeSHGetKnownFolderPathDart = int Function(
    Pointer<GUID>, int, int, Pointer<Pointer<Utf16>>);
/* Win32 C 接口参数沿用匈牙利命名 */ // ignore: non_constant_identifier_names
final FFITypeSHGetKnownFolderPathDart SHGetKnownFolderPath =
    _dllShell32.lookupFunction<_FFITypeSHGetKnownFolderPath,
        FFITypeSHGetKnownFolderPathDart>('SHGetKnownFolderPath');

// 绑定 Win32 `GetFileVersionInfoW` 文件版本信息读取函数。
typedef _FFITypeGetFileVersionInfoW = BOOL Function(
    LPCWSTR, DWORD, DWORD, LPVOID);
typedef FFITypeGetFileVersionInfoW = int Function(
    Pointer<Utf16>, int, int, Pointer<NativeType>);
/* Win32 C 接口参数沿用匈牙利命名 */ // ignore: non_constant_identifier_names
final FFITypeGetFileVersionInfoW GetFileVersionInfo = _dllVersion
    .lookupFunction<_FFITypeGetFileVersionInfoW, FFITypeGetFileVersionInfoW>(
        'GetFileVersionInfoW');

// 绑定 Win32 `GetFileVersionInfoSizeW` 版本信息缓冲区大小查询函数。
typedef _FFITypeGetFileVersionInfoSizeW = DWORD Function(LPCWSTR, LPDWORD);
typedef FFITypeGetFileVersionInfoSizeW = int Function(
    Pointer<Utf16>, Pointer<Uint32>);
/* Win32 C 接口参数沿用匈牙利命名 */ // ignore: non_constant_identifier_names
final FFITypeGetFileVersionInfoSizeW GetFileVersionInfoSize =
    _dllVersion.lookupFunction<_FFITypeGetFileVersionInfoSizeW,
        FFITypeGetFileVersionInfoSizeW>('GetFileVersionInfoSizeW');

// 绑定 Win32 `GetLastError` 线程末次错误码读取函数。
typedef _FFITypeGetLastError = DWORD Function();
typedef FFITypeGetLastError = int Function();
/* Win32 C 接口参数沿用匈牙利命名 */ // ignore: non_constant_identifier_names
final FFITypeGetLastError GetLastError = _dllKernel32
    .lookupFunction<_FFITypeGetLastError, FFITypeGetLastError>('GetLastError');

// 绑定 Win32 `GetModuleFileNameW` 当前模块完整路径读取函数。
typedef _FFITypeGetModuleFileNameW = DWORD Function(HMODULE, LPWSTR, DWORD);
typedef FFITypeGetModuleFileNameW = int Function(int, Pointer<Utf16>, int);
/* Win32 C 接口参数沿用匈牙利命名 */ // ignore: non_constant_identifier_names
final FFITypeGetModuleFileNameW GetModuleFileName = _dllKernel32.lookupFunction<
    _FFITypeGetModuleFileNameW,
    FFITypeGetModuleFileNameW>('GetModuleFileNameW');

// 绑定 Win32 `VerQueryValueW` 版本资源键值提取函数。
typedef _FFITypeVerQueryValueW = BOOL Function(LPCVOID, LPCWSTR, LPVOID, PUINT);
typedef FFITypeVerQueryValueW = int Function(
    Pointer<NativeType>, Pointer<Utf16>, Pointer<NativeType>, Pointer<Uint32>);
/* Win32 C 接口参数沿用匈牙利命名 */ // ignore: non_constant_identifier_names
final FFITypeVerQueryValueW VerQueryValue =
    _dllVersion.lookupFunction<_FFITypeVerQueryValueW, FFITypeVerQueryValueW>(
        'VerQueryValueW');

// 绑定 Win32 `GetTempPathW` 系统临时目录查询函数。
typedef _FFITypeGetTempPathW = DWORD Function(DWORD, LPWSTR);
typedef FFITypeGetTempPathW = int Function(int, Pointer<Utf16>);
/* Win32 C 接口参数沿用匈牙利命名 */ // ignore: non_constant_identifier_names
final FFITypeGetTempPathW GetTempPath = _dllKernel32
    .lookupFunction<_FFITypeGetTempPathW, FFITypeGetTempPathW>('GetTempPathW');
