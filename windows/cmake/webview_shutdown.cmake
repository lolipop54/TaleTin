# The pinned WebView plugin keeps its compositor and dispatcher in DLL statics.
# Release these in the manager destructor, on their owning UI thread. Build a
# patched translation unit locally so other projects keep their pub cache intact.
set(webview_target flutter_inappwebview_windows_plugin)
get_target_property(webview_dir ${webview_target} SOURCE_DIR)
set(manager in_app_webview/in_app_webview_manager.cpp)
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${webview_dir}/${manager}")
file(READ "${webview_dir}/${manager}" webview_source)
string(REPLACE "windowWebViews.clear();" "windowWebViews.clear();
      compositor_ = nullptr;
      graphics_context_.reset();
      if (dispatcher_queue_controller_) {
        TaleTinShutdownDispatcher(dispatcher_queue_controller_);
        dispatcher_queue_controller_ = nullptr;
      }
      rohelper_.reset();" webview_source "${webview_source}")
set(webview_patched "${CMAKE_CURRENT_BINARY_DIR}/in_app_webview_manager.cpp")
set(webview_source "#include \"webview_dispatcher_shutdown.h\"\n${webview_source}")
if(EXISTS "${webview_patched}")
  file(READ "${webview_patched}" previous_webview_source)
endif()
if(NOT webview_source STREQUAL previous_webview_source)
  file(WRITE "${webview_patched}" "${webview_source}")
endif()
get_target_property(webview_sources ${webview_target} SOURCES)
list(REMOVE_ITEM webview_sources "${manager}")
set_property(TARGET ${webview_target} PROPERTY SOURCES "${webview_sources};${webview_patched}")
target_include_directories(${webview_target} PRIVATE "${webview_dir}/in_app_webview" "${CMAKE_CURRENT_LIST_DIR}")
target_link_libraries(${webview_target} PRIVATE windowsapp.lib)
