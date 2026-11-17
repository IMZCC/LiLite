# 原版到原生版的全面重审

固定上游为 `d9e9626f1a3f89cd9ca85e18f61aaba02634e12a`，复核从上一轮交付的 `daa2ea629cc15584ebcad032c7275424dbc4700f` 继续，覆盖原版实际页面、菜单、设置、状态保存和业务请求，不直接沿用既有 passed 结论

## 本轮结论如何产生

三个独立审查范围分别核对发现/阅读/设置与平台、账号/社会/数据、播放/直播/离线，再交叉检查新增实现。此前完成判断确实遗漏了一些可实现行为，以下问题已进入本轮源码修复，而非以平台差异或“服务授权”继续豁免

655 行清单是页面、嵌套界面、路由、偏好、README 和底层模块的重叠索引，不是 655 个独立功能或完成百分比。本轮撤销登录页、别名与设备列表的 3 行 partial；最终应为 636 implemented、16 not-ios、3 source-note，且严格完成门拒绝任何 pending/partial。16 条平台项须对应固定原版的 Android/桌面专属守卫，3 条备注仅允许原 README 的裸总结，具体证明继续由 `Checks/parity.py` 执行

## 实际发现与修复

| 原操作及触发 | 本轮修正 | 具体实现与核对 |
| --- | --- | --- |
| 推荐已有列表后刷新失败，重试请求错页 | 保存失败的刷新模式与页码，同一请求重试 | `FeedModel.Request/retry`，现有发现/过滤检查及 SDK |
| 话题分页后刷新失败，重试错用旧游标 | 保存 topic/owner/reset/cursor/sort，独立重试 | `TopicTimelineState.Request`，话题读回与 SDK |
| 移动推荐分区过滤遗漏、已关注错误豁免 | 在关注豁免前按 tname 应用分区过滤，请求与过滤共用捕获的来源 | `RecommendationFilter.mobileFeed`、`FeedModel`、`MobileFeed`，原有行为回归增量 |
| 搜索分类切换丢失列表/分页/筛选/位置 | 每分类保留独立页面及筛选，关键词/身份变化才整体失效 | `SearchView` / `RetainedDeck`，发现检查与 SDK |
| 账号用途缺少原版 API 说明入口 | 按真实服务映射显示用途说明 | `AccountRolesPanel` 直接消费 `AccountRoutes.services` |
| 评论提及人数设置 0 误过滤所有评论 | 按原版将 0 保存为禁用 nil | `ReplyFilterPanel`，原有规则与 SDK |
| 阅读页缺浏览器/复制链接直接操作 | 正常与加载失败均可打开原链接、复制链接 | `ArticleReader`，现有阅读及 SDK |
| 导入的过期 mobile token 阻断有效网页及本地离线 | web/mobile/local 用途独立证明，已核对本机 owner 可离线读取 | `AccountJar`、`ImportedCredentialProof`，真实合成回包、并发及无网络检查 |
| 误将原版公开 AppSign 当特殊签发身份 | 撤销豁免并补齐原生移动扫码、密码 RSA、短信、Geetest、风险短信与 OAuth2、设备列表 | `MobileClientSigning` / `MobilePassport` / `NativeLoginFlow` / `NativeLoginForm`，215 地区、签名独立 oracle、RSA 实际解密及状态机闭环 |
| 普通 app REST 仅带 Cookie、漏 access_key 和签名 | 所有 app 主机 REST 共用签名、用途及 UID/token/device 绑定，Cookie-only 按原版走签名匿名请求 | `MobileREST` / `MobileRESTSession` / `BiliAPI.fetch`，覆盖推荐、空间、搜索推荐、话题等，独立请求与会话变化回归 |
| 独立反馈及身份叶漏 app 签名 | 独立请求使用同一生产 signer，token-only 身份检查仍不借用网页登录或别的账号 | `CardPreferenceMutation`、`MobileAuthorization`、`ImportedCredentialProbe`，独立签名 oracle 与账号证明回归 |
| 话题游客头部误当本人点赞/收藏状态 | 仅真实携本人的 token 才缓存本人状态 | `TopicHeader.authenticatedOwner`，真实状态请求及显式未知分支 |
| 电视取流把公开签名变成不可取得的 Keychain 条件 | 移除不合理 operator 门槛，复用原版公开 AppSign | `CastProjectionSigning` / `CastGrantAPI`，现有投屏回环与播放许可检查 |
| 旧式单/多段 MP4/FLV durl 无播放、听视频或离线支路 | 统一总时间线、按段/GOP 准备、随机定位、音效/解码回退、后台下载及离线本地回放 | `LegacyDURL*`、原生 FFmpeg、`LegacyMediaComponents`，真实媒体逐帧、断点续传、许可、取消、目录封存与 sparse seek 回归 |
| 原证书设置被缩成私有服务器专用 | 恢复同义的默认关闭全局可选开关，实际传输栈及备份均消费 | `ServerCertificatePolicy` / `MediaCertificatePolicy`，TLS 负例、网络回环、备份及 SDK |
| 设置 UI 包装使语义生成器漏控件 | 保持显式原生控件，并按实际 anchor/静态键/直接 Binding getter 读取 | `ControlLabels.swift` / `terms.py`，317 锚点、145 语义项、45 个设置目标逐项核对 |
| 正常网页响应的 Set-Cookie 未更新会话 | 保留逐跳真实来源，并按 URI、域/路径/到期时间和原账号快照合并，游客上下文独立，拒绝迟到及跨号更新 | `WebSessionCookies` / `WebSessionSnapshot` 与账号回归，具体见会话 Cookie 报告 |
| 失效主账号仅报错、不清理原版会撤销的身份 | 主账号选择/导入与个人页读取确认未登录时撤销该会话并清其非持久网页上下文；网络/风控和其他账号保留 | 绑定主账号的 nav 结果与本机撤销通知，具体见会话 Cookie 报告 |
| 设备初始化和登录账号激活遗漏 | 游客初始化 SPI 与本地回退，具名实际用途账号按原顺序初始化/激活后发布状态 | `DeviceActivation` / `DeviceActivationContext`，请求序列化、并发、取消、Cookie 轮转与激活时序回归 |
| 自托管服务被硬性限定 HTTPS，WebDAV 缺 Digest | 按固定上游恢复 HTTP/HTTPS、80/443、LAN/端口与专用 DAV 认证，同源和凭据隔离保持 | 自托管地址/请求及 DAV 挑战策略，现有真实备份回环与身份拒绝检查 |

