# UP 投稿、合集、系列与资料库视频连续播放

对照固定上游 lib/pages/member_video/controller.dart（toViewPlayAll）、lib/pages/video/controller.dart（getMediaList、onReverse、updateMediaListHistory）、lib/http/user.dart（getMediaList）、lib/http/video.dart（medialistHistory）、lib/pages/fav_detail/controller.dart 和 lib/pages/later/controller.dart

- UP 空间的投稿、合集和系列目录可以直接“播放全部”，每个视频的菜单还支持“从这里连续播放”。有已记录的本机进度或此观看账号下服务返回的继续入口时显示“继续播放”。收听仍是独立入口
- 未筛选投稿使用原项目也调用的 /x/v2/medialist/resource/list。发布日期 / 播放量对应 sort_field=1/2，type=1、biz_id=UP 主；从已知 BV 恢复时带 oid 和 with_current，向前 / 向后使用边界资源和 otype=2。跨页去重，跳过没有可播放 CID 的条目。分页缓存支持回看；跨多页的明确页码跳转调用支持页码的投稿目录定位，不把数千页顺次拉下来。搜索词、投稿分类、专有标签、按收藏排序会改用原本支持该筛选的目录接口，队列沿用同一条件
- 合集与系列保持独立 business ID 和正倒序。依据服务 episodic_button 的 page_type、oid、desc、sort_field 还原远端继续播放；只解析所需参数，不打开返回 URI。服务没有给出列表类型时，仍能从合集 / 系列的正式分页目录播放。先用当前作用域本机书签，再用与观看账号一致的服务书签；已删除或拒绝的锚点显示状态，用户可选从头播放
- 选择下一条、上一条、选中列表行、列表循环皆由 LibraryQueueState 对接视频详情/剧集播放器。普通云队列以及全屏侧栏都保留当前条目；外层传 fullscreen 决定切换后是否留在全屏。系列内切换优先沿用服务返回的真实 CID。倒转按原版从新方向第一条有效视频播放，游标列表不需要遍历整个 UP 空间才能倒转或循环。内嵌/全屏通过 libraryPlaybackPanel 与 JoinedPlaybackPanels.merge(...,fullscreen:) 组合当前队列和视频选集
- 本机书签以投稿/合集/系列、目标 ID、筛选、排序和主账号/推荐账号/取流账号/观看账号区分，保存曾采用的服务顺序、排序字段、当前 BV 和页号，受“记住播放进度”控制。账号和隐私角色切换废弃旧请求。适用的 UP 队列切换资源时，原版 /x/v1/medialist/history 收到 upper_mid、oid、desc；CSRF 只走 app 原有的观看账号表单通道。写前复核全部角色，短时切换串行收敛到最新，成功才去重；失败不影响本地续播。过滤目录、收藏夹/稍后再看、访客观看身份不会误发 UP 主列表回执
- 独立复核收藏和稍后再看：现有 API 保留搜索、浏览排序与“未看完”过滤。倒转从新方向首项开始；失效视频不阻塞下一条。播放中移除要求可编辑且服务返回成功才重载，优先选相邻可播放项，保留方向和全屏；他人的公开收藏不可移除。超过 1000 条的收藏夹按固定上游限制禁用手动整理。原有 UGC、番剧跳转与收藏顺序/稍后再看筛选继续使用

**可重复核验。** 在 Native 下运行 bash Checks/creator_playlist.sh。生产的 CreatorArchiveCatalog、CreatorQueueDomain、CreatorPlaybackCursor、CloudLibrarySource、LibraryQueueState、MediaPageWindow 和账户路由直接参与；替代项只有 Apple UI 外壳、测试专用偏好库与进程内服务。测试覆盖从中间 BV 加载前后页、跳过缺失 CID、目录页面缓存、全屏切换、倒序的首项、常量请求数的列表循环、本机/服务续播优先级、类型及真实参数、拒绝不误播、不同角色与分类不串记录、回执拒绝/成功去重/切号停发、收藏移除、公开收藏不可编辑以及稍后再看筛选和循环。该回归通过，涉及的 Swift 文件通过 iPhoneOS SDK 类型检查

**实际公开读取。** 2026-11-12，匿名读取 /x/v2/medialist/resource/list（type=1、biz_id=2、ps=5）返回业务码 0、总数 44、本页 5 条都有可用 CID，has_more 为 true。同一时段匿名请求移动端空间的简化参数返回 −400，网页 WBI 投稿搜索返回 −352；没有重试这两条拒绝，也没有触碰验证流程。默认未筛选的 UP 投稿浏览和视频队列从一开始就直接读取公开游标。需要关键词、分类或按具体页号跳跃的查询若被服务拒绝，会说明失败，不替换成其他结果。个性化续播按钮及实际服务端观看历史写入未用真实账号测试；本机试验没有发送账号、Cookie、CSRF 或写操作到公网
