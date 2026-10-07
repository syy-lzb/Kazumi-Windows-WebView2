import 'dart:async';
import 'dart:convert';

import 'package:webview_windows/webview_windows.dart';
import 'package:kazumi/webview/video/video_webview_controller.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/network/proxy_utils.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/video_source/video_source_format.dart';

class VideoWebviewWindowsImpl
    extends VideoWebviewController<WebviewController> {
  final List<StreamSubscription> subscriptions = [];

  HeadlessWebview? headlessWebview;
  Timer? _domFallbackTimer;
  bool _domProbeRunning = false;
  int _domProbeCount = 0;

  @override
  Future<void> init() async {
    await _setupProxy();
    headlessWebview ??= HeadlessWebview();
    await headlessWebview!.run();
    await headlessWebview!.setPopupWindowPolicy(WebviewPopupWindowPolicy.deny);
    initEventController.add(true);
  }

  Future<void> _setupProxy() async {
    final bool proxyEnable = GStorage.getSetting(SettingsKeys.proxyEnable);
    if (!proxyEnable) {
      return;
    }

    final String proxyUrl = GStorage.getSetting(SettingsKeys.proxyUrl);
    final formattedProxy = ProxyUtils.getFormattedProxyUrl(proxyUrl);
    if (formattedProxy == null) {
      return;
    }

    try {
      await WebviewController.initializeEnvironment(
        additionalArguments: '--proxy-server=$formattedProxy',
      );
      KazumiLogger().i('WebView: 代理设置成功 $formattedProxy');
    } catch (e) {
      KazumiLogger().e('WebView: 设置代理失败 $e');
    }
  }

  void _stopDomFallback() {
    _domFallbackTimer?.cancel();
    _domFallbackTimer = null;
    _domProbeCount = 0;
  }

  void _startDomFallback() {
    _stopDomFallback();

    // Some Windows WebView2 pages expose a usable <video>.currentSrc but do
    // not trigger webview_windows' native media-source callbacks. Probe the
    // DOM as a fallback while the normal native capture remains primary.
    unawaited(_probeDomMediaSource());

    _domFallbackTimer =
        Timer.periodic(const Duration(milliseconds: 750), (timer) {
      if (headlessWebview == null || isVideoSourceLoaded) {
        _stopDomFallback();
        return;
      }

      _domProbeCount++;
      if (_domProbeCount >= 20) {
        _stopDomFallback();
        return;
      }

      unawaited(_probeDomMediaSource());
    });
  }

  Future<void> _probeDomMediaSource() async {
    if (_domProbeRunning || isVideoSourceLoaded || headlessWebview == null) {
      return;
    }

    _domProbeRunning = true;
    try {
      final result = await headlessWebview!.executeScript(r'''
(() => {
  const videos = Array.from(document.querySelectorAll('video'));

  for (const video of videos) {
    const currentSrc = String(video.currentSrc || '');
    if (/^https?:\/\//i.test(currentSrc)) {
      return currentSrc;
    }

    const src = String(video.getAttribute('src') || video.src || '');
    if (/^https?:\/\//i.test(src)) {
      return src;
    }

    const source = video.querySelector('source[src]');
    if (source) {
      const sourceSrc = String(source.src || source.getAttribute('src') || '');
      if (/^https?:\/\//i.test(sourceSrc)) {
        return sourceSrc;
      }
    }
  }

  const source = document.querySelector('video source[src], source[src]');
  if (source) {
    const sourceSrc = String(source.src || source.getAttribute('src') || '');
    if (/^https?:\/\//i.test(sourceSrc)) {
      return sourceSrc;
    }
  }

  return '';
})()
''');

      if (isVideoSourceLoaded) {
        return;
      }

      String mediaUrl = result?.toString() ?? '';
      try {
        final decoded = jsonDecode(mediaUrl);
        if (decoded is String) {
          mediaUrl = decoded;
        }
      } catch (_) {
        // Some webview_windows versions already return the plain string.
      }

      mediaUrl = mediaUrl.trim();
      if (!(mediaUrl.startsWith('http://') ||
          mediaUrl.startsWith('https://'))) {
        return;
      }

      isIframeLoaded = true;
      isVideoSourceLoaded = true;
      videoLoadingEventController.add(false);
      _stopDomFallback();

      final format = mediaUrl.toLowerCase().contains('.m3u8')
          ? VideoSourceFormat.hls
          : VideoSourceFormat.auto;

      logEventController.add('Loading DOM video source: $mediaUrl');
      notifyVideoSourceResolved(mediaUrl, format: format);
      unawaited(unloadPage());
    } catch (_) {
      // DOM probing is only a fallback. Native media capture remains primary.
    } finally {
      _domProbeRunning = false;
    }
  }

  @override
  Future<void> loadUrl(
    String url,
    bool useLegacyParser, {
    int offset = 0,
  }) async {
    await unloadPage();
    count = 0;
    this.offset = offset;
    isIframeLoaded = false;
    isVideoSourceLoaded = false;
    videoLoadingEventController.add(true);

    subscriptions.add(headlessWebview!.onM3USourceLoaded.listen((data) {
      if (headlessWebview == null || isVideoSourceLoaded) return;

      final String mediaUrl = data['url'] ?? '';
      if (mediaUrl.isEmpty) return;

      isIframeLoaded = true;
      isVideoSourceLoaded = true;
      videoLoadingEventController.add(false);
      _stopDomFallback();

      logEventController.add('Loading m3u8 source: $mediaUrl');
      notifyVideoSourceResolved(
        mediaUrl,
        format: VideoSourceFormat.hls,
      );
      unawaited(unloadPage());
    }));

    subscriptions.add(headlessWebview!.onVideoSourceLoaded.listen((data) {
      if (headlessWebview == null || isVideoSourceLoaded) return;

      final String mediaUrl = data['url'] ?? '';
      if (mediaUrl.isEmpty) return;

      isIframeLoaded = true;
      isVideoSourceLoaded = true;
      videoLoadingEventController.add(false);
      _stopDomFallback();

      logEventController.add('Loading video source: $mediaUrl');
      notifyVideoSourceResolved(mediaUrl);
      unawaited(unloadPage());
    }));

    _startDomFallback();
    await headlessWebview!.loadUrl(url);
  }

  @override
  Future<void> unloadPage() async {
    _stopDomFallback();

    for (final s in subscriptions) {
      try {
        await s.cancel();
      } catch (_) {}
    }
    subscriptions.clear();

    await redirect2Blank();
  }

  @override
  Future<void> dispose() async {
    _stopDomFallback();

    for (final s in subscriptions) {
      try {
        await s.cancel();
      } catch (_) {}
    }
    subscriptions.clear();

    await headlessWebview?.dispose();
    headlessWebview = null;
    disposeEventControllers();
  }

  // The webview_windows package does not have a method to unload the current
  // page. Redirecting to about:blank lets the controller be reused between
  // episodes without recreating the WebView.
  Future<void> redirect2Blank() async {
    if (headlessWebview == null) return;

    try {
      await headlessWebview!.executeScript('''
        window.location.href = 'about:blank';
      ''');
    } catch (e) {
      KazumiLogger().d('WebView: redirect2Blank skipped (likely disposed): $e');
    }
  }
}
