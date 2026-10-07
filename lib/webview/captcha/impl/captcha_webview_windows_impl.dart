import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:webview_windows/webview_windows.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/network/proxy_utils.dart';
import 'package:kazumi/webview/captcha/captcha_webview_controller.dart';

class CaptchaWebviewWindowsImpl
    extends CaptchaWebviewController<WebviewController> {
  final List<StreamSubscription> _subscriptions = [];
  String _currentCaptchaImageXpath = '';
  String _currentInputXpath = '';
  String _currentPageUrl = '';
  String _buttonXpath = '';
  String? _customScript;
  int _customScriptGeneration = 0;

  /// 使用可见的 [WebviewController] 而非 HeadlessWebview，以便在对话框中
  /// 嵌入真正可点击/滚动的 WebView2（Cloudflare 等人工验证）。
  /// Cookie/UA/HTML 仍从同一实例收割。
  WebviewController? get _wv => webviewController;

  @override
  Future<void> init() async {
    await _setupProxy();
    final controller = WebviewController();
    // 先挂到 webviewController，保证 init 失败时 dispose 仍可释放。
    webviewController = controller;
    await controller.initialize();
    await controller.setPopupWindowPolicy(WebviewPopupWindowPolicy.deny);

    // Listen for messages from JavaScript via window.chrome.webview.postMessage
    _subscriptions.add(controller.webMessage.listen(_onWebMessage));

    // Custom-script rules should not have to wait for every image/ad/analytics
    // request before they can inspect the DOM. Schedule an early injection on
    // every navigation-state change; the JS-side guard prevents duplicates in
    // the same document. A redirect creates a new document and is injected
    // again automatically.
    _subscriptions.add(
      controller.loadingState.listen((state) async {
        final customScript = _customScript;
        if (customScript != null) {
          unawaited(
            _injectCustomScriptWhenReady(customScript, _customScriptGeneration),
          );
        }

        if (state == LoadingState.navigationCompleted) {
          logEventController.add(
            '[Captcha WebView] Navigation completed: $_currentPageUrl',
          );
          if (_currentCaptchaImageXpath.isNotEmpty) {
            await _injectCaptchaScript();
          } else if (_buttonXpath.isNotEmpty) {
            await _injectButtonClickScript(_buttonXpath);
          }
        }
      }),
    );

    // After a navigation, detect verification completion for captcha-image
    // and automated flows that marked a verification action as clicked.
    _subscriptions.add(
      controller.loadingState.listen((state) async {
        if (state == LoadingState.navigationCompleted) {
          if (captchaWasFound) {
            final present = await _isCaptchaPresent();
            if (!present && !captchaDisappearedController.isClosed) {
              logEventController.add(
                '[Captcha WebView] Captcha gone after navigation',
              );
              captchaWasFound = false;
              captchaDisappearedController.add(null);
            }
          }
          if (buttonWasClicked && !captchaDisappearedController.isClosed) {
            logEventController.add(
              '[Captcha WebView] Button click → page navigated, verification done',
            );
            buttonWasClicked = false;
            captchaDisappearedController.add(null);
          }
        }
      }),
    );

    initEventController.add(true);
  }

  @override
  Widget? buildVerificationView() {
    final controller = _wv;
    if (controller == null) return null;
    return ValueListenableBuilder<WebviewValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        if (!value.isInitialized) {
          return const Center(child: Text('正在准备验证页面…'));
        }
        return Webview(controller);
      },
    );
  }

  void _onWebMessage(dynamic message) {
    final msg = message.toString();
    logEventController.add('[Captcha WebView] WM: $msg');
    if (msg.startsWith('captchaImage:')) {
      final src = msg.replaceFirst('captchaImage:', '');
      if (src.isNotEmpty && !captchaImageFoundController.isClosed) {
        captchaWasFound = true;
        captchaImageFoundController.add(src);
      }
    } else if (msg.startsWith('buttonClicked:')) {
      buttonWasClicked = true;
      logEventController.add('[Captcha WebView] Button clicked flag set');
    } else if (msg.startsWith('captchaGone:')) {
      buttonWasClicked = false;
      if (!captchaDisappearedController.isClosed) {
        captchaDisappearedController.add(null);
      }
    } else if (msg.startsWith('captchaLog:')) {
      logEventController.add(
        '[Captcha WebView JS] ${msg.replaceFirst('captchaLog:', '')}',
      );
    }
  }

  Future<bool> _isCaptchaPresent() async {
    if (_currentCaptchaImageXpath.isEmpty || _wv == null) {
      return false;
    }
    final escaped = _currentCaptchaImageXpath
        .replaceAll('\\', '\\\\')
        .replaceAll("'", "\\'");
    try {
      final result = await _wv!.executeScript('''
(function() {
  try {
    var r = document.evaluate('$escaped', document, null,
      XPathResult.FIRST_ORDERED_NODE_TYPE, null);
    return r.singleNodeValue ? 'present' : 'absent';
  } catch(e) { return 'absent'; }
})();
''');
      return result?.toString().contains('present') ?? false;
    } catch (e) {
      KazumiLogger().d('[Captcha WebView] _isCaptchaPresent error: $e');
      return false;
    }
  }

  Future<void> _injectCaptchaScript() async {
    if (_currentCaptchaImageXpath.isEmpty) return;
    final escapedXpath = _currentCaptchaImageXpath
        .replaceAll('\\', '\\\\')
        .replaceAll("'", "\\'");
    final escapedInputXpath = _currentInputXpath
        .replaceAll('\\', '\\\\')
        .replaceAll("'", "\\'");

    final script =
        '''
(function() {
  window.chrome.webview.postMessage('captchaLog:CaptchaScript injected on ' + window.location.href);

  var _captchaXpath = '$escapedXpath';
  var _inputXpath = '$escapedInputXpath';
  var _captchaPoller = null;
  var _disappearObserver = null;

  function _evalXpath() {
    try {
      var result = document.evaluate(
        _captchaXpath, document, null,
        XPathResult.FIRST_ORDERED_NODE_TYPE, null);
      return result.singleNodeValue;
    } catch(e) { return null; }
  }

  function _startDisappearMonitor() {
    if (_disappearObserver) return;
    _disappearObserver = new MutationObserver(function() {
      if (!_evalXpath()) {
        _disappearObserver.disconnect();
        _disappearObserver = null;
        window.chrome.webview.postMessage('captchaGone:');
      }
    });
    _disappearObserver.observe(document.documentElement,
      { childList: true, subtree: true, attributes: true });
  }

  function _captureAsBase64(imgNode, callback) {
    function doCapture() {
      try {
        var canvas = document.createElement('canvas');
        canvas.width = imgNode.naturalWidth || imgNode.width || 100;
        canvas.height = imgNode.naturalHeight || imgNode.height || 40;
        var ctx = canvas.getContext('2d');
        ctx.drawImage(imgNode, 0, 0);
        callback(canvas.toDataURL('image/png'));
      } catch(e) { callback(null); }
    }
    if (imgNode.complete && imgNode.naturalWidth > 0) {
      doCapture();
    } else {
      imgNode.addEventListener('load', doCapture);
      imgNode.addEventListener('error', function() { callback(null); });
    }
  }

  function _checkForCaptcha() {
    var node = _evalXpath();
    if (node) {
      _captureAsBase64(node, function(dataUrl) {
        if (dataUrl) {
          window.chrome.webview.postMessage('captchaImage:' + dataUrl);
        }
      });
      _startDisappearMonitor();
      return true;
    }
    return false;
  }

  function _triggerInputFocus() {
    if (!_inputXpath) {
      return false;
    }

    try {
      var inputResult = document.evaluate(_inputXpath, document, null,
        XPathResult.FIRST_ORDERED_NODE_TYPE, null);
      var inputEl = inputResult.singleNodeValue;

      if (inputEl) {
        if (typeof \$ !== 'undefined' && \$) {
          \$(inputEl).trigger('focus');
          return true;
        } else if (typeof jQuery !== 'undefined' && jQuery) {
          jQuery(inputEl).trigger('focus');
          return true;
        } else {
          inputEl.focus();
          return true;
        }
      }
    } catch(e) {
      window.chrome.webview.postMessage('captchaLog:Failed to trigger input focus - ' + e.message);
    }
    return false;
  }

  _triggerInputFocus();

  if (!_checkForCaptcha()) {
    _captchaPoller = setInterval(function() {
      if (_checkForCaptcha()) {
        clearInterval(_captchaPoller);
        _captchaPoller = null;
      }
    }, 500);
  }
})();
''';

    try {
      await _wv?.executeScript(script);
    } catch (e) {
      KazumiLogger().e('[Captcha WebView] inject script error: $e');
    }
  }

  @override
  Future<void> loadPage(
    String url,
    String captchaXpath, {
    String? inputXpath,
  }) async {
    _currentCaptchaImageXpath = captchaXpath;
    _currentInputXpath = inputXpath ?? '';
    _buttonXpath = '';
    _customScript = null;
    _customScriptGeneration++;
    buttonWasClicked = false;
    _currentPageUrl = url;
    captchaWasFound = false;
    await _wv?.loadUrl(url);
  }

  @override
  Future<void> loadPageForButtonClick(String url, String buttonXpath) async {
    _currentCaptchaImageXpath = '';
    _currentInputXpath = '';
    _buttonXpath = buttonXpath;
    _customScript = null;
    _customScriptGeneration++;
    buttonWasClicked = false;
    _currentPageUrl = url;
    captchaWasFound = false;
    await _wv?.loadUrl(url);
  }

  @override
  Future<void> loadPageForCustomScript(String url, String script) async {
    _currentCaptchaImageXpath = '';
    _currentInputXpath = '';
    _buttonXpath = '';
    _customScript = script;
    final generation = ++_customScriptGeneration;
    buttonWasClicked = false;
    _currentPageUrl = url;
    captchaWasFound = false;
    await _wv?.loadUrl(url);
    unawaited(_injectCustomScriptWhenReady(script, generation));
  }

  Future<void> _injectCustomScriptWhenReady(
    String script,
    int generation,
  ) async {
    // executeScript can fail while WebView2 is between documents. Poll briefly
    // for a documentElement instead of waiting for navigationCompleted, which
    // may be delayed by slow third-party resources.
    for (var attempt = 0; attempt < 40; attempt++) {
      if (_wv == null ||
          _customScript != script ||
          generation != _customScriptGeneration) {
        return;
      }
      try {
        final href = await _wv!.executeScript(
          "document.documentElement ? window.location.href : '';",
        );
        final hrefText = href?.toString() ?? '';
        if (hrefText.isNotEmpty && !hrefText.contains('about:blank')) {
          await _injectCustomScript(script);
          return;
        }
      } catch (_) {
        // Navigation may still be swapping documents; retry shortly.
      }
      await Future.delayed(const Duration(milliseconds: 100));
    }
  }

  Future<void> _injectCustomScript(String script) async {
    logEventController.add('[Captcha WebView] Injecting custom script');
    final wrappedScript =
        '''
(function() {
  try {
    if (window.__kazumiCaptchaScriptActive === true) {
      return 'already-injected';
    }
    window.__kazumiCaptchaScriptActive = true;
    window.KazumiCaptcha = {
      log: function(message) {
        window.chrome.webview.postMessage('captchaLog:' + String(message));
      },
      clicked: function() {
        window.chrome.webview.postMessage('buttonClicked:');
      },
      done: function() {
        window.chrome.webview.postMessage('captchaGone:');
      },
      fail: function(message) {
        window.chrome.webview.postMessage('captchaLog:Custom script failed: ' + String(message));
      }
    };
    window.KazumiCaptcha.log('CustomScript injected on ' + window.location.href);
    if (!${script.trim().isEmpty ? 'false' : 'true'}) {
      window.KazumiCaptcha.fail('empty captchaScript');
      return;
    }
    var __kazumiResult = (function() {
$script
    })();
    if (__kazumiResult === true) {
      window.KazumiCaptcha.done();
    }
  } catch(e) {
    try { window.KazumiCaptcha.fail(e && e.message ? e.message : e); } catch(e2) {}
  }
})();
''';
    try {
      final result = await _wv?.executeScript(wrappedScript);
      logEventController.add(
        '[Captcha WebView] Custom script execute result: $result',
      );
    } catch (e) {
      KazumiLogger().e('[Captcha WebView] injectCustomScript error: $e');
      logEventController.add(
        '[Captcha WebView] Custom script inject error: $e',
      );
    }
  }

  Future<void> _injectButtonClickScript(String buttonXpath) async {
    final escaped = buttonXpath.replaceAll('\\', '\\\\').replaceAll("'", "\\'");
    final script =
        '''
(function() {
  window.chrome.webview.postMessage('captchaLog:ButtonClickScript injected on ' + window.location.href);

  var _xpath = '$escaped';
  var _clicked = false;
  var _poller = null;
  var _disappearObserver = null;

  function evalXpath() {
    try {
      var r = document.evaluate(_xpath, document, null,
        XPathResult.FIRST_ORDERED_NODE_TYPE, null);
      return r.singleNodeValue;
    } catch(e) { return null; }
  }

  function startDisappearMonitor() {
    if (_disappearObserver) return;
    _disappearObserver = new MutationObserver(function() {
      if (!evalXpath()) {
        _disappearObserver.disconnect();
        _disappearObserver = null;
        window.chrome.webview.postMessage('captchaGone:');
      }
    });
    _disappearObserver.observe(document.documentElement,
      { childList: true, subtree: true, attributes: true });
  }

  function checkAndClick() {
    var btn = evalXpath();
    if (btn && !_clicked) {
      _clicked = true;
      btn.click();
      window.chrome.webview.postMessage('buttonClicked:');
      startDisappearMonitor();
      return true;
    }
    return false;
  }

  if (!checkAndClick()) {
    _poller = setInterval(function() {
      if (checkAndClick()) { clearInterval(_poller); _poller = null; }
    }, 500);
  }
})();
''';
    try {
      await _wv?.executeScript(script);
    } catch (e) {
      KazumiLogger().e('[Captcha WebView] injectButtonClickScript error: $e');
    }
  }

  @override
  Future<void> submitCaptchaInteract(
    String captchaCode,
    String inputXpath,
    String buttonXpath,
  ) async {
    logEventController.add(
      '[Captcha WebView] Filling input and clicking button',
    );
    final escapedCode = captchaCode
        .replaceAll('\\', '\\\\')
        .replaceAll("'", "\\'");
    final escapedInput = inputXpath
        .replaceAll('\\', '\\\\')
        .replaceAll("'", "\\'");
    final escapedButton = buttonXpath
        .replaceAll('\\', '\\\\')
        .replaceAll("'", "\\'");
    final script =
        '''
(function() {
  function evalXpath(xpath) {
    try {
      var r = document.evaluate(xpath, document, null,
        XPathResult.FIRST_ORDERED_NODE_TYPE, null);
      return r.singleNodeValue;
    } catch(e) { return null; }
  }
  var inputEl = evalXpath('$escapedInput');
  if (inputEl) {
    inputEl.focus();
    var nativeInput = Object.getOwnPropertyDescriptor(
      window.HTMLInputElement.prototype, 'value');
    nativeInput.set.call(inputEl, '$escapedCode');
    inputEl.dispatchEvent(new Event('input', { bubbles: true }));
    inputEl.dispatchEvent(new Event('change', { bubbles: true }));
    window.chrome.webview.postMessage('captchaLog:Input filled');
  } else {
    window.chrome.webview.postMessage('captchaLog:Input element not found');
  }
  var btnEl = evalXpath('$escapedButton');
  if (btnEl) {
    btnEl.click();
    window.chrome.webview.postMessage('captchaLog:Button clicked');
  } else {
    window.chrome.webview.postMessage('captchaLog:Button element not found');
  }
})();
''';
    try {
      await _wv?.executeScript(script);
    } catch (e) {
      KazumiLogger().e('[Captcha WebView] submitCaptchaInteract error: $e');
    }
  }

  @override
  Future<String> getCookieString(String pageUrl) async {
    try {
      final result = await _wv?.getCookies(pageUrl);
      return result ?? '';
    } catch (e) {
      KazumiLogger().e('[Captcha WebView] getCookieString error: $e');
      return '';
    }
  }

  @override
  Future<String> getPageHtml() async {
    try {
      final result = await _wv?.executeScript(
        "document.documentElement ? document.documentElement.outerHTML : '';",
      );
      return result is String ? result : '';
    } catch (e) {
      KazumiLogger().d('[Captcha WebView] getPageHtml error: $e');
      return '';
    }
  }

  @override
  Future<String> getUserAgent() async {
    try {
      final result = await _wv?.executeScript('navigator.userAgent;');
      return result is String ? result : '';
    } catch (e) {
      KazumiLogger().d('[Captcha WebView] getUserAgent error: $e');
      return '';
    }
  }

  @override
  Future<void> unloadPage() async {
    _currentCaptchaImageXpath = '';
    _currentInputXpath = '';
    _buttonXpath = '';
    _customScript = null;
    _customScriptGeneration++;
    buttonWasClicked = false;
    try {
      await _wv?.executeScript("window.location.href = 'about:blank';");
    } catch (e) {
      KazumiLogger().d('[Captcha WebView] unloadPage skipped: $e');
    }
  }

  @override
  void dispose() {
    _currentCaptchaImageXpath = '';
    _currentInputXpath = '';
    _buttonXpath = '';
    _customScript = null;
    _customScriptGeneration++;
    buttonWasClicked = false;
    _currentPageUrl = '';
    for (final s in _subscriptions) {
      try {
        s.cancel();
      } catch (_) {}
    }
    _subscriptions.clear();
    try {
      captchaImageFoundController.close();
      captchaDisappearedController.close();
      initEventController.close();
      logEventController.close();
    } catch (_) {}
    final controller = webviewController;
    webviewController = null;
    if (controller != null) {
      // WebviewController.dispose 为异步，且 init 失败时可能抛错；
      // 这里不阻塞 UI，同时吞掉释放过程中的异常避免取消流程卡死。
      unawaited(controller.dispose().then<void>((_) {}, onError: (_) {}));
    }
  }

  Future<void> _setupProxy() async {
    final bool proxyEnable = GStorage.getSetting(SettingsKeys.proxyEnable);
    if (!proxyEnable) return;

    final String proxyUrl = GStorage.getSetting(SettingsKeys.proxyUrl);
    final formattedProxy = ProxyUtils.getFormattedProxyUrl(proxyUrl);
    if (formattedProxy == null) return;

    try {
      await WebviewController.initializeEnvironment(
        additionalArguments: '--proxy-server=$formattedProxy',
      );
      KazumiLogger().i('[Captcha WebView] 代理设置成功 $formattedProxy');
    } catch (e) {
      KazumiLogger().e('[Captcha WebView] 设置代理失败 $e');
    }
  }
}
