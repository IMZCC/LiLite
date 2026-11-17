# 推荐过滤偏好验收

基线 d9e9626f1a3f89cd9ca85e18f61aaba02634e12a，范围限这七个偏好的设置及数据筛选行为：最短时长、最低播放量、最低点赞率、标题表达式、应用于相关推荐、已关注豁免、热门和排行分区表达式

- 对照 lib/utils/recommend_filter.dart、lib/utils/storage_pref.dart 及 lib/http/video.dart 的 _filterHotAndRank、相关推荐接口。原版的黑名单优先于“已关注豁免”，相关推荐的黑名单独立于“应用过滤”。这是复核时发现并修正的一处差异
- 原生入口：设置 → 推荐过滤。保存时验证数字范围和正则并持久化；推荐、热门、排行、相关推荐在加载实际数据时调用同一套规则
- Checks/PortBehaviorCheck.swift 写入隔离的 UserDefaults 并重新读取，覆盖阈值等号、低于阈值、已关注、黑名单、各列表的时长/分区区别、表达式忽略大小写、关闭相关过滤仍屏蔽 UID、非法表达式不能覆盖原值。WSL 上运行 bash Checks/run.sh 通过
- 此记录不代替首页、推荐来源切换、分页接口、个人账号黑名单或 iOS 点击交互各自的验收
