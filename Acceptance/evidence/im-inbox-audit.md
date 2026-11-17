# 消息、私信与聊天二次核查

基线 `d9e9626f1a3f89cd9ca85e18f61aaba02634e12a`。本轮只读取固定上游、构建和运行本地夹具；没有登录真人收件箱，没有实际上传图片或发送、转发、撤回、标已读、删除、置顶、举报人与消息

| 可核查的记录 | 原版操作及服务 | Swift 实现与本轮发现 |
| --- | --- | --- |
| `page:whisper`、`page:whisper_secondary` | `whisper/{controller,view,widgets/item}.dart`、`common/common_whisper_controller.dart`、`utils/extension/three_dot_ext.dart` | 主/次级会话通过服务的 offsets 分页；未关注、陌生人、垃圾箱、群分组、客服、AI 与系统通知分别路由。展示会话头像、名称、用户标签、直播、时间、摘要、置顶、静音、数字或圆点。整组已读/清理需确认，单聊可删除、免打扰、标已读，服务给出 ID 的分类/会话都可置顶。新增粉丝打开与上游相同的官方页面。聊天设置和已读成功后会话列表在返回时刷新 |
| `page:whisper_link_setting` | `whisper_link_setting/{view,controller}.dart` 读取 `imUserInfos/getSessionSs/getMsgDnd/SessionUpdate`，设置 `setPushSs/PinSession/UnpinSession/setMsgDnd/relationMod` | 以确切 peer 和主账号读取个人资料、内容推送、置顶、免打扰、拉黑；内容推送的 0 表示开启，免打扰的 1 表示开启，只有服务声明可设置时才显示内容推送。关闭推送、拉黑需确认；举报连接已有用户资料举报页，不混用单条私信举报。普通网页账号已有会话的置顶可从会话列表当时的状态和 web 置顶 API 读取/修改 |
| `page:whisper_settings`、`page:whisper_block` | `whisper_settings/widgets/item.dart` 与 `whisper_block/controller.dart`，`GetImSettings/SetImSettings` 与关键词 RPC | 读取服务端返回的设置页、分组、开关、选项、弹出选项、子页值回传，跳黑名单、关键词、官方网页；服务回执成功才更新。关键词数量、字数、去重、添加与确认移除均按服务状态；移动端专用设置需要相应登录授权 |
| `page:whisper_detail`（记录） | `whisper_detail/controller.dart`：`SyncFetchSessionMsgs` 与 `MsgHttp.ackSessionMsg`；`whisper/widgets/item.dart:_updateAck`：`SessionDetail` | 单聊消息由原账号分页取回，移动授权走 RPC，网页和只读群聊使用对应 web 服务。进入先定位最新，上翻加载早期内容、下拉刷新最新；表情、撤回控制与原消息合并。聊天按实际可读最新序号发送签名 GET `update_ack`，仅陌生人提醒及历史翻页不发，也不重复较旧序号。列表显式“标为已读”使用上游 SessionDetail 的 ackSeqno；写性质 GET 不重试/重定向。返回原账号前，其会话不借另一个账号继续显示或发送 |
| `page:whisper_detail`（消息、发送、撤回） | `whisper_detail/view.dart`、`widget/chat_item.dart`、`grpc/im.dart:sendMsg` | type 1 普通文本、表情与链接，2 图片、6 自定义表情、5 撤回，7 资源分享，10 通知的三个跳转，11 视频（含失效状态/附言）、12 专栏多图、13 图卡、14 常规/直播卡、16 多项卡、18 提示；未知类型可读原文。授权时发送类型 1/2/5/7/14 都走专属 SendMsg，网页账号走签名 web 服务，消息号/序号返回才认可。发送者在打开会话时固定，每次从相册上传后重新核对账号；RPC 会话中历史用 talkerUid、发送用服务提供的 avatar.mid，没有收件人（如 UP 助手）时只读。成功撤回后立刻禁用内容及转发，再拉取记录；消息举报同时约束原发送人、消息键和账号 |
| `page:contact`、`page:share` | `contact/view.dart`、`share/view.dart`、`RequestUtils.pmShare` | 关注、粉丝、关注搜索；普通入口点进空间，选择入口返回收件人，可管理自己粉丝。最近联系人、多人发送、附言、部分失败续送保留，与现有 IM 分享页共用。会话可转发文本、站内原图和已支持的资源卡，提交前回查同一会话、消息序号、原始 64 位消息键、发送者和撤回标记；不会转发系统控制消息。图片仅用原服务的 HTTPS 媒体地址、尺寸与格式，移除其他发送人字段 |
| `page:msg_feed_top`、`screen:msg_feed_top/{reply_me,at_me,like_me,like_detail,sys_msg}` | `msg_feed_top/*/{view,controller}.dart`、`http/msg.dart` | 回复、@、点赞和系统通知均可分页、核对账号和删除；支持用户空间、原文/定点回复、引用内容、附图，按最新/累计分别合并点赞分页，群组点赞进入来源和逐名用户，停止/恢复某项点赞通知。系统通知支持原版标记链接、【AV/BV】、（动态 ID）、普通网页和首次游标已读 |
| `preference:SettingBoxKey/disableLikeMsg`、`msgBadgeMode`、`msgUnReadTypeV2` | `whisper/controller.dart`、源设置与主页角标 | 延用原生提示偏好及未读类别掩码；移动授权有服务端未读计数，普通网页登录现在也能取得原通知数。出入通知页或成功确认私信已读触发刷新 |

**验证记录**

- 原版 protobuf 由 `Native/Checks/generate_wire.py` 的固定 Git 描述符重建，新增 `SessionUpdateReq/Reply`、`ReqSessionDetail`、`SessionInfo`。在临时目录生成，只复制变化的 3 个 IM 文件；当时 `--check` 的 21 个文件、639 项一致（其他模块的独立增量会改变总数）
- WSL 隔离依赖目录 `swift test --package-path Wire --filter IM`：7 个测试、0 失败。模拟请求与回执覆盖发送者/接收者、真实 RPC 路径、图片、撤回、64 位键、读取/置顶会话身份、序号、offset、表情和失败状态；没有网络客户端向真人发送数据
- `cd Native && bash Checks/im_notice_actions.sh` 通过：系统原文链接、带上下文的回复、未知未读字段、不转发控制消息、图片域名和私有字段隔离
- iPhoneOS 27.1 SDK、arm64 iOS 17，21 个相关应用源文件独立类型检查通过，包括账号授权、收件箱、聊天、相册编码、全部通知和分享；未安装本轮 IPA

**仍需真实环境的部分**

双账号实际收件、服务对撤回时限的当场判定、系统相册 GIF/APNG 的真机导出与接收端显示、新增粉丝页登录及服务器当日提供的设置项未动用真人账号验证。群聊沿用可读通道；原版没有在群折叠/系统身份中提供任意群消息发布或伪装收件人的能力。Windows 的线下回包也不能代表目标服务今天一定给某个账号下放对应权限
