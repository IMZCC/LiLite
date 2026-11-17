# 播放进度预览与热度

基线：lib/http/video.dart 的 videoshot、lib/plugin/pl_player/controller.dart 的 updatePreviewIndex，以及 lib/pages/video/controller.dart 的 _getDmTrend

使用公开样片 BV17x411w7KC（aid 170001、cid 279786）读取游客接口，两份响应均为 HTTP 200。视频快照有 121 个时间戳，前两个为 0，随后是 7、13、16；单格 160 × 90，每张拼图为 10 × 10。实际读取的两张 JPEG 均为 1600 × 900。热点接口返回 modules[0].params.data，步长 3 秒，共 68 个样本

在 WSL 将两个未经改写的 JSON 文件传给 Checks/run.sh，Swift 解码器核实头尾对应不同的拼图并生成热度列。固定用例另外覆盖精确边界、换行、换图和合并热度峰值。图集不随仓库发布，普通离线测试也不要求联网

原生进度条、横滑和全屏时间轴共用一份预览状态。首次拖动后才请求拼图；切换视频或分 P 取消旧任务，热度图按设置读取。已通过 iOS arm64 优化编译，实际拖动显示和系统全屏交互留到整体验收
