# Android 私有目录提供程序

固定上游 lib/pages/setting/models/extra_settings.dart 第 55–63 行只在 Platform.isAndroid 时提供 enableDocProvider，直接调用 AndroidHelper.updateDocProvider。对应 AndroidHelper.java 修改 Android 包组件 BiliDocumentsProvider 的启用状态；该组件继承 android.provider.DocumentsProvider，给第三方文件管理器提供本应用的私有目录

iOS 版没有这个 Android 组件或相同的全沙箱授权。原生已允许通过文件选择器导出设置、通过系统分享面板分享用户选择的媒体，不向外暴露账号存储。此排除仅针对 Android 组件开关，不覆盖离线下载、图片保存或文件导入导出需求
