# 分享链接中的连续播放列表

基线 `lib/utils/app_scheme.dart` 的 `playlist/pl<ID>?bvid=<BV>&page_type=4` 进入 SourceType.playlist。对照 `models/common/video/source_type.dart`、`pages/video/controller.dart:getMediaList`、`pages/video/medialist/view.dart`、`http/user.dart:getMediaList`。列表视频接口使用 type=3；独立收听入口使用 MEDIA_LIST、extra_id=4，分享参数 page_type 不能替代视频接口的 type。它不是 UP 投稿（type=1），也不是当前用户收藏夹

`SharedLink.sharedPlaylist` → `SharedMediaPlaylist(id:bvid:)` → `LibraryPlaylist`。打开后按合法 BV 还原 aid，以 `/x/v2/medialist/resource/list` 的 type=3、biz_id=列表 ID、oid=aid、with_current=true、desc=true、sort_field=1、ps=20 定位对应视频；读取服务分配的 CID。链接不包含任何写入权。网络请求使用当前主账号角色；本地记忆区分列表、主账号、播放、推荐和历史角色，换号退出原列表。没有为共享列表发送收藏夹编辑或 UP 投稿清单历史 POST

前一页与后一页按两端原始条目的 oid、otype 和 direction 请求。即使边界条目本身不可播放，也不会把其类型硬编码为普通视频。列表面板可以选择、倒序、依次播放或循环，并沿用全屏/内嵌展示方式。手动点按有合法 BV 但缺少 CID 的普通稿件交由视频详情重新读取；自动前后切换会跳过此类缺少可播 CID 的条目。未识别资源在面板保留但不可选。对提供明确 ep_id 的影视条目可进入原生剧集播放器；没有明确影视/视频标识时不把非视频游标当作 BV。若分享锚点已从列表消失，会显示原因，可显式选择从头开始，不会悄悄换播无关稿件

验证：`bash Native/Checks/creator_playlist.sh` 使用生产的双向游标和队列状态机、进程内服务，复核指定 BV/CID、上下页、type 24 边界、节目切换与全屏、无 CID 的手动定位、缺失锚点、反序、账号隔离、列表 ID 与收藏夹 ID 相同时仍不可写，清单相关外发写操作为零。既有 UP、合集、系列、收藏和稍后再看用例同时通过。新目的地、链接路由和队列源码已通过 iPhoneOS arm64 SDK 类型检查

实际服务：一次访客读取每周必看第一期以取得公开片单 ID，返回业务码 −352，未重试或换账号；没有记录本次访客的 type=3 在线成功响应。无账号写操作、未安装或操作 iPhone
