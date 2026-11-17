对照 lib/pages/sponsor_block、lib/pages/video/introduction/ugc/view.dart::buildDesc、lib/pages/video/post_panel 及 lib/http/sponsor_block.dart。设置可选择服务器及其单独的贡献身份，显示状态、统计、各分类的颜色、最短时长、跳过策略、提示和可选统计；播放中的片段定位、手动与自动跳过、投票和投稿沿用该服务器。设置中的“关于空降助手”打开上游项目

新核对的原视频绑定：启用空降助手并在当前分 P 的简介点 YouTube 链接后，以同一 BV/CID 查询 portVideo。对已绑定、尚无绑定和读取失败分别显示；可以始终打开原视频。只在用户确认绑定时按原版 POST bvID、字符串 cid、ytbID、对应服务器的 userID 和四舍五入到秒的 biliDuration。收到 UUID 才显示成功；不发送 B 站账号凭据，切换分 P、服务地址或关闭功能会丢弃旧绑定页面

Checks/PortBehaviorCheck.swift 核对用户实际点击的 11 位编号，排除冒名域名、重复 v 和错误的媒体上下文；还包含同一 CID 分段跳过等已有用例。非 B 站外部简介网址遵守网页打开设置。arm64 iPhoneOS SDK 类型检查通过。没有向空降助手测试投票或写绑定
