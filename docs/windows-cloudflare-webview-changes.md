# Windows Cloudflare／WebView 兼容性修改

## 背景

这是 Kazumi 的非官方修改分支，与上游项目无隶属关系，也未获得上游认可或背书。

这是个人维护的 Kazumi fork，改善 Windows WebView2 对 anti-crawler 页面及部分媒体源的兼容性。保留 upstream Git 历史、原作者和贡献者归属，以及 GPL-3.0 LICENSE。hanime1 兼容不代表 upstream Kazumi 官方支持该站点。

## 主要修改

1. **Windows 可见 Cloudflare 验证**：在应用内显示可交互 WebView2 验证页面。
2. **WebView 会话复用**：成功后保留当前控制器和会话，后续搜索通常可静默复用。取消验证不会启动无限自动重试。
3. **反爬搜索获取渲染后的 HTML**：直接读取浏览器渲染后的 HTML，再使用规则解析；不改回 cookie → Dio → HTML，因为携带 cf_clearance 的 Dio 请求仍可能返回 403。
4. **@self 章节处理**：chapterRoads 和 chapterResult 都为 @self 时，直接使用搜索结果 URL 作为单线路播放地址。
5. **WebView 生命周期稳定性**：先让验证界面移除，再释放控制器，避免组件仍挂载时的原生访问冲突。
6. **视频解析广播流竞态修复**：导航前订阅广播事件，用 Completer 保存第一个事件，finally 取消订阅，避免漏掉 loadUrl 期间的结果。
7. **Windows WebView2 的 DOM 媒体备用解析**：保留原生媒体捕获，并检查 video.currentSrc、video.src、video source[src] 中有效的 http/https 地址。
8. **可复现的依赖分支**：三个依赖补丁已通过下述 fork 与完整提交固定，不再手工修改 Pub Cache。

十个已有定制文件由 `maintenance/windows/protected-files.json` 记录。本轮依赖固化和文档整理未改变这些文件。

### 规则配置独立于主程序

hanime1 的 XPath 属于用户导入规则，不是内置主程序代码。clone 不会自动获得个人规则、cookies 或设置；以下仅为已验证的规则语义片段，不是完整可导入规则：

```text
searchList: //div[@id='home-rows-wrapper']//div[@class='horizontal-card']
searchName: .//a[@class='video-link']/div[@class='title']
searchResult: .//a[@class='video-link']
chapterRoads: @self
chapterResult: @self
```

### 普通番剧搜索

自编译版本测试期间，Kazumi 镜像搜索路径 api.kazumi.fyi 曾返回 401。切换“设置 → 网络 / 代理 → 访问加速 → 番剧条目加速 → 直连”后，普通番剧搜索恢复正常。因此本次源码修改不包含普通番剧搜索鉴权修复。

当前代码还保留此前提交的普通关键词旧公开索引兼容及新版接口回退，高级筛选继续使用新版接口。此项与 Windows Cloudflare 修复分别记录，见 `maintenance/windows/search-compat-20261007.md`；详情、评论及高级筛选可见性仍由服务端决定。

## 已验证行为

2026-10-07，用户对固定依赖后的 Windows 构建完成人工验收，以下四项均通过：

- 普通番剧搜索正常，番剧条目加速使用“直连”。
- hanime1 搜索通过可见 WebView2 完成 Cloudflare 验证，验证后的 session 可以继续复用。
- 原本可播放的视频继续正常播放。
- https://hanime1.me/watch?v=407947 此前约 15 秒后抛出 VideoSourceTimeoutException，现通过 DOM currentSrc fallback 可以正常解析播放。

首次 Cloudflare 验证不保证一次成功。受当前验证机制、网络条件和浏览器会话状态影响，可能立即通过，也可能需要多次尝试。

验证成功后，当前实现会保留并复用 WebView2 会话，后续搜索通常可以复用已通过验证的会话。

