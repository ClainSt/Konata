#ifndef RUNNER_UTILS_H_
#define RUNNER_UTILS_H_

#include <string>
#include <vector>

// 为当前进程附着或创建输出控制台，并重定位标准输出与标准错误流，
// 使宿主进程与 Flutter 引擎库日志均可实时输出。
void CreateAndAttachConsole();

// 将以空字符结尾的 UTF-16 宽字符串转换并返回对应的 UTF-8 标准字符串；
// 当获取参数失败时返回空列表，参数项编码无效则返回空字符串。
std::string Utf8FromUtf16(const wchar_t* utf16_string);

// 读取进程命令行参数并编码为 UTF-8 字符串数组；若获取失败则返回空列表或空字符串。
std::vector<std::string> GetCommandLineArguments();

#endif  // RUNNER_UTILS_H_
