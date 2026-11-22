#include "windows_file_picker_bridge.h"

#include <shobjidl.h>
#include <wrl/client.h>

#include <algorithm>
#include <utility>

namespace {

constexpr char kChannelName[] = "konata/win_file_picker";

std::wstring Utf8ToWide(const std::string& utf8) {
  if (utf8.empty()) {
    return std::wstring();
  }
  const int needed = MultiByteToWideChar(
      CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()), nullptr, 0);
  if (needed <= 0) {
    return std::wstring();
  }
  std::wstring out(static_cast<size_t>(needed), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()),
                      out.data(), needed);
  return out;
}

std::string WideToUtf8(const wchar_t* wide) {
  if (wide == nullptr || *wide == L'\0') {
    return std::string();
  }
  const int needed = WideCharToMultiByte(CP_UTF8, 0, wide, -1, nullptr, 0,
                                         nullptr, nullptr);
  if (needed <= 1) {
    return std::string();
  }
  std::string out(static_cast<size_t>(needed - 1), '\0');
  WideCharToMultiByte(CP_UTF8, 0, wide, -1, out.data(), needed - 1, nullptr,
                      nullptr);
  return out;
}

std::string ReadStringArg(const flutter::EncodableMap& args, const char* key) {
  const auto it = args.find(flutter::EncodableValue(key));
  if (it == args.end()) {
    return std::string();
  }
  if (const auto* s = std::get_if<std::string>(&it->second)) {
    return *s;
  }
  return std::string();
}

bool ReadBoolArg(const flutter::EncodableMap& args,
                 const char* key,
                 bool fallback) {
  const auto it = args.find(flutter::EncodableValue(key));
  if (it == args.end()) {
    return fallback;
  }
  if (const auto* b = std::get_if<bool>(&it->second)) {
    return *b;
  }
  return fallback;
}

std::vector<std::string> ReadStringListArg(const flutter::EncodableMap& args,
                                           const char* key) {
  std::vector<std::string> out;
  const auto it = args.find(flutter::EncodableValue(key));
  if (it == args.end()) {
    return out;
  }
  const auto* list = std::get_if<flutter::EncodableList>(&it->second);
  if (list == nullptr) {
    return out;
  }
  for (const auto& item : *list) {
    if (const auto* s = std::get_if<std::string>(&item)) {
      std::string ext = *s;
      while (!ext.empty() && ext.front() == '.') {
        ext.erase(ext.begin());
      }
      if (!ext.empty()) {
        out.push_back(std::move(ext));
      }
    }
  }
  return out;
}

void ApplyInitialDirectory(IFileDialog* dialog, const std::string& dir_utf8) {
  if (dialog == nullptr || dir_utf8.empty()) {
    return;
  }
  const std::wstring wide_dir = Utf8ToWide(dir_utf8);
  if (wide_dir.empty()) {
    return;
  }
  Microsoft::WRL::ComPtr<IShellItem> folder;
  if (SUCCEEDED(SHCreateItemFromParsingName(wide_dir.c_str(), nullptr,
                                            IID_PPV_ARGS(&folder))) &&
      folder) {
    dialog->SetFolder(folder.Get());
  }
}

void ApplyFileTypeFilters(IFileDialog* dialog,
                          const std::vector<std::string>& extensions) {
  if (dialog == nullptr) {
    return;
  }
  if (extensions.empty()) {
    const COMDLG_FILTERSPEC spec = {L"所有文件 (*.*)", L"*.*"};
    dialog->SetFileTypes(1, &spec);
    return;
  }
  std::wstring pattern;
  std::wstring display = L"支持的文件 (";
  for (size_t i = 0; i < extensions.size(); ++i) {
    const std::wstring ext_w = Utf8ToWide(extensions[i]);
    if (ext_w.empty()) {
      continue;
    }
    if (!pattern.empty()) {
      pattern += L";";
      display += L", ";
    }
    pattern += L"*." + ext_w;
    display += L"*." + ext_w;
  }
  display += L")";
  if (pattern.empty()) {
    const COMDLG_FILTERSPEC spec = {L"所有文件 (*.*)", L"*.*"};
    dialog->SetFileTypes(1, &spec);
    return;
  }
  const COMDLG_FILTERSPEC specs[2] = {
      {display.c_str(), pattern.c_str()},
      {L"所有文件 (*.*)", L"*.*"},
  };
  dialog->SetFileTypes(2, specs);
  dialog->SetFileTypeIndex(1);
}

std::string ReadShellItemPath(IShellItem* item) {
  if (item == nullptr) {
    return std::string();
  }
  PWSTR raw_path = nullptr;
  if (FAILED(item->GetDisplayName(SIGDN_FILESYSPATH, &raw_path)) ||
      raw_path == nullptr) {
    return std::string();
  }
  std::string utf8 = WideToUtf8(raw_path);
  CoTaskMemFree(raw_path);
  return utf8;
}

}  // 匿名命名空间

