> 历史记录：本轮固定依赖后的人工验收和构建方式以 docs/windows-cloudflare-webview-changes.md 为准。

# 2.3.8 定制版同步与验收记录（2026-10-07）

## 保存与隔离

- 原目录：`<local checkout>`，稳定分支 `windows-visible-captcha`，保留 2.3.7 日常 Release。
- 有效修复提交：`1c26285f`；外部补丁及维护记录：`75c8d659`、`1a633c51`。
- 推荐恢复标签：`custom-windows-2.3.7-protected-20261007`。
- 更新工作树：`<local checkout>`，分支 `codex/sync-official-2.3.8`；用户验收后已合并至稳定分支 `windows-visible-captcha`。
- 合并官方标签 `2.3.8`：`0cce1aa4`，没有冲突。上游仅改变四个文件；十个定制源码文件和依赖版本保持原样。
- 备份：`<local backup>`。旧 Release 的 60 个文件全部 SHA256 核验一致；包含用户数据、WebView2 profile、十个工作树修改文件、七个未跟踪文件、三份外部补丁以及完整 Git bundle。
- 原有七个备份/诊断文件当时保留；源码整理后移至仓库外备份，未删除。
- WebView2 profile 位于 `%LOCALAPPDATA%\flutter_webview_windows\kazumi`，新旧 exe 同名，因此使用同一个原有 profile。不要同时运行两版。

## 验证

- 合并前、合并后及补充测试后的静态分析：17 info / 0 warning / 0 error。Flutter analyze 因 info 返回 1，按本项目认可的基线通过。
- 保护核验：十个定制源码文件的 Git blob 内容相同，三份实际缓存补丁及仓库快照 SHA256 相同。
- 相关测试：52 项通过，覆盖规则引擎、API 规则、规则配置、普通搜索参数和搜索条件解析。
- 旧测试将无 challenge 标记的 403 预期为普通搜索错误，旧版与合并版均失败。为保留既有验证流程，将普通服务错误用例改为 500，并新增 403/429/503 转交验证、harvest 空结果和 @self 相对/绝对 watch URL 测试。仅修改测试，未调整定制实现。测试提交 `410c8fc2`。
- 构建：`flutter build windows --release --no-pub` 成功，未使用 flutter run。
- 可运行发布目录：`<local release>`，版本 `2.3.8+20308`，完整复制后 61 个文件核验一致。
- 已直接运行该目录的 exe，并从可访问控件确认热门番组页面正常显示。
- 自动窗口截图工具分别返回 `FrameArrived timed out` 和 `window capture timed out`；文本控件可以读取，但两次控件点击均返回 `element ... is not available in cached app state`。自动界面验收未完成；后续用户亲自验收并明确回复“验收通过”。

## 人工验收通过

1. 普通番剧搜索；保持“番剧条目加速 → 直连”。
2. 规则仓库浏览及规则搜索。
3. hanime1 搜索、在 Kazumi 中可视完成 Cloudflare 验证、再次搜索复用会话。
4. @self watch URL 直接播放；正常视频继续播放。
5. `watch?v=407947` 视频通过 DOM fallback 播放。

用户于 2026-10-07 明确回复“验收通过”，上述验收清单作为通过记录保存。已将候选分支合并回稳定分支。正式定制版标签：`custom-windows-2.3.8-20261007`；原候选标签保留作过程记录。人工验证结果来自用户确认，不属于自动工具的验证结果。

日常程序为 `<local release>`；桌面现有 `Kazumi.lnk` 已指向此文件，保留用户命名与启动入口。无须命令行启动。后续仅通过源码合并及定制编译更新，不安装官方二进制覆盖。下一次同步从这个正式标签建立独立更新分支。

旧版仍可运行 `<local checkout>`；额外完整副本在备份目录的 `Release-2.3.7-custom`。源码恢复应从保护标签新建分支/工作树，避免 reset 或覆盖用户的新修改。
