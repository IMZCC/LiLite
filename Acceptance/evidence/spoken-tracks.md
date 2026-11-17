# 原声和 AI 配音

固定上游的 0745d83e4 引入「AI 原声翻译」。对照当前 lib/models/video/play/url.dart、VideoDetailController.setLanguage 和 lib/http/video.dart，原版展示服务发布的 language.items，用 cur_language 请求对应的整套视频/音频清单。它不会在用户设备上合成他人的声音

普通稿件、番剧、课程和自定义全屏播放器都显示服务实际提供的语言。语言列表去重、中文在前，同语言组中保留原声优先；production_type 为 2 时注明 AI。切换需当前视频取流账号，服务返回的语言要匹配选择。成功解析新分轨并准备好本机桥接后才替换原播放器项目；保留画质优先、进度和暂停状态。切音质和切字幕仍为独立操作

主机已执行中外语排序、AI 标注和重复语言样本。WSL 匿名读取 BV1WEp8zwE6d 得到可用 DASH，但该响应返回 0 个可切语言；没有将其算作实际听到两种配音。可用 PILI_SPOKEN_TRACKS=<BV号> bash Checks/public_services.sh 复查公开响应。最终验收仍需服务实际授予多音轨的账号及内容
