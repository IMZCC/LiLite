# 自适应卡片与桌面窗口边界

对照 style_settings.dart 的最大列宽设置：主页推荐与其他目录独立配置，范围均为 150–500，默认 240。原生网格按当前可用窗口宽度算列数，旋转、iPad 分屏或修改设置立即更新；辅助功能大字号固定单列。推荐保留「以下是上次推荐」的整行分隔，热门不误用首页推荐的宽度。影视索引、直播列表和创作者图文采用其他目录设置；已有分页、重试和下拉刷新保留。WSL 已编译 arm64。真实设备的横竖屏、分屏与大字号仍是最终验收场景

固定上游 lib/main.dart:199–215 只在桌面打开 WindowManager 并用 calcWindowBounds() 设置窗口；lib/utils/desktop/calc_window_position.dart:10 和 :41 分别读取像素宽高、桌面坐标。iPhone 应用没有可由应用移动或最大化的桌面窗口，这三个键与应用内横屏布局分开记录

播放器也有两套不同键：lib/plugin/pl_player/controller.dart:116 仅桌面会恢复 desktopVolume，play_settings.dart:222–235 将最高音量上限放在非移动端分支；移动端另设 playerVolume。排除这两个桌面开关不等于移动端播放器增益已验收
