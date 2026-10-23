package com.pichillilorenzo.flutter_inappwebview_android.types;

import android.webkit.WebResourceResponse;
import androidx.annotation.Nullable;

/** Optional host-owned local resource provider. Null retains the plugin's existing path. */
public final class LocalResourceInterceptor {
  public interface Handler {
    @Nullable WebResourceResponse intercept(Object viewId, WebResourceRequestExt request);
  }
  @Nullable public static volatile Handler handler;
  private LocalResourceInterceptor() {}
}
