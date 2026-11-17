# 固定上游 gRPC 与 HTTP 服务差异

基线 d9e9626f1a3f89cd9ca85e18f61aaba02634e12a。不把仓库生成的数千条消息类当成功能。grpc-service-matrix.json 收录 GrpcUrl 的 37 个服务方法，并以包装类名回溯 Dart 可执行调用点（排除行注释/块注释、声明和生成代码），再对应 Swift 的请求构造、响应消费和入口。35 个有实际调用，均可联到同一真实服务：听视频 5、弹幕 2、动态/作者空间 5、会话消息 17、评论 6。OpusDetail 没有可执行调用；ViewUnite/View 只在已注释的 PGC 示例中出现。

| 核查 | 已实现行为与验证 |
|---|---|
| gRPC 正常响应 | 生产 WireFrame 验证 HTTP 状态、MIME、gRPC 成功状态、长度、压缩标记与 gzip 膨胀上限，再按固定 protobuf 描述符解码。原生 Wire 模块对 650 个依赖的消息/枚举、23 个源文件进行可重建检查；真正业务动作数仍按上面 35 个方法计算 |
| 被拒绝和错误的响应 | 上游 GrpcReq.request 优先读 grpc-status-details-bin 中的业务状态。原生现在按同一 bilibili.rpc.Status 描述符解码有/无 Base64 padding 的嵌套错误，保留实际业务码和消息。损坏或过大则退回 grpc-message；HTTP JSON 错误不会当作有效 protobuf 成功。只识别适当的状态类型，不展示无关 Any 数据，长度有上限。ServiceReceiptErrorTests 使用合成的 -352、-101、未知类型、非法数据和拒绝响应，没有发起验证挑战 |
| 账号与凭据 | 目标主机固定为 app.bilibili.com，不向重定向转发 RPC；请求前、只读重试前及收到回包后三次边界核对当前主账号、同一移动授权和当前设备标识。网页 Cookie 不代替要求移动授权的变更；所有写请求单次提交。只有本机自有安装标识或用户持有的有效设备标识，应用身份申明 PiliNative。没有使用其他客户端的签名密钥、代他人发令牌或制作指纹 |
| 签核证据 | Wire 包整体主机套件 25 项，21 项本地夹具执行、4 项需显式开启的公开读回跳过，0 失败；涵盖 64 位 ID、游标、不同 thread/session ID、发布/更新/撤回/已读、服务拒绝和嵌套错误。PiliWire 与实际 iOS 消费者已在 iPhoneOS 27.1 SDK 定点编译。既有公开只读结果见[动态协议](dynamic-protocol.md)；没有用真实账号发送消息或改动私有数据 |
| HTTP 反查发现的真缺口 | 固定上游 episode_panel/view.dart 的合集按钮会先查询 archive/relation.season_fav。以前只能在“我的订阅”取消订阅；现在从当前 UGC 合集也能直接订阅/取消。当前 BV 只用于查询关系，写入用 season_id 和 platform=web；顶层与合集编号冲突时不发请求。确认服务成功才切状态，“A 打开、B 接管”、拒绝、重复及冲突均有隔离主机验证 |
| HTTP 其他差异 | http-service-matrix.json 的 311 个固定常量分成：239 仅索引到字符串（不据此签功能）、26 个动作在原生组装同一端点、7 个换同站真实 HTTPS 服务、9 个官方账户页面接管、7 个包装虽引用常量但无可达操作、1 个自有客户端身份边界、1 个本轮补齐、21 个常量本身无业务引用。固定原版搜索遇到 v_voucher 实际直接返回“触发风控”；注册/提交挑战的调用已注释。原生显示拒绝，可由用户去官方页面处理，未实现规避。登录的短信/密码/安全中心在官方页面交互，移动令牌不能由网页会话自动签发 |
| 重复记录和边界 | 资料库 README 的“取消/订阅合集”已补上具体读/写消费者及证据；消息、评论、空间和动态页面仍分别由各自功能域签核。访问真实账号、人工登录/验证码与服务是否接受特定授权属于运行条件，不由静态端点存在推断 |

可复核：从 Native 运行 python3 Checks/service_protocols.py；python3 Checks/http_surface.py --reviewed-output dist/http-reviewed.tsv 可得到按原始 URL/常量、可执行引用、实际消费者、处置与理由分列的 TSV。bash Checks/personal_library.sh 运行合集身份/回执与既有资料库回归；在 Wire 包执行 swift test 运行协议夹具。本次未签名、未操作手机