WindowsFilePickerBridge::WindowsFilePickerBridge(
    HWND window_handle,
    flutter::PluginRegistrarWindows* registrar)
    : window_handle_(window_handle) {
  if (registrar == nullptr) {
    return;
  }
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      registrar->messenger(), kChannelName,
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](
          const flutter::MethodCall<flutter::EncodableValue>& call,
          std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
              result) { HandleMethodCall(call, std::move(result)); });
}

WindowsFilePickerBridge::~WindowsFilePickerBridge() { Shutdown(); }

void WindowsFilePickerBridge::Shutdown() {
  if (shutdown_called_) {
    return;
  }
  shutdown_called_ = true;
  if (pending_request_ && pending_request_->result) {
    if (pending_request_->kind == RequestKind::kPickFiles) {
      pending_request_->result->Success(
          flutter::EncodableValue(flutter::EncodableList{}));
    } else {
      pending_request_->result->Success();
    }
  }
  pending_request_.reset();
  if (channel_) {
    channel_->SetMethodCallHandler(nullptr);
    channel_.reset();
  }
}

void WindowsFilePickerBridge::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  RequestKind kind;
  if (call.method_name() == "pickFiles") {
    kind = RequestKind::kPickFiles;
  } else if (call.method_name() == "pickDirectory") {
    kind = RequestKind::kPickDirectory;
  } else if (call.method_name() == "saveFile") {
    kind = RequestKind::kSaveFile;
  } else {
    result->NotImplemented();
    return;
  }

  if (shutdown_called_ || dialog_active_ || pending_request_ != nullptr ||
      window_handle_ == nullptr || !IsWindow(window_handle_)) {
    if (kind == RequestKind::kPickFiles) {
      result->Success(flutter::EncodableValue(flutter::EncodableList{}));
    } else {
      result->Success();
    }
    return;
  }

  auto req = std::make_unique<PendingRequest>();
  req->kind = kind;
  req->result = std::move(result);
  if (const auto* args = std::get_if<flutter::EncodableMap>(call.arguments())) {
    req->dialog_title = ReadStringArg(*args, "dialogTitle");
    req->initial_directory = ReadStringArg(*args, "initialDirectory");
    req->default_file_name = ReadStringArg(*args, "fileName");
    req->accept_label = ReadStringArg(*args, "acceptLabel");
    req->allow_multiple = ReadBoolArg(*args, "allowMultiple", true);
    req->allowed_extensions = ReadStringListArg(*args, "allowedExtensions");
  }

  dialog_active_ = true;
  pending_request_ = std::move(req);
  if (!PostMessageW(window_handle_, kShowDialogWindowMessage, 0, 0)) {
    auto failed = std::move(pending_request_);
    dialog_active_ = false;
    if (failed && failed->result) {
      failed->result->Error("POST_MESSAGE_FAILED", "无法向主窗口投递文件选择消息");
    }
  }
}

void WindowsFilePickerBridge::ProcessPendingDialog() {
  if (shutdown_called_ || !pending_request_) {
    return;
  }
  std::unique_ptr<PendingRequest> req = std::move(pending_request_);
  switch (req->kind) {
    case RequestKind::kPickFiles:
      ExecutePickFiles(*req);
      break;
    case RequestKind::kPickDirectory:
      ExecutePickDirectory(*req);
      break;
    case RequestKind::kSaveFile:
      ExecuteSaveFile(*req);
      break;
  }
  dialog_active_ = false;
}

void WindowsFilePickerBridge::ExecutePickFiles(const PendingRequest& req) {
  Microsoft::WRL::ComPtr<IFileOpenDialog> dialog;
  HRESULT hr = CoCreateInstance(CLSID_FileOpenDialog, nullptr,
                                CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&dialog));
  if (FAILED(hr) || !dialog) {
    req.result->Error("COM_INIT_FAILED", "无法创建系统文件选择对话框");
    return;
  }

  FILEOPENDIALOGOPTIONS options = 0;
  if (SUCCEEDED(dialog->GetOptions(&options))) {
    options |= FOS_FORCEFILESYSTEM | FOS_FILEMUSTEXIST | FOS_NOCHANGEDIR;
    if (req.allow_multiple) {
      options |= FOS_ALLOWMULTISELECT;
    }
    dialog->SetOptions(options);
  }
  if (!req.dialog_title.empty()) {
    const std::wstring title = Utf8ToWide(req.dialog_title);
    dialog->SetTitle(title.c_str());
  }
  if (!req.accept_label.empty()) {
    const std::wstring ok_label = Utf8ToWide(req.accept_label);
    dialog->SetOkButtonLabel(ok_label.c_str());
  }
  ApplyFileTypeFilters(dialog.Get(), req.allowed_extensions);
  ApplyInitialDirectory(dialog.Get(), req.initial_directory);

  hr = dialog->Show(window_handle_);
  if (shutdown_called_) {
    return;
  }
  if (hr == HRESULT_FROM_WIN32(ERROR_CANCELLED)) {
    req.result->Success(flutter::EncodableValue(flutter::EncodableList{}));
    return;
  }
  if (FAILED(hr)) {
    req.result->Error("DIALOG_FAILED", "系统文件选择对话框异常退出");
    return;
  }

  flutter::EncodableList paths;
  Microsoft::WRL::ComPtr<IShellItemArray> items;
  if (SUCCEEDED(dialog->GetResults(&items)) && items) {
    DWORD count = 0;
    if (SUCCEEDED(items->GetCount(&count))) {
      for (DWORD i = 0; i < count; ++i) {
        Microsoft::WRL::ComPtr<IShellItem> item;
        if (SUCCEEDED(items->GetItemAt(i, &item)) && item) {
          std::string path = ReadShellItemPath(item.Get());
          if (!path.empty()) {
            paths.emplace_back(std::move(path));
          }
        }
      }
    }
  }
  req.result->Success(flutter::EncodableValue(std::move(paths)));
}

