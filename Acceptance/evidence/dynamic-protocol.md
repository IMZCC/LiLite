# 动态列表协议核查

与固定版本对照的入口为 `lib/grpc/dyn.dart` 的 LikeList、RepostList 和 `lib/grpc/space.dart` 的 OpusSpaceFlow。Wire 消息由上游描述符生成。点赞的翻页同时携带页号和上页最后一位用户的 mid；转发保留服务端给出的字符串游标；图文列表保留 next 并区分作品和文集

WSL 的 Swift 客户端未使用账号凭据，从 UID 2 的公开图文接口收到两页响应，分别为 39,533 和 40,443 字节。第一页解出 20 条记录、无文集、有下一页；第二页非空，首条 ID 与第一页不同。此次公开账号没有文集，不能用于验收文集展示

同一核查读取点赞时服务端以 HTTP 200 / gRPC 2 返回业务错误 -352，未使用其他身份或绕过验证。这次线上流程在点赞请求结束，未对转发列表取得线上结论。本地独立字节样本验证了点赞翻页、重复游标终止和转发请求类型

运行离线检查：`bash Checks/run.sh`。单独运行只读网络抽查：`PILI_PUBLIC_SMOKE=1 swift test --package-path Wire --filter DynamicGatewayTests.testPublicSpaceAndActivity`。网络抽查按实际服务结果报告失败，不属于离线测试通过条件