技术验证：flutter pub get 成功；flutter analyze 为 17 info / 0 warning / 0 error；git diff --check 通过；Windows Release 构建成功。media-kit 的 11 项归档/工具发现测试及实际 .7z 解压验证通过。这些结果不是所有视频、站点或 Windows 环境的保证。

## 已知限制

- Cloudflare 验证机制可能随时间变化，不保证兼容所有挑战页面或未来实现。
- 首次验证可能一次通过，也可能需要多次尝试；重复尝试不保证一定成功。
- 会话复用仅适用于验证成功之后，会话仍可能失效。
- DOM fallback 仅处理 DOM 已暴露的有效 http/https media URL；blob:、MSE、DRM 等不保证解析。
- @self 是“搜索结果即播放页”站点的扩展语义；hanime1 兼容不代表 upstream 官方支持。
- Windows .7z 构建需要可用的 7-Zip 安装或 MEDIA_KIT_7ZIP 配置。
- 完整站点使用仍需用户自行导入合适规则；用户数据和验证 session 不随源码分发。

## 依赖维护分支

以下是原项目的维护 fork，保留各自历史和许可证，不代表本仓库维护者原创这些依赖。pubspec.yaml 与 pubspec.lock 均固定完整 commit。

| 依赖包 | 维护分支仓库 | 固定提交 |
| --- | --- | --- |
| webview_windows | https://github.com/syy-lzb/flutter-webview-windows.git | 04786a4df07cfd7fa3496f01b14699e60055dba9 |
| ech_http | https://github.com/syy-lzb/ech_http.git | 8a0077271605774f75f05170225ebcc82352d361 |
| media_kit / media_kit_video | https://github.com/syy-lzb/media-kit.git | f7ac8bc029c0d29dca1b170c2322ec555ac60b40 |

webview_windows 从 Predidit 的 2b3306d2bfb9f22cbb328743b60e547cf50f0c3c 开始，仅移除 --disable-web-security、--disable-site-isolation-trials，保留 --msEdgeWebViewApplyWebResourceRequestedFilterForOOPIFs。

ech_http 基准与 pub.dev 0.2.1 发布源码一致，仅在 MSVC 下拆分 CA bundle raw string，避免超长字符串编译问题；包版本保持 0.2.1。

media-kit 从 Predidit 的 803c4a27912091db6f839d48d1b984a0d9f588c7 开始，仅扩展 Windows .7z 解压及相关测试。media_kit 1.1.11、media_kit_video 1.2.5 保持原版本和 path package 结构，两者使用同一 commit。

7-Zip 查找顺序为 MEDIA_KIT_7ZIP、PATH 中的 7z.exe / 7zz.exe、Windows Program Files 常见安装位置。不存在的候选跳过，最终找不到时明确提示安装或配置，不回退到可能缺少 LZMA 支持的 bsdtar。归档路径安全检查保留，其他格式继续使用原逻辑。

## 构建

需要 Windows、Flutter 3.47.6 / Dart 3.13.5、Visual Studio C++ 构建工具、WebView2 和上述可用的 7-Zip。将 Flutter 加入 PATH，在源码根目录执行：

```powershell
flutter pub get
flutter analyze
git diff --check
powershell -ExecutionPolicy Bypass -File maintenance/windows/verify-preserved.ps1
flutter build windows --release
```

如需显式指定工具，在自己的构建终端设置 MEDIA_KIT_7ZIP 为已安装的可执行文件路径，不将个人路径写入源码。

原有 checkout 从 hosted 依赖迁移到 Git 后，若 CMake 报源目录与旧缓存不一致，可备份并移走错误所指的生成缓存目录再构建；不要修改依赖源码或覆盖整个工作树。全新 checkout 不携带这些旧缓存。

clone 本提交后，pub get 会自动获取以上补丁源码，无需手改 Pub Cache。构建工具、网络可达性、规则配置和 Cloudflare 状态仍需满足各自条件；尚未在全新电脑上完成完整验收。直接运行 exe 做人工验收，不以 flutter run 为主要验收。本仓库只维护源码，不发布 exe 或 GitHub Release。
