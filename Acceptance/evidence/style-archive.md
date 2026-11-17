以固定上游 lib/utils/storage_key.dart 的字符串字面值为准。原来的 alwaysExapndIntroPanel、exapndIntroPanelH、showDynDecorate 均按实际拼写导入导出；此前原生版导出的拼写仍可读

navBarSort 是“首页、动态、我的”三个索引，defaultHomePage 是原枚举编号，不是所选列表内的位置。默认栏目被隐藏时回到首个可见栏目。tabBarSort 是“直播、推荐、热门、分区、番剧、影视”顺序的索引数组。原生版额外的搜索标签不会冒用上游编号；恢复自己导出的双格式备份时保留搜索标签及位置。appFont 区别系统字名与原版以斜线标记的字体文件，文件只由完整数据包的字体选项恢复，不能把备份字符串当本地文件打开。textScale、appFontWeightV2 另外映射原始倍率及字重

cacheVideoFit 的九个枚举与 lib/plugin/pl_player/models/video_fit_type.dart 依次对应：拉伸、自动、裁剪、等宽、等高、原始、限制、4:3、16:9。原生播放器改变画面矩形，字幕、手势和播放按钮仍使用视口坐标；正常与全屏共用镜像状态。竖向媒体默认把储存的拉伸视为自动，可在播放中再手动设为拉伸。系统单独接管的播放控件和画中画保留 AVKit 支持的画面表示。Checks/PortBehaviorCheck.swift 测试方形/竖形/强制比例、保留尺寸与下限；Checks/BackupCheck.swift 验证隐藏后的默认栏目、仅原生搜索标签、时间/字号单位和原版拼写
