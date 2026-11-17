# 原生 iOS 跨模块核查

固定对照：PiliPlus 2.2.0.2，提交 d9e9626f1a3f89cd9ca85e18f61aaba02634e12a。原始 Dart 保留作为可复核的基线。设备包由 Native 目录的 SwiftPM 目标构建，业务和界面为 Swift/SwiftUI/UIKit；媒体使用 AVKit、Metal 与本仓库列出许可证的原生库

核对从两个方向做：一是从实际页面、嵌套界面、持久设置和上游功能项找到 Swift 中的触发点、参数、读取身份与结果处理；二是从网络操作和系统回调回查有没有入口、是不是把拒绝当成功，以及其他账号或上一条媒体的异步结果会不会覆盖当前界面。原 README 的分组与平台特有项保持可追溯，重叠的 655 行不能换算成功能百分比

| 领域 | 独立证据 | 重点 |
|---|---|---|
| 发现 | [推荐搜索](discovery-search-audit.md)、[频道、链接和网页](retained-discovery.md) | 推荐/热门的过滤、21 个榜单分区、7 类搜索、分页、位置、身份、验证回退 |
| 播放 | [视频详情](archive-detail-audit.md)、[输入](player-key-gestures.md)、[媒体系统](media-system-final.md) | 普通/互动稿件、真实授权、声画分轨、寻址、分 P 续看、画质、全屏、倍速和输入 |
| 番剧和课堂 | [剧集和课程](season-catalog-audit.md)、[分集离线](episode-offline.md) | 选集、付费/试看边界、历史观看者与实际播放者、在线和离线用同一集身份 |
| 听视频 | [音频、缓存与系统会话](offline-listening-final.md) | 正反向队列、独立音轨、锁屏、暂停/中断、定时与当前媒体所有权 |
| 弹幕和字幕 | [弹幕和字幕回归](danmaku-subtitles-audit.md)、[播放器输入](player-key-gestures.md) | XML/protobuf、分段、过滤、特殊弹幕、双语与 ASS 像素渲染、倒拖和暂停 |
| 账号 | [登录与账号](account-final-scope.md)、[账号协议](account-grant-scope.json) | 原生移动扫码/密码/短信与风险验证、公开客户端签名、设备列表、角色分流、钥匙串、凭据独立核验与离线归属 |
| 个人资料库 | [资料库与空间](personal-library-final.md)、[共享清单](shared-media-playlist.md) | 收藏/历史/稍后再看、顺序、批量操作、资源种类和回执 |
| 社区及消息 | [社交阅读](social-reading-signoff.json)、[账号与消息](account-messages-signoff.json)、[共用页面](common-page-actions.md)、[楼层](reply-domain-audit.md) | 动态与文章、投票、消息、评论/二级回复、给定楼层与媒体的关联 |
| 创作者 | [空间与创作者](personal-library-signoff.json)、[剧集目录](season-catalog-audit.md) | 空间、关系、投稿与分组、合集/系列、不同人的内容 |
| 直播 | [交互](live-interaction.md)、[直播间控件](live-room-controls.md)、[原生转封装](live-native-remux.md)、[表情和排行](community-and-live-emotes.md) | 房间与身份、线路及音频模式、实时与历史、SC、草稿和个人屏蔽 |
| 离线 | [缓存与系统会话](offline-listening-final.md)、[文件操作](offline-files-audit.md)、[文件位置](storage-locations.md)、[迁移与账号导入](data-integrity-final.md) | 分轨、断点、持久标识、受限内容、目录授权、取消后回调与进度 |
| 设置和备份 | [备份恢复](backup-restore-audit.md)、[原生界面](interface-signoff.json)、[迁移与账号导入](data-integrity-final.md) | 原版格式、分项导入、本机凭据、事务恢复、WebDAV 条件写入 |
| iOS 集成 | [系统媒体](media-system-final.md)、[系统会话](offline-listening-final.md)、[投屏](dlna-cast.md) | 画中画、音频中断、旋转、蓝牙/锁屏、间接输入、文件和照片权限 |
| 工程和包 | [构建/开发签名](personal-device-signing.md)、[协议回查](service-protocol-review.md)、[交付检查](release-review-gate.md) | 非 Flutter 的 arm64 iOS 17 包，内含许可证及着色器，来源、可执行文件签章、预置描述文件和目标设备 |

[逐项清单](../../parity.json) 记录实现与对应证据，[最终审查文件](../final.json) 绑定源码指纹。真实账号写入不会作为自动测试；宿主回归使用模拟回执、本地 HTTP/媒体、逐字节/像素验证，公开服务使用无账号读取。系统弹窗、声音、硬件/GPU、真实来电、外接设备以及实际操作后服务的最终业务结果见[真机清单](../device-checklist.md)
