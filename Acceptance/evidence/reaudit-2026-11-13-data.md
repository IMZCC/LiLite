# 2026-11-13 账号、社交与本地数据复核

本轮重新读固定上游 `d9e9626f1a3f89cd9ca85e18f61aaba02634e12a` 的 Dart 调用链，再查 Swift 入口、取数、动作发送及回包消费者，审查开始时工作树 HEAD 为 `daa2ea629`

发现并修复了移动端登录和设备签名被错误列为不可移植、导入凭据首用把 web/mobile/local 绑在一起、旧登录入口的迟到保存，以及独立反馈请求漏签名等实际问题

## 发现与修复

| 严重性 | 实际问题 | 本轮处理 |
| --- | --- | --- |
| P1 | 先前把移动登录、登录设备的应用签名视为 issuer 私有能力，因而缺了原版客户端的扫码令牌、密码、短信及风险验证闭环 | 更正该结论并实现公开源码的 AppSign、TV QR、RSA 密码、SMS、Geetest、风险短信、OAuth2 换令牌及设备签名，网页登录与 Cookie 仍可独立使用 |
| P2 | 导入账号即使只读 web 收藏或本地缓存，也先验证全部 Cookie 和 accessKey，过期 accessKey 会阻塞正确 Cookie 和离线使用 | `current(credentials:)` 分开 web/mobile/both，未证明的另一种凭据不返回给消费者，`localOwner` 只读本机已确认身份，不联网、不暴露凭据；新导入的 UID 声明不能直接取得既有缓存 |
| P2 | 旧 Cookie、网页 QR、网页登录和手填令牌在异步验证后未统一检查保存时的账号 generation，Cookie/手填入口也没有完整取消任务 | `add`、`addSession`、`setMobileToken` 保存前检查任务取消及可选 generation；相关 UI 保存捕获 generation，离开取消任务；新登录状态机还绑定 expectedUID、验证码 ID 和 operation |
| P2 | 交叉复核发现密码登录请求未完成时仍能编辑账号输入，迟到 A 结果会在 B 的输入画面保存 | 请求期间禁用账号、密码及手填令牌输入，方法切换和离开仍取消旧任务 |
| P2 | 推荐反馈、取消反馈及视频点踩的独立 app REST 请求漏了上游 AccountManager 自动注入的 AppSign | `CardPreferenceMutation.sendOnce` 使用生产共享 signer，feed 保留原版 build=1/mobi_app=android，archive 保留 aid/dislike，重用既有一次发送和真实 ack 拒绝处理 |
| P2 | 导入 accessKey 与手填移动令牌的两个独立身份读取仍未附 AppSign | 两入口共用 `MobileIdentityRequest` 与隔离 `ImportedCredentialProbe`，只签调用者传入的 token，附 guest 设备头；不从 AccountJar 选替代身份、不带 Cookie，myinfo 成功回包的正数 UID 才能继续证明或保存 |

`ImportedCredentialProof` 的旧 Keychain 兼容仍在：普通既有登录不会突然成为未确认导入账号；从 archive 新导入的凭据只对改变的材料要求证明，证明不会写入导出账号备份

并发 web/mobile 首用按 owner、凭据种类和原始材料去重，回包归属不符、换号、同 UID 换凭据或任务取消均不能把旧证明写到新会话，已确认的本地 owner 可继续离线访问属于自己的缓存

## 更正先前 issuer 例外

固定上游 `lib/common/constants.dart` 公布了 `appKey`、`appSec`，`lib/utils/app_sign.dart` 的处理只是补 appkey/ts、按键排序、`Uri.encodeComponent` 编码并计算 MD5(query + appSec)，不存在此流程必须调用的私有签名服务、设备证书或受保护的颁发端

`lib/http/login.dart` 已直接实现以下正常客户端请求，因此它们属于本次可实现范围，不能继续以缺少 issuer 授权豁免

| 上游方法 | 对应 Swift 协议与消费 |
| --- | --- |
| `getHDcode` / `codePoll` | `MobilePassport.qrTicket/qrPoll` 发出相同签名 POST query，解析等待、已扫码、过期和顶层 access_token + cookie_info |
| `getWebKey` / `loginByPwd` | `MobilePasswordCipher` 处理 SPKI 或 PKCS#1 PEM，Security 使用 RSA PKCS#1 v1.5，加密 salt + password 及随机 dt，再签名密码表单 |
| `sendSmsCode` / `loginBySms` | 发送与登录各自携带 cid/tel、验证码及 captcha_key，Geetest URL 不全时使用 preCapture，保留源列表全部 215 个地区 |
| 密码 `status == 2` 分支 | `MobileRiskContext` 校验官方风险 URL，取绑定手机号、preCapture、签名发送风险短信、校验验证码、以 authorization_code 换完整会话 |
| `loginDevices` | `MobilePassport.deviceListRequest` 使用同一公开 AppSign，带 access_key、CSRF、buvid/local_id 和 statistics，`LoginDevices` 消费真实 devices 字段并复核保存的账号材料 |

