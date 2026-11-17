固定来源：lib/utils/app_scheme.dart、lib/utils/page_utils.dart（pushDynFromId）、lib/utils/reply_scheme_helper.dart 与 lib/http/user.dart

- AV、BV 和文章/动态分享同时携带评论定位时，先保留原资源、分 P、CID 和开始时间，再用已加载内容的评论编号与类型打开指定根楼和子楼。关闭评论返回原内容，并可在视频页继续使用当前播放时间。动态的评论类型为 12 时进入图文阅读器，其余保留动态详情。相册 rid 按 type=2 请求，不拿它冒充动态 ID
- 通知链接按真实 following/detail 的动态 ID 打开；原生 comment/msg_fold 的 11/12 型区分主题 oid 和 enterUri 内的动态 ID，17 型直接定位动态。非可信 enterUri 不用于打开网页。h5/comment/sub 使用自己的 pageType。视频弹幕进度提前三秒，保留 CID
- MA 音乐编号保留前缀，h5 投票保留动态 ID；播放列表保留片单和起播 BV；粉丝、关注及其关注者、直播主页、赛事数据、笔记、相册及受限创作者资料各自进入相应页面。应用网页链接由用户先确认域名；原生解析只识别限定域名与协议
- 创作者公示仅在显式操作后向固定官方端点请求当前主账号获准展示的数据；服务拒绝时显示拒绝说明。未以真实身份请求个人资料，未模拟官方客户端的签名凭据
- Checks/ContentContractCheck.swift 与 Checks/im_notice_actions.sh 使用真实解析器回归（包括多组恶意或歧义输入以及通知 subject_id 不同于动态 ID）；相关界面在 iPhoneOS 27.1 arm64 类型检查通过
