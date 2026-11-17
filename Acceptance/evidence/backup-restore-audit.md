# 设置、数据包与 WebDAV 操作审计

固定上游 d9e9626f1a3f89cd9ca85e18f61aaba02634e12a，核对 lib/utils/config_archive.dart、lib/utils/storage.dart、lib/utils/storage_key.dart、lib/utils/accounts.dart、lib/utils/accounts/account.dart、lib/pages/my_reply、lib/pages/webdav/webdav.dart。SDK 为 arm64-apple-ios17.0 / iPhoneOS 27.1。以下“回归”是隔离的 Swift/ZIP/HTTP 实际运行；“已接入”是上游对照、实际调用链及 iPhone SDK 类型检查。未登录真实账号、未连接用户的 WebDAV，未装机

| 用户动作 | 上游数据与原生入口 | 结论与证据 |
|---|---|---|
| 导出/恢复普通设置 JSON | GStorage.exportAllSettings / importAllJsonSettings；设置 → 导出设置、从文件恢复；NativePrefs.archive / SettingsRestore | 两盒 setting、video 均校验。固定 SettingBoxKey 的 244 项中 220 项直接映射，danmakuBlockType 另作集合语义转换；5 个 VideoBoxKey 全部直接映射。原版两盒导入会重置缺席的对应项、保留原生专有项和未指定设备身份；老版稀疏原生 JSON 以当前设置补缺。非法类型在实际设置写入前拒绝。已有 BackupCheck 加本轮恢复回归 |
| 从旧版本/其他平台迁入再迁出 | BackupFormat.native、restorationBase、remainder、PortableArchive.Meta、PackRestorePanel | 兼容 v1 单层原生 JSON、带/不带 piliNativeFormat 的双格式、Flutter 盒、别名、旧字重和自定义字体名；纯原版/原生可分别保留值。14 个没有独立 iOS 映射的安全平台选项（含窗口尺寸、Android 输出驱动及刷新模式）可按原格式带回；未知键只在更新同一远端原文件时保留。不同来源/较新小版本/较新构建在恢复前展示；不接受不支持的 ZIP 主版本、重复条目或清单与实际成员不符 |
| 普通 ZIP、加密包、选择成员 | 设置 → 本地数据包，可选择原版兼容 ZIP 或可跨设备解密的 .pilipack；DataPackPanel / PackPreview / PortableArchive | meta 与 setting、account、blacklist、reply、search、customFont.otf 对应原版；缺席成员不提供恢复，人可独立选择。支持直接从原版设置 JSON 提取其可选私密项目。加密格式可只带私密设置；兼容格式中的字体/私密设置需要同时选择普通设置，以免 Flutter 当作完整配置误清其余设置 |
| 选择账号、验证持有、跨设备恢复 | 原版 LoginAccount.toJson 与 Accounts.importJsonAccount.putAll；PackAuthorization、ArchiveAccount.decode/validateRoles、AccountJar.mergeArchive | 账号/贡献 ID/服务器凭据默认均不选；勾选需 Face ID、Touch ID 或设备密码，普通 ZIP 导出另作明文确认。账号按已校验的 DedeUserID 合并，保留未导入账号；cookie、accessKey、refresh、buvid 用设备钥匙串。原版 0–3 角色兼容，原生扩展保留“跟随主账号/固定 UID/游客”，扩展不能更改原版记录中的实际归属。读取与提交均检查账号版本。两个合成账号、guest、伪造角色、身份与 Cookie 不符等 ArchiveKit 回归 |
| 备份密码与完整性 | DataPackCipher，iOS 系统 CommonCrypto + CryptoKit | 密码 NFC UTF-8、独立随机盐 16 字节、PBKDF2-HMAC-SHA256 600,000 轮、AES-256-GCM；版本和盐纳入认证。解密只需用户密码，设备解锁不是解密密钥。每次产生不同密文，Swift 可读独立 Python 样本、Python 可读 Swift 样本；错密、改头/盐/nonce/正文或标签均拒绝 |
| 恢复保存的本人评论 | 原版保存当前主号的 ReplyInfo Proto3 JSON；DataPack.restore + ReplyArchive.mergeForPack/rollbackPack | 新包携带确切 UID；旧包缺少归属须明确选择本机 UID，或同时勾选该份账号导入；不会根据“当前主号”或“包内第一个人”猜归属。按评论 ID 合并；保留导入原始 member 和图片等 Proto3 JSON 字段。实际临时目录中两个 UID 互隔、失败撤销、其他评论不变；并发改动时不覆盖用户新内容 |
| 恢复搜索、屏蔽、弹幕或字体 | search.json 写实际 search.history；blacklist.json 单独替换 RecommendationRules.blockedCreators；setting 中的弹幕开关/字号/样式/过滤；字体通过 Core Text | 不恢复黑名单时保留现有 UID；数据包内通用设置去除内嵌名单，不会绕过选择。字体按内容哈希存放，只加载从包里选中的字节；旧包中的路径字符串不会当成设备路径。缺席字体不替换可用自定义字体。逐项目校验 + iOS SDK；真实字体注册和文件选择留整包验收 |
| 恢复失败 | 先解析各选中项，StagedPreferences.collect 在临时套件准备设置；DataPackRestoreJournal 反向撤销新字体/评论文件/新贡献身份/新暂存服务凭据。账号钥匙串为最后一个可失败写入，随后发布非抛出设置 | 隔离回归：模拟已写入部分设置后抛错，目标套件保持原值；确认后只修改选中键；模拟钥匙串拒绝后撤销 UID 101、UID 202 不变；回滚并发冲突可见。这里覆盖进程内的返回错误/取消，不将掉电或进程强杀宣称为已经实测 |
| 迁移私人服务器和贡献身份 | WebDAV URI、用户名、目录、密码以及 blockUserID / blockServer 在原版 setting 盒；DataPackServerProfile / DataPackContributor 分项 | 普通 JSON/默认数据包不输出这些私密项。显式勾选的 WebDAV 配置先以独立 Keychain 项暂存，不覆盖当前服务器；界面展示地址并由用户填入、验证保存或丢弃。贡献身份只能写已显示的 HTTPS 服务地址，不替换该地址已有的不同 ID。证书例外、第三方 Android 反诈交接、旧机目录路径从不因备份而建立授权 |
| WebDAV 配置、备份与恢复当前设置 | 原版 webdav.dart：配置主机/账号/目录，递归目录、手机/平板/桌面文件；WebBackup → DAVConnection → DAVStore | 支持 HTTPS 目录和旧的指定 JSON 文件，手机/平板默认文件名与原版兼容；使用指定账号 Basic 凭据、临时不带 Cookie 的会话、禁重定向。创建用 If-None-Match，替换用服务器版本条件。旧远端若含私密项，必须明确选择覆盖去除或另存；覆盖确认绑定目标、用户、原文件摘要。已测固定文件/实际 HTTP 读写与过期 412；系统证书与钥匙串设备弹窗待真机 |
| WebDAV 版本、浏览、恢复、删除 | WebBackup → 管理远程备份 → DAVLibrary；保存单独设置版本、上传加密数据包、远程读取并预览分项 | 深度 1 PROPFIND 只接纳当前同源目录下受管理的备份文件；直接文件模式仅显示指定 URL。拒绝外域/兄弟目录/路径穿越、未知文件和 XML 外部实体。远程全量包只传加密内容；删除需确认和强 ETag，旧 ETag 读取或删除不重试。真实环回 HTTP 服务验证原版固定备份、两个版本、预览解密、删除、修改后 412、不触及其他文件 |