密码的上游 `encrypt` 5.x 默认同样为 RSA PKCS#1，已核对[该库原始实现](https://raw.githubusercontent.com/leocavalcante/encrypt/5.x/lib/src/algorithms/rsa.dart)

`QRLoginView` 现可选客户端登录、网页登录、Cookie 和网页二维码，客户端页提供扫码、密码和短信，移动授权页可用同样流程重新授权并限定当前 UID

所有移动登录在写入前都以隔离 Cookie 的 `/x/web-interface/nav` 和不携带 Cookie 的 `/x/v2/account/myinfo` 分别核对，两个回包和原会话 Cookie UID 必须一致，再由 `AccountJar.addSession` 一次提交 Cookie、accessKey、refresh、设备和本地证明，不在中间切换到只有一半凭据的账号

## 实际对照的业务路径

以下是本轮阅读到的路径与操作，不用现成 passed 清单替代这些检查

| 领域 | 上游覆盖 | Swift 消费与核查要点 |
| --- | --- | --- |
| 账号用途及多账号 | `utils/accounts.dart`、`utils/accounts/api_type.dart`、`models/common/account_type.dart`、`pages/login`、`http/login.dart`、`app_sign.dart` | `AccountRole`、`AccountServices`、`Accounts`、`QRLogin`、`NativeLoginFlow`、`MobileAuthorization`；检查主账号与 video/recommend/heartbeat 指派、guest、导入、同 UID 替换及 Cookie/token 分开使用 |
| 登录设备与日志 | `pages/login_devices`、`models_new/login_devices`、`pages/{login_log,coin_log,exp_log,log_table}` | `LoginDevices`、`AccountLogs`；确认设备名、本机标记、时间、来源的真实字段及登录后的入口，设备签名缺口已补 |
| 私信与通知 | `pages/common/common_whisper_controller.dart`、`pages/{whisper,whisper_secondary,whisper_detail,whisper_settings,whisper_link_setting,whisper_block}`、`pages/msg_feed_top/{reply_me,at_me,like_me,like_detail,sys_msg}` | `Inbox`、`IMSessions`、`MessageComposer`、`IMMessageReport`、`NoticeViews`、`NoticeService`；检查会话和通知游标、折叠/次级会话、读取/全部已读、置顶/免打扰、撤回/举报、系统通知确认及身份隔离，均有实际请求和消费者 |
| 动态与管理 | `pages/dynamics_detail/controller.dart`、`pages/common/dyn/common_dyn_controller.dart`、`pages/member_dynamics/controller.dart`、`pages/dynamics_create/view.dart`、`pages/dynamics_create_{vote,reserve}` | `DynamicDetail`、`MomentOwnerSettings`、`DynamicRevision`、`DynamicEditView`、`Votes`、`VoteEditor`、`MomentResources`；检查主账号重新读取后的点赞、转发、删除、置顶、公开/私密和评论控制，投票/预约有自己的数据模型和请求 |
| 评论 | `pages/common/reply/reply_controller.dart`、`pages/common/reply/{fold,vote}`、`pages/main_reply`、`pages/video/{reply_reply,reply_new}` | `Discussion`、`ReplyComposeRules`、`ReplyTools`、`ReplyDraft`、`ReplyComposeAssets` 与 Wire ReplyGateway；检查主/子评论 root-parent、排序和翻页、折叠/对话/定位、置顶、点赞/点踩/删除、输入限制、翻译、插入视频/专栏和发送回执，未见只有标签而无消费者的空壳 |
| UP 空间与关系 | `pages/member/controller.dart`、`models/common/member/tab_type.dart`、`pages/member_{dynamics,favorite,search,opus,contribute}` | `Creators`、`CreatorSections`、`CreatorHeaderDetails`、`CreatorFavorites`、`CreatorSearchResults`、`CreatorQuickRelation`、`CreatorCatalog`、`CreatorOpus`；核对服务端 tab、默认栏、投稿/收藏/合集、搜索、图文游标、主页资料/头图/充电/舰队/预约、关注/特别关注/分组/拉黑/移除粉丝入口与实际动作 |
| 收藏、稍后看、历史 | `pages/{fav_detail,fav_sort,fav_folder_sort,subscription_detail,history,later}` 的 controller/base_controller 和 `fav` 各类别 | `CloudLibrary`、`FavoriteOrder`、`FavoriteMedia`、`Subscriptions`、`HistoryLibrary`、`CloudLibrarySource`、`LibraryPlaylist`、`LibraryQueueState`；核对文件夹及内容排序、订阅逆序、分类目标、失效条目、history 删除 kid/business、播放队列和选中项；收藏排序超过 1000 的限制上游也存在 |
| 备份与缓存完整性 | `pages/webdav`、`utils/accounts` 的归档字段、上次固定迁移/存储修复与本轮凭据入口 | `DataPack`、`BackupFormat`、`WebDAVStore`、`WebBackup`、`OfflineMediaStore`、`OfflinePackage`、`OfflineVideo`、`Downloads`；核查导入的阶段性回滚、账号最终提交、本地证明不导出、条件写入、迁移新权威失联保留唯一旧文件、删除前复核 owner，以及本地读取不被网络凭据验证阻塞 |

