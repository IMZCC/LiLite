这五个偏好已按固定版本逐条核查。设置界面的输入、保存和原版备份键在 ReplyFilterPanel、ReplyFilterRules、BackupFormat 中；实际生效处是 Discussion 对 gRPC 主楼、楼中楼、预览以及 HTTP 评论列表的筛选，不是只在设置页面保存开关

| 原版键 | 原版判断 | 原生行为及回归证据 |
|---|---|---|
| antiGoodsReply | reply.dart 中 goods_cm_control=1、goods_item_id/goods_prefetched_cache 的字段存在性，或正文商品 URL | HTTP/gRPC 进入同一过滤器。特别修复 protobuf 零 ID/空缓存也有字段存在性；ReplyGatewayTests 直接用两组线上的字段编码形式检查解码和再次编码。PortBehaviorCheck 覆盖商品标记、链接及普通文本 |
| blockAtOnlyReply | 映射须非空，图/表情不算纯 @，嵌套回复只看冒号后，逐一比对 @用户名 | 覆盖连续 @、嵌套、未知名字、带文字与含媒体；不是简单找一个 @ 就过滤 |
| blockReplyAtCount | 提及的映射条数大于或等于阈值，null 关闭 | 保留 0、相等边界、未设置三种语义，设置留空恢复 null；夹具验证 3 个不同名称 |
| banWordForReply | 非空正则，忽略大小写 | 编译检查再保存，带大小写和数字的规则命中，普通文本保留 |
| filterIntro | 对上层视频评论比较去除首尾空白的正文与简介，二级预览不传简介 | 两端分别修剪；主评论接入视频简介，子回复、普通动态没有简介；夹具验证前后空白 |

基线：lib/grpc/reply.dart:31–104、lib/pages/common/reply/reply_controller.dart:149–160、lib/pages/video/introduction/ugc/controller.dart:138。原生规则不发账号写请求