云端收藏、订阅、稍后再看、历史、动态库、下载媒体与本地观看进度不在固定上游 ConfigArchive.export 的成员里；搜索历史和当前主号保存的评论在其中。用户目录授权和服务器证书信任由 iOS 单独持有，不把原设备路径或授权票据伪装成可移植配置

复验（在 Native 下）：

- 运行 bash Checks/run.sh 中的 BackupCheck，或单独执行 swiftc Sources/PiliNative/Network/ServiceError.swift Sources/PiliNative/Settings/{BackupFormat,WebDAVStore}.swift Checks/BackupCheck.swift -o /tmp/pili-backup-compat，再运行产物：旧格式、两盒、表项类型、同文件更新、MKCOL 并发和条件请求通过
- swift test --package-path ArchiveKit --scratch-path "$HOME/.cache/piliplus-native/archive-tests"：6 项通过。原版布局由独立 zipfile 生成，Swift 输出也由标准 zipfile 反读
- python3 Checks/backup_recovery.py：真实环回服务只绑定 127.0.0.1 随机端口，凭据均为固定假数据；临时目录、独立 UserDefaults 套件和独立 Python AESGCM 相互校验。Linux 使用 Checks/storage_locations.sh 同一份固定版本 Apple Swift Crypto 构建产物及系统 OpenSSL；iOS 不引入它们
- 备份 SwiftUI、权限、两方钥匙串接口、ArchiveKit、WebDAV、还原和加密源码在实际 iPhoneOS 27.1 arm64 目标通过类型检查。当前无真实 WebDAV、Keychain 设备交互或整机 UI 的运行证据，父级统一交付前保留此项

可按本地证据登记的上游功能记录：page:webdav、upstream:feat/WebDAV 备份/恢复设置、preference:SettingBoxKey/webdavUri、webdavUsername、webdavPassword、webdavDirectory。preference:SettingBoxKey/blockUserID 的选择迁移、归属隔离、冲突处理与 Playback/SponsorSegments.swift 现有查看/手动更换链已接通；在线贡献并不由备份测试验证
