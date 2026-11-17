# 帧率与视频简介

使用服务 DASH 字段 width、height、frameRate/frame_rate 生成本机 HLS 主列表的 RESOLUTION 和 FRAME-RATE；支持小数、数值和 60000/1001 形式的帧率，不猜测缺失值。按 [Apple HLS 编写规范](https://developer.apple.com/streaming/hls-authoring-specification-for-apple-devices.html) 声明已知帧率。系统启用 iPhone 高刷，弹幕和动图库尊重屏幕可用刷新率；动图保留原始帧延时。主机检查 59.940、非法分母和负分辨率；匿名实测 BV1WEp8zwE6d 返回四种分轨、四种均有分辨率，帧率为 30 或 30.001。该片不作为 60 fps 真机播放样例

普通稿件显示发布时间、播放量、弹幕量，以及可关闭的服务争议提示。原生简介可以折叠，支持默认展开和仅横屏时展开。desc_v2 的 @用户、BV/AV 编号、时间戳、内容链接可分别进入空间、视频或定位当前播放器。显式展开/收起优先于旋转后的默认状态。WSL 已编译原生 Release 包
