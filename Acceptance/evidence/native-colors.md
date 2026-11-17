原版固定 theme_color_type 索引对应 19 个预设色，也可直接保存任意选择的 ARGB。原生支持全部预设、系统选色器、浅色与深色、21 个 FlexSchemeVariant 索引与旧原生强调色迁移。Flutter 主题组件改为 iOS 原生按钮、侧栏与导航；主色、选中填充、频道与导航背景分别使用其对应的调色板角色。备份中的 customColor/schemeVariant 保留原数值。旧原版 iOS 从未提供系统壁纸取色（lib/utils/storage_pref.dart:741–743），这里可跟随原生系统强调色

颜色运算为 Apache-2.0 的 Google Swift MCU 与固定 BSD-3-Clause FlexSeedScheme 5.0.1 的调色规则；应用包携带两份许可。Checks/theme_colors.sh 在 Linux 用同一份 Swift 源码比对固定 Dart 测试中的 16 个独立预期颜色，以及 19 种预设 × 21 种风格的浅深模式，不依赖屏幕截图。UIKit 的高对比辅助功能与实机外观仍属于最后的交互核查
