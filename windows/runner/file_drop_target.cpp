#include "file_drop_target.h"

#include <ole2.h>
#include <shellapi.h>

#include <memory>
#include <string>
#include <utility>

#include "utils.h"

namespace {
FORMATETC FileFormat() {
  return {CF_HDROP, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
}
}  // namespace

FileDropTarget::FileDropTarget(HWND window, flutter::BinaryMessenger* messenger)
    : window_(window),
      channel_(messenger, "taletin/windows_file_drop",
               &flutter::StandardMethodCodec::GetInstance()) {}

FileDropTarget* FileDropTarget::Register(HWND window,
                                         flutter::BinaryMessenger* messenger) {
  if (FAILED(OleInitialize(nullptr))) return nullptr;
  auto* target = new FileDropTarget(window, messenger);
  if (FAILED(RegisterDragDrop(window, target))) {
    target->Release();
    OleUninitialize();
    return nullptr;
  }
  target->channel_.SetMethodCallHandler([target](const auto& call, auto result) {
    if (call.method_name() != "setBounds") {
      result->NotImplemented();
      return;
    }
    target->bounds_ = {};
    auto values = std::get_if<flutter::EncodableList>(call.arguments());
    if (values && values->size() == 4) {
      auto left = std::get_if<double>(&(*values)[0]);
      auto top = std::get_if<double>(&(*values)[1]);
      auto right = std::get_if<double>(&(*values)[2]);
      auto bottom = std::get_if<double>(&(*values)[3]);
      if (left && top && right && bottom) {
        target->bounds_ = {static_cast<LONG>(*left), static_cast<LONG>(*top),
                           static_cast<LONG>(*right), static_cast<LONG>(*bottom)};
      }
    }
    if (IsRectEmpty(&target->bounds_)) target->SetHover(false);
    result->Success();
  });
  return target;
}

void FileDropTarget::Detach() {
  channel_.SetMethodCallHandler(nullptr);
  RevokeDragDrop(window_);
  OleUninitialize();
  Release();
}

HRESULT FileDropTarget::QueryInterface(REFIID iid, void** object) {
  if (!object) return E_POINTER;
  *object = nullptr;
  if (iid != IID_IUnknown && iid != IID_IDropTarget) return E_NOINTERFACE;
  *object = static_cast<IDropTarget*>(this);
  AddRef();
  return S_OK;
}

ULONG FileDropTarget::AddRef() { return ++references_; }

ULONG FileDropTarget::Release() {
  const auto remaining = --references_;
  if (!remaining) delete this;
  return remaining;
}

bool FileDropTarget::CanDrop(POINTL point, DWORD effect) const {
  POINT client{point.x, point.y};
  return has_files_ && (effect & DROPEFFECT_COPY) &&
         ScreenToClient(window_, &client) && PtInRect(&bounds_, client);
}

void FileDropTarget::SetHover(bool hover) {
  if (hovering_ == hover) return;
  hovering_ = hover;
  channel_.InvokeMethod("hover", std::make_unique<flutter::EncodableValue>(hover));
}

HRESULT FileDropTarget::DragEnter(IDataObject* data, DWORD keys, POINTL point,
                                  DWORD* effect) {
  auto format = FileFormat();
  has_files_ = data->QueryGetData(&format) == S_OK;
  return DragOver(keys, point, effect);
}

HRESULT FileDropTarget::DragOver(DWORD /*keys*/, POINTL point, DWORD* effect) {
  const bool accept = CanDrop(point, *effect);
  *effect = accept ? DROPEFFECT_COPY : DROPEFFECT_NONE;
  SetHover(accept);
  return S_OK;
}

HRESULT FileDropTarget::DragLeave() {
  has_files_ = false;
  SetHover(false);
  return S_OK;
}

HRESULT FileDropTarget::Drop(IDataObject* data, DWORD /*keys*/, POINTL point,
                             DWORD* effect) {
  const bool accept = CanDrop(point, *effect);
  DragLeave();
  *effect = DROPEFFECT_NONE;
  if (!accept) return S_OK;

  auto format = FileFormat();
  STGMEDIUM medium{};
  if (FAILED(data->GetData(&format, &medium))) return S_OK;
  const auto drop = reinterpret_cast<HDROP>(medium.hGlobal);
  const auto count = DragQueryFileW(drop, 0xFFFFFFFF, nullptr, 0);
  flutter::EncodableList paths;
  paths.reserve(count);
  // Query each path length first so Unicode names and paths beyond MAX_PATH fit.
  for (UINT i = 0; i < count; ++i) {
    const auto size = DragQueryFileW(drop, i, nullptr, 0) + 1;
    std::wstring path(size, L'\0');
    if (DragQueryFileW(drop, i, path.data(), size)) {
      paths.emplace_back(Utf8FromUtf16(path.c_str()));
    }
  }
  ReleaseStgMedium(&medium);
  if (!paths.empty()) {
    channel_.InvokeMethod("drop", std::make_unique<flutter::EncodableValue>(std::move(paths)));
    *effect = DROPEFFECT_COPY;
  }
  return S_OK;
}
