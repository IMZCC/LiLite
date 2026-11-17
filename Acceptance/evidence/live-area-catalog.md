直播分区对照：lib/pages/live_area、lib/pages/live_area_detail 及 lib/http/live.dart。目录走推荐账号，个人常用标签走主账号；按 lib/utils/app_scheme.dart，bilibili://livearea 打开直播首页，再由「分区」进入原生目录

- 原版 getAreaList 的 list → area_list 含「推荐」和跨父分区的标签。用每个标签实际的 parent_id/id 跳转；不能用当前栏目编号当父分区。按原生 iOS 请求参数匿名实读返回 14 组、497 个栏目项，包括重复推荐。网游分区独立的 getList(parent_id=2, need_entrance=1) 返回 116 项，其中「全部网游」id 为字符串 "0"；两种接口的数字、字符串 ID 都按同一规则读取
- 分区详情可切换同父分区的其他标签、看全部、搜索直播、切首帧，沿原有房间列表进入播放
- 我的常用标签从 get_fav_tag 读取，编辑中可添加、移除、拖动排序、保存清空后的列表，不能收藏「全部」。保存前重新读 service order；另一设备改过顺序时保留草稿、提示重新载入。set_fav_tag 只由点击完成发起一次；账号切换重置草稿。这里未向真实账号发送写入

iPhone SDK 类型检查：LiveAreaTags、LiveAreaCatalog、LiveViews、LiveAPI 和 AppLinkPage。公开读取校验在 2026-11-12 完成，数量是当时服务数据

直播观看记录：lib/pages/live_room/controller.dart 在已登录的观看记录角色、未暂停历史时调用 roomEntryAction。原生使用解析后的真实房间 ID，进入时核对本地开关和该观看账号的远程暂停状态，一次进入对同一房间和账号至多发一次，不由切清晰度/线路触发；没有向真实服务写入历史
