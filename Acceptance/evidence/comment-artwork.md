# 评论头像、装扮与表情

基线为 lib/common/widgets/pendant_avatar.dart、emote_tooltip.dart、lib/pages/video/reply/widgets/reply_item_grpc.dart、lib/pages/emote/view.dart 与 lib/pages/live_emote/view.dart。Web 评论读取 avatar、pendant.image、vip 和认证信息；移动评论读取 MemberV2 并兼容旧 Member 的头像、挂件、装扮卡与编号。关闭装扮仅移除挂件和卡片，保留头像、认证及进入空间。上游默认开启装扮、关闭阅读时的表情预览；两项均可备份

评论正文的系统文本附件可点按或长按，点按时从实际字形矩形弹出图片、名称及服务提供的详情入口，动态文件按原帧时序展示。触发预览不会发表回复。评论选择器与直播选择器始终提供独立的长按预览，确认插入与发送分开。链接通过现有的内容识别或网页查看器打开。WSL Release 已通过 arm64 打包；文字选择和长按的真机交互、不同类型的实际装扮、动态图文及私信范围继续核查
