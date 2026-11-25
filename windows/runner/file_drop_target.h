#ifndef RUNNER_FILE_DROP_TARGET_H_
#define RUNNER_FILE_DROP_TARGET_H_

#include <windows.h>
#include <oleidl.h>

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

// Accepts Explorer files only within the bounds published by the Flutter shelf.
class FileDropTarget final : public IDropTarget {
 public:
  static FileDropTarget* Register(HWND window, flutter::BinaryMessenger* messenger);
  void Detach();

  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** object) override;
  ULONG STDMETHODCALLTYPE AddRef() override;
  ULONG STDMETHODCALLTYPE Release() override;
  HRESULT STDMETHODCALLTYPE DragEnter(IDataObject* data, DWORD keys, POINTL point, DWORD* effect) override;
  HRESULT STDMETHODCALLTYPE DragOver(DWORD keys, POINTL point, DWORD* effect) override;
  HRESULT STDMETHODCALLTYPE DragLeave() override;
  HRESULT STDMETHODCALLTYPE Drop(IDataObject* data, DWORD keys, POINTL point, DWORD* effect) override;

 private:
  FileDropTarget(HWND window, flutter::BinaryMessenger* messenger);
  ~FileDropTarget() = default;

  bool CanDrop(POINTL point, DWORD effect) const;
  void SetHover(bool hover);

  ULONG references_ = 1;
  HWND window_;
  RECT bounds_{};
  bool has_files_ = false;
  bool hovering_ = false;
  flutter::MethodChannel<flutter::EncodableValue> channel_;
};

#endif  // RUNNER_FILE_DROP_TARGET_H_
