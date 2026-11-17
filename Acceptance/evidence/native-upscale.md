# Anime4K 原生播放层

固定上游 lib/common/assets.dart 的效率与画质预设，按原始顺序使用 assets/shaders 中的九份程序。Native/Tools/anime4k.py 将 hook、采样、卷积权重、绑定与条件转成 Anime4K.msl 和 Graph.json；Swift 按输出尺寸执行相应阶段，使用 Metal 的有符号浮点中间纹理，最后按所选画面比例呈现。资源与许可被打进应用，未嵌入 mpv 或 Flutter。发布检查逐字节比对 Metal 与图描述文件，并校验随包许可

普通投稿可以在当前播放器内手动切换，番剧与国创按服务的 season.type（1、4）应用默认值；内嵌/全屏沿用当前分集的选择。临时偏好模式不修改下一次播放的超分设置。渲染只消费系统允许显示的 AVPlayerItemVideoOutput，受保护片源、HDR 色彩或外接播放回到原画；没有可用帧、Metal 编译失败或内存预算不足时不阻断原本的播放

原图和转换后的核在 WSL 使用合成图像作逐像素比较，检查不同缩放率的阶段选择、临时纹理复用、权重和输出尺寸。两种预设共 10 组，实际执行 15 至 48 个阶段，先前结果最大 RGB 差约 0.004883、最大 RMS 约 0.001343。可用 PYTHONDONTWRITEBYTECODE=1 python3 Checks/anime4k.py 重跑。该组检查没有执行 iPhone GPU 着色器；真机还要核查低电量、帧率、色彩、外放与横竖屏切换
