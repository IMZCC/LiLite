对照 lib/pages/video/member/controller.dart、view.dart、lib/pages/member/view.dart 和用户投稿的两种官方列表

横屏打开作者时保留原播放器。侧栏先定位当前 BV 的投稿位置；最新发布 / 最多播放分别按 sort_field=1/2，使用列表首尾的 AV 请求前后窗口，去掉重复边界，支持返回 UP 主完整空间。在侧栏选择投稿时携带该集 first CID，关掉侧栏并切换当前 DetailView，不叠放另一个播放器；横屏离开、账号切换会取消旧的加载

该固定版的移动端 archive/cursor 用原生 iOS 参数访问返回 -400。在同一项目的 member_video → video/controller → UserHttp.getMediaList 中有公开的上传稿件列表：type=1、biz_id=作者、oid=当前稿件、otype=2、with_current、direction、desc。2026-11-12 匿名实读该列表：同一稿件定位到响应第一项，取到 20 项和下一页；向前请求的 5 项索引连续，发布时间从新到旧、按播放量的另 5 项则按播放数递减。页面没有遍历整个作者历史来找当前视频

空间资料和横屏侧栏的粉丝/关注数量直接打开该人的列表，使用 /x/relation/stat；获赞只在登录时请求 /x/space/upstat，缺值时保留服务已有的空间资料。已关注用户在本人账号的关系菜单中可查看 /x/relation 的 mtime。没有查询本人的私有关系、变更关注或向真实账号写入历史

本次 iPhoneOS 27.1 SDK 已检查带侧栏的 DetailView、CreatorVideoPanel、CreatorSpace、空间资料和关系模型。用户手势、横竖屏及屏幕阅读器联动仍在最终设备验收范围