void WindowsFilePickerBridge::ExecutePickDirectory(const PendingRequest& req) {
  Microsoft::WRL::ComPtr<IFileOpenDialog> dialog;
  HRESULT hr = CoCreateInstance(CLSID_FileOpenDialog, nullptr,
                                CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&dialog));
  if (FAILED(hr) || !dialog) {
    req.result->Error("COM_INIT_FAILED", "无法创建系统目录选择对话框");
    return;
  }

  FILEOPENDIALOGOPTIONS options = 0;
  if (SUCCEEDED(dialog->GetOptions(&options))) {
    options |= FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM | FOS_NOCHANGEDIR;
    dialog->SetOptions(options);
  }
  if (!req.dialog_title.empty()) {
    const std::wstring title = Utf8ToWide(req.dialog_title);
    dialog->SetTitle(title.c_str());
  }
  if (!req.accept_label.empty()) {
    const std::wstring ok_label = Utf8ToWide(req.accept_label);
    dialog->SetOkButtonLabel(ok_label.c_str());
  }
  ApplyInitialDirectory(dialog.Get(), req.initial_directory);

  hr = dialog->Show(window_handle_);
  if (shutdown_called_) {
    return;
  }
  if (hr == HRESULT_FROM_WIN32(ERROR_CANCELLED)) {
    req.result->Success();
    return;
  }
  if (FAILED(hr)) {
    req.result->Error("DIALOG_FAILED", "系统目录选择对话框异常退出");
    return;
  }

  Microsoft::WRL::ComPtr<IShellItem> item;
  if (SUCCEEDED(dialog->GetResult(&item)) && item) {
    std::string path = ReadShellItemPath(item.Get());
    if (!path.empty()) {
      req.result->Success(flutter::EncodableValue(std::move(path)));
      return;
    }
  }
  req.result->Success();
}

void WindowsFilePickerBridge::ExecuteSaveFile(const PendingRequest& req) {
  Microsoft::WRL::ComPtr<IFileSaveDialog> dialog;
  HRESULT hr = CoCreateInstance(CLSID_FileSaveDialog, nullptr,
                                CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&dialog));
  if (FAILED(hr) || !dialog) {
    req.result->Error("COM_INIT_FAILED", "无法创建系统文件保存对话框");
    return;
  }

  FILEOPENDIALOGOPTIONS options = 0;
  if (SUCCEEDED(dialog->GetOptions(&options))) {
    options |= FOS_FORCEFILESYSTEM | FOS_OVERWRITEPROMPT | FOS_NOCHANGEDIR;
    dialog->SetOptions(options);
  }
  if (!req.dialog_title.empty()) {
    const std::wstring title = Utf8ToWide(req.dialog_title);
    dialog->SetTitle(title.c_str());
  }
  if (!req.accept_label.empty()) {
    const std::wstring ok_label = Utf8ToWide(req.accept_label);
    dialog->SetOkButtonLabel(ok_label.c_str());
  }
  if (!req.default_file_name.empty()) {
    const std::wstring name_w = Utf8ToWide(req.default_file_name);
    dialog->SetFileName(name_w.c_str());
    const auto dot_pos = req.default_file_name.find_last_of('.');
    if (dot_pos != std::string::npos &&
        dot_pos + 1 < req.default_file_name.size()) {
      const std::wstring ext_w =
          Utf8ToWide(req.default_file_name.substr(dot_pos + 1));
      if (!ext_w.empty()) {
        dialog->SetDefaultExtension(ext_w.c_str());
      }
    }
  }
  ApplyFileTypeFilters(dialog.Get(), req.allowed_extensions);
  ApplyInitialDirectory(dialog.Get(), req.initial_directory);

  hr = dialog->Show(window_handle_);
  if (shutdown_called_) {
    return;
  }
  if (hr == HRESULT_FROM_WIN32(ERROR_CANCELLED)) {
    req.result->Success();
    return;
  }
  if (FAILED(hr)) {
    req.result->Error("DIALOG_FAILED", "系统保存文件对话框异常退出");
    return;
  }

  Microsoft::WRL::ComPtr<IShellItem> item;
  if (SUCCEEDED(dialog->GetResult(&item)) && item) {
    std::string path = ReadShellItemPath(item.Get());
    if (!path.empty()) {
      req.result->Success(flutter::EncodableValue(std::move(path)));
      return;
    }
  }
  req.result->Success();
}
