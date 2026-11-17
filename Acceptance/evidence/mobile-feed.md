# 首页移动端推荐

对照 VideoHttp.rcmdVideoListApp、RcmdVideoItemAppModel 和 App/Web 两种来源选择。Swift 首页默认请求 app.bilibili.com/x/v2/feed/index，使用 iPhone 的客户端参数；仍可切换网页版接口。按推荐账号读取，按服务端 can_play、广告字段和内容类型过滤，使用 player_args 的实际 CID 和时长、args 的作者和分区、推荐原因和关注状态。播放数和弹幕数识别万/亿单位。卡片仍经过设置中的本地推荐筛选

长按卡片时，不感兴趣/反馈项来自该条卡片实际下发的菜单；显式点按后向推荐账号的反馈接口提交，仅成功时移除，撤销成功才恢复。未向用户账号提交测试反馈

PILI_MOBILE_FEED=1 bash Checks/public_services.sh 在无 Cookie 条件下实际读取两次：分别 8、8 条可播放卡片，16 条不同内容，均返回理由菜单。原生 Release 已编译，既有主机行为检查通过
