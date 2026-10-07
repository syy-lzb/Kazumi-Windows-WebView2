> 历史记录：本轮固定依赖后的人工验收和构建方式以 docs/windows-cloudflare-webview-changes.md 为准。

# 普通搜索取消 R18 分类过滤（2026-10-07）

用户要求普通搜索同时返回 R18 和非 R18，并重新构建 Release。

`BangumiApi.buildBangumiSearchParams` 不再发送 `filter.nsfw`，保留关键词、动画类型、标签、排名、评分、日期和星期条件。榜单的 NSFW 参数保持原样。根据 Bangumi OpenAPI 的字段说明，不传该字段时有权限的用户可获取两类条目；无权限时服务端仍不返回 R18，不能将本地修改视作权限绕过。

验证：搜索参数和解析测试共 10 项通过；静态分析 17 info / 0 warning / 0 error。十个 hanime1 修复源码文件及三份实际缓存补丁通过维护脚本核验。

构建方式：`flutter build windows --release --no-pub`，不使用 flutter run。程序版本仍为 2.3.8+20308，此次为本地定制功能调整。

替换前备份：`<local backup>`，包含原日常 Release 和用户数据，原 Release 62 个文件完整校验。

新日常发布目录：`<local release>`。旧日常目录 `<local release>` 保留；桌面 Kazumi 快捷方式切换至新发布目录。此前的 `custom-windows-2.3.8-20261007` 标签保持原样，本次另建 `custom-windows-2.3.8-all-subjects-20261007` 标签。

此次记录的验证范围是构建、静态分析、测试及修复核验，不代表自动完成了服务端 R18 权限或完整视频播放验收。

参考：https://github.com/bangumi/api/blob/master/open-api/v0.yaml