本轮没有用真实账号发帖、发送私信、改关系、删历史或覆盖 WebDAV，以上写操作通过源码实际发送路径和合成边界核查

## 本轮可运行证据

- `bash Checks/imported_credentials.sh` 通过：真实生产 AccountJar 使用内存 Keychain 与合成身份回包，覆盖过期 mobile 不阻塞 web/local、未确认导入不准读文件、跨 UID 凭据、同字节复用、16 个并发 web/mobile 证明、取消、同 UID 替换、换角色、原子登录及旧 Keychain 兼容，导出不含 proof
- `python3 Checks/mobile_passport.py` 通过：运行生产编码、签名、PEM 拆包、协议、解码、验证与 UI flow 状态机，独立 Python/hashlib 与 OpenSSL 复核 AppSign、RSA salt+password 和 dt 解密、随机 PKCS#1 填充、全部 11 条请求路径、设备签名及 215 地区，覆盖错误 expectedUID、混合凭据、陈旧验证码、取消中途验证和 generation 变化拒绝保存
- 最终身份叶复核扩展同一 fixture：运行生产 token-only myinfo 构造/回包解析和手填入口委托，独立 oracle 核对普通与含保留字符 token 的精确 access_key/sign，没有 Cookie、Authorization 或角色 UID；无效 token、HTTP 拒绝、服务拒绝和缺失/非正 UID 均不通过
- `python3 Checks/discovery_readback.py` 通过：原有实际请求/回包 fixture 加入反馈、取消反馈、视频点踩/取消四种精确表单签名，与独立 Python oracle 比对，超时及服务拒绝仍只发送一次
- Linux 的 CryptoKit/Security 叶由 OpenSSL 适配执行，iPhone 的实际 Security 调用与全部 15 个登录核心/页面使用 iPhone 27.1 arm64 SDK 完成定点类型检查
- `python3 Checks/mobile_passport.py --anonymous` 通过：实际获取官方登录公钥，按生产 AppSign 生成临时 TV QR，再轮询得到未扫码等待状态，未保存或输出 auth_code、二维码 URL、Cookie 或 token
- 日志在 `dist/imported-credentials-data-check.log`、`dist/mobile-passport-check.log`、`dist/mobile-passport-anonymous.log`、`dist/mobile-passport-sdk-run.log`、`dist/card-preference-signing-check.log`

对原生源码的 `app.bilibili.com` 直接 URLRequest 入口另外逐一核对：统一 `BiliAPI.fetch/read` 的 app REST 及话题 own-state 由网络复核代理接通用 MobileREST，会话反馈由该代理接同样身份核对；本轮处理上述独立 mutation 构造，独立 token-only 身份核对、MobilePassport 和 gRPC 保留各自协议，不重复叠加通用 REST 签名

数据改动此前已通过覆盖全部所改消费者的 arm64 SDK 定点，本轮最终全树构建由主代理在各域冻结后统一运行

## 真机操作范围

本轮未签名安装，未使用真人密码、短信或扫码确认登录，因此还需要用户在真机体验 Geetest 展示、完整登录成功后的设备记录，以及私信通知、收藏历史、评论动态写入和外部缓存提供方的实际使用

这些交互均保留真实业务入口，没有再以 issuer 限制留下缺失的客户端实现