缓存末段完成与附件任务之间退出时，重启也会补齐尚未保存的字幕/弹幕，继续遵守用户 includeExtras 开关；账号切换、覆盖、删除和缓存归属检查保留

旧式媒体片段的共享等待者也补上 stop/seek 后的取消与任务代次复核，防止延迟生产者把已失效资源交给第二个等待者；保留单个等待者取消时其他使用者继续播放的行为，生产 actor 回归及删除此复核的变异负例均已执行

## 界面按当前苹果设计语言重做

默认使用系统 Tab 与独立搜索页、系统导航/表单、内容主次文字和自适应留白。推荐首项为主卡片，次要播放控制进入原生播放选项，个人页为资料头/四快捷入口/清楚分组，设置为原生图标行与分组 Form。自定义导航、旧系统、辅助字号与降低透明度保留对应分支，具体见[原生界面复核](reaudit-2026-11-13-interface.md)

参考 Apple 当前的[导航与 Liquid Glass 指导](https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass)、[标签栏](https://developer.apple.com/design/human-interface-guidelines/tab-bars)与[搜索](https://developer.apple.com/design/human-interface-guidelines/search-fields)。预览是按最终源码对照的本地 HTML/CSS 渲染，具有逐页文件摘要，使用虚构内容，不充当 iOS 真机或模拟器截图

## 证据与完整执行

- [发现/阅读/设置原操作矩阵](reaudit-2026-11-13-surface.md)
- [账号、社交及数据原操作矩阵](reaudit-2026-11-13-data.md)
- [媒体/直播/离线原操作矩阵](reaudit-2026-11-13-media.md)
- [原生界面、保留入口与预览](reaudit-2026-11-13-interface.md)
- [设备初始化及原版中间件可达链](reaudit-2026-11-13-session.md)
- [会话 Cookie 维护与失效账号恢复](reaudit-2026-11-13-cookies.md)
- [自托管地址、WebDAV 认证与请求隔离](reaudit-custom-services.md)

原版通用 `RequestUtils.validate` 虽有完整验证码函数，但唯一外部调用在固定源码中被注释，故没有遗漏可达的非登录验证码恢复入口；-352 原版只报错。WBI 按日/缺缓存重新取键的行为已对齐。原版保存及导出 refresh_token，但没有刷新令牌端点调用或定时续期，不能把未执行的死链算成可用功能

本轮再次用实际原生模型读取公开服务：热门 20、排行 100、影视 20/剧集 200、直播 14 大区/497 子区、联想词 10、直播短号及真实音视频 CDN 字节范围，均成功；日志 `dist/reaudit-2026-11-13/public-services.log`。另匿名真实核对官方公钥、签名二维码生成及未扫码轮询，不携带真人身份、不输出票据

正式整体验收统一针对最终冻结 Git 提交捕获 host/media/unsigned 收据，绑定执行命令、完整日志、实际 arm64 IPA 与源码/证据摘要；签名后再核对原设备授权、Apple 签章及签名前后的完整包内容。最终状态、对应源码提交、收据及交付 IPA 摘要以 `Acceptance/final.json` 为准，不能复用旧交付收据

真实账号写入、短信发送/密码输入/扫码确认、iPhone 音画和手势、系统画中画及实际电视接收器仍按[真机验收清单](../device-checklist.md)由用户安装后核对。个人开发签名的多播发现边界见[本机签名与投屏](personal-device-signing.md)，标准 Bonjour/手动 DLNA/AirPlay 路径保留
