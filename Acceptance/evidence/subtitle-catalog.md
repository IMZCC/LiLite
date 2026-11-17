# 字幕目录与默认选轨

基线：lib/models/common/video/subtitle_pref_type.dart、lib/models_new/video/video_play_info/subtitle.dart、lib/pages/video/controller.dart 的 _setSubtitle 和游客 DmView 路径

原生播放器按服务语言和 AI 标记整理字幕。中文优先，同语言组人工优先，保留等价轨的返回顺序；选轨使用轨道 ID，兼容旧离线字幕的语言标识。进入点播、剧集、课程或离线文件时，根据用户偏好及系统输出音量选择首轨。详情和全屏可以手动覆盖，切集后取消旧读取，迟到的字幕不能覆盖新集。设置支持原版整数索引 0–3 的备份映射

游客在 Web 成功但无可用字幕时，再向原版 DmView 读取对应 aid/cid；使用固定上游描述符生成的 SwiftProtobuf，游客请求不带身份。主机回归检查四种默认策略、AI 音量分支及 DmView 帧中两个 ID 的位置。匿名访问两组真实 ID：av170001/cid279786 与 av455017605/cid168409646 均返回 HTTP 200，解出空字幕目录。包含真实字幕文件的游客样本、登录后轨道、真机静音切入仍列入最终验收
