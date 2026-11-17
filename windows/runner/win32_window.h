#ifndef RUNNER_WIN32_WINDOW_H_
#define RUNNER_WIN32_WINDOW_H_

#include <windows.h>

#include <functional>
#include <memory>
#include <string>

// 支持高 DPI 缩放感知的原生 Win32 窗口封装基类；
// 供上层子类继承并扩展自定义渲染表面与输入消息处理逻辑。
// 提供基础窗口创建、销毁及消息泵路由能力。
class Win32Window {
 public:
  struct Point {
    unsigned int x;
    unsigned int y;
    Point(unsigned int x, unsigned int y) : x(x), y(y) {}
  };

  struct Size {
    unsigned int width;
    unsigned int height;
    Size(unsigned int width, unsigned int height)
        : width(width), height(height) {}
  };

  Win32Window();
  virtual ~Win32Window();

  // 按给定逻辑起点与尺寸创建并定位 Win32 窗口；
  // 系统侧创建尺寸以物理像素计量，故本函数会依据主显示器缩放倍数换算传入值；
  // 创建后窗口默认处于隐藏状态，直至显式调用显示方法；
  // 保证不同缩放倍率的显示器均可按预期的视觉尺寸创建窗口，
  // 返回值指示原生窗口句柄是否创建成功。
  // 创建成功返回真值，失败返回假。
  bool Create(const std::wstring& title, const Point& origin, const Size& size);

  // 显式展示当前窗口，成功显示时返回真值。
  bool Show();

  // 释放与该窗口绑定的系统内核句柄与相关资源。
  void Destroy();

  // 将外部子窗口内容句柄嵌入挂载至当前宿主窗口节点下。
  void SetChildContent(HWND content);

  // 返回底层原生窗口句柄供调用方设置图标及扩展属性；若已销毁则返回空指针。
  // 失效句柄统一返回 `nullptr` 避免误操作。
  HWND GetHandle();

  // 配置关闭该窗口时是否同步触发退出整个应用程序消息循环。
  void SetQuitOnClose(bool quit_on_close);

  // 返回表示当前窗口客户区物理像素边界的 RECT 结构。
  RECT GetClientArea();

 protected:
  // 拦截并分发尺寸变更、鼠标事件与 DPI 缩放变更等关键窗口消息，
  // 交由派生类通过对应虚拟保护方法完成自定义行为响应。
  // 集中调度窗口生命周期与视觉交互消息。
  virtual LRESULT MessageHandler(HWND window,
                                 UINT const message,
                                 WPARAM const wparam,
                                 LPARAM const lparam) noexcept;

  // 窗口创建并准备展示时回调，供子类完成视口宿主或渲染引擎初始化；
  // 若子类初始化失败须返回假值以中止展示流程。
  virtual bool OnCreate();

  // 窗口进入销毁阶段时的资源释放回调钩子。
  virtual void OnDestroy();

 private:
  friend class WindowClassRegistrar;

  // 系统消息泵静态回调入口：重点拦截 `WM_NCCREATE` 以启用非客户区
  // 自动 DPI 缩放适配，其余消息统一转发给实例级消息处理器。
  // 保证窗口标题栏与边框随显示器 DPI 变化自动按比例重绘。
  // 除创建前消息外的其余消息皆经实例路由分发，
  // 保障面向对象的窗口消息回调结构。
  static LRESULT CALLBACK WndProc(HWND const window,
                                  UINT const message,
                                  WPARAM const wparam,
                                  LPARAM const lparam) noexcept;

  // 通过原生窗口句柄扩展存储位取回对应的 C++ 类实例指针。
  static Win32Window* GetThisFromHandle(HWND const window) noexcept;

  // 根据当前系统深浅色配置即时刷新窗口非客户区框架外观属性。
  static void UpdateTheme(HWND const window);

  bool quit_on_close_ = false;

  // 顶级宿主窗口的系统原生句柄。
  HWND window_handle_ = nullptr;

  // 嵌入托管的子内容视图原生句柄。
  HWND child_content_ = nullptr;
};

#endif  // RUNNER_WIN32_WINDOW_H_
