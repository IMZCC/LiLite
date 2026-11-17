# 视频截帧与全屏锁定

上游 README 的「视频截取动图」、lib/plugin/pl_player/controller.dart 的 screenshot，以及 lib/utils/storage_pref.dart 的 showFsScreenshotBtn / showFsLockBtn 是本项对照依据

普通视频、剧集与已下载视频共用截取面板。静态图取当前播放帧，以 PNG 保存；GIF 按真实媒体时间采集 1–10 秒，支持选择帧率、预览、系统分享及写入相册。暂停不增加录制时长，跳转或更换播放项目会停止原任务；受保护内容不采集。全屏锁定后隐藏播放控件并拦截操作，仍保留解锁入口

WSL 行为检查覆盖帧间隔、暂停、播放位置倒退、跳转和结束边界。xtool Release 已生成并检查未签名 arm64 IPA。待最终设备验收：不同视频方向、音视频分轨及离线文件的画面，实际 GIF 回放、相册授权及全屏解锁交互
