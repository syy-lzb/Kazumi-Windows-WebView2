# Windows 定制版维护

本目录记录已验证的 Windows 兼容性修复及更新流程。完整说明、依赖固定值和 2026-10-07 人工验收见 [兼容性说明](../../docs/windows-cloudflare-webview-changes.md)。保留 upstream 历史和 GPL-3.0，不安装官方二进制覆盖定制成果。

## 当前保护范围

- Windows 可见验证、安全释放 controller 和成功后的 WebView2 session 复用。
- 浏览器 rendered HTML harvest，不改回 cookie → Dio 请求受保护页面。
- 取消验证不无限自动重试；成功后的搜索尽量静默复用。
- @self 使用搜索结果播放页 URL。
- 导航前订阅 broadcast stream 和 DOM currentSrc/src/source fallback。
- 三个固定依赖 fork：WebView2 参数、ech_http MSVC CA 字符串、media-kit 通用 7-Zip 发现。
- 普通关键词旧公开接口兼容及新版回退；高级筛选保持原接口，见 search-compat-20261007.md。

protected-files.json 保存十个定制文件的 Git blob 和历史 SHA256。verify-preserved.ps1 只读核验十个源码文件、pubspec.lock 的四个固定 package，以及 package_config 实际解析到的 Git commit 和干净 checkout。先运行 flutter pub get。今后改动受保护文件或更新依赖时需先审阅和回归验证，再更新核验基线。

旧缓存源码快照、机器路径清单及本地整理报告已移至仓库外备份；它们不参与构建，也不在当前源码树中。旧提交仍保留原历史，没有重写。

## 更新流程

1. 从稳定分支最新提交开始，备份当前工作树、完整本地构建产物和用户数据。
2. fetch 官方正式标签，在独立更新分支/工作树合并；不用 reset、clean、整树 restore 或重写 upstream 历史。
3. 检查定制文件、依赖及 lock 的交集，逐项解决冲突，避免机械地全部选择任一方。
4. 运行 pub get、保护核验、analyze 和相关测试；认可基线为 17 info / 0 warning / 0 error，不为清零修改既有 info。
5. 本地构建 Windows Release，完整保留 DLL/data 等文件，直接运行 exe 验收。
6. 验收普通直连搜索、可见验证、成功后会话复用、取消行为、@self、正常播放及 watch?v=407947。Cloudflare 首次可能一次通过，也可能需多次尝试，不保证所有 Challenge。
7. 人工验收通过后再形成稳定提交；推送和发布仍按维护者明确授权执行。

## 历史记录

官方 2.3.8 仅改变信息卡片、播放器动画、时间表及版本号，没有覆盖十个定制文件。旧版保护标签为 custom-windows-2.3.7-protected-20261007；它不包含后续依赖固化，日后更新应从最新稳定提交开始。

sync-2.3.8.md、search-all-subjects-20261007.md 和 search-compat-20261007.md 为历史验收及搜索调查记录。规则配置独立于主程序，个人规则、数据库和 session 不提交。

自编译测试期间 api.kazumi.fyi 镜像搜索路径曾返回 401；切换“番剧条目加速 → 直连”后普通搜索恢复。本次不包含普通搜索鉴权修复，不提交构建凭据或用户令牌。
