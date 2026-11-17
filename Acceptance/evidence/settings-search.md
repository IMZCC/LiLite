设置搜索基于 lib/pages/settings_search/view.dart 的行为（查找标题/说明、找到对应的控件），原生使用 iOS 搜索栏和可定位的结果行

- 搜索索引从实际 SwiftUI 控件的 settingAnchor 重建，不靠分类名称猜测。312 个锚点对应设置页或子面板内的具体位置，结果打开原控件并定位，修改沿用该控件的现有保存/取消逻辑。Wi-Fi 和蜂窝分别打开自己的画质设置；仅蜂窝拥有“与 Wi-Fi 相同”
- 除原生标题和分组外，还比对固定上游的设置标题、说明和存储字段。显式登记的布尔值、数值及两项音频同步偏好可按当前值查找；未索引账号授权、WebDAV 密码或用户自己保存的屏蔽词。支持多个词组合、全角/半角、大小写。没有匹配时显示系统的空结果视图
- Checks/setting_search.sh 检查索引与真实控件的一一对应，并在隔离 UserDefaults 测试：用“自动同步”和“ＭＰＶ 视频同步”查找、按非默认平滑值和即时开关状态查找、蜂窝独有选项。开发时 python3 Checks/setting_search.py --write 更新锚点；python3 Tools/SettingsIndex/terms.py --write 使用工具链自带的 SwiftSyntax 和固定上游 Dart 重新提取同义词
- 39 个相关 Swift 文件与队列/笔记调用点的 arm64 iPhone SDK 类型检查通过。页面内条件未满足的设置仍遵守原显示条件；动态字体、屏幕阅读器与真机滚动焦点列入最终验收
