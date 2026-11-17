# iOS 图片保存位置与离线缓存

固定上游 lib/main.dart 的 _initDownPath 只在桌面读取 Pref.downloadPath，lib/pages/setting/models/extra_settings.dart 的目录选择也在 isDesktop 分支；iOS 使用 defDownloadPath。imageSavePath 只在 storage_key.dart 定义、storage_pref.dart 声明 getter，没有调用者。原版移动端的图片/截帧由 lib/utils/image_utils.dart 经照片图库保存

原生实现额外提供 iOS「文件」选取方式。SwiftUI 文件夹选取器返回的目录在授权范围内通过 NSFileCoordinator 读写，保存 minimalBookmark 而非绝对路径；每次访问配对 start/stopAccessing。书签单独存在 Application Support 的受保护目录，排除系统备份，也不读写 PiliPlus 的设置备份、WebDAV 或数据包。设置恢复不能授予目录访问权。依据：[Apple：Providing access to directories](https://developer.apple.com/documentation/uikit/providing-access-to-directories)

- 图片与实况：默认仍保存到系统照片，可在「图片与实况照片 → 图片保存位置」改到指定文件夹。当导出到文件夹时不会请求照片图库权限。原图保持下载文件字节；多张导出到一个新目录，实况照片共享配对标识的 JPEG 和 MOV 在同一目录内一次发布，已有名字会选下一个名字。视频截帧和 GIF 使用同一选择。用户可以恢复系统照片
- 缓存：目录选取只改变新缓存的目标；已有缓存显示其实际位置，用户可另行移动。系统后台下载始终先在应用目录落盘。转入目标之前比对完整媒体文件、字节数、SHA-256 和分集代次；索引持久写入新位置之后才清理原件。授权失效、外部磁盘离线、文件内容被改动或出现外加文件时保留原件及重试记录。针对复制中断、已发布但没有更新索引、清理中断分别有恢复路径。应用回到前台会重试，用户也可手动重试
- 读写与容量：索引保留在应用里；主媒体的唯一权威位置按分集保存，迁移后可从该目录读取并在应用内建立限时播放快照，播放结束释放。字幕、弹幕保存在应用目录。容量按实际主媒体文件、迁移暂存和字幕/弹幕分别计入相应位置，无法读取的文件夹不会被报成零占用。删除只处理对应缓存代次命名规范内的文件，外部删除失败保留索引。迁移中同名请求或删除不能使旧任务覆盖新代次
- 番剧/课程继续要求同一个取流账号、服务允许离线、无 DRM 和非预览媒体。此类文件在外部只发布 .pilicache 缓存包；AES-GCM 分块认证绑定原账号、代次、轨道、块序和长度，密钥来自仅此设备的钥匙串。恢复中发现已提交的包，会校验解密后的内容与原件一致再释放原件；不会导出账号密钥。纯软件在线解码支持的格式不混入离线 AVFoundation 轨道选择

检查：运行 bash Checks/storage_locations.sh。覆盖同名原文件保留、成组导出、失败不发布、两轨缓存复制重放、篡改与外来文件保护、恢复中断的清理与复制、暂存容量。以原生封装源码测试三个实际密码块的往返、不同随机密文、错误账号/密钥、篡改、截断和块调序；WSL 宿主使用固定 Apple swift-crypto 3.15.1（仅检查使用），iOS 使用系统 CryptoKit。相关 iOS 源已在真实 Release SDK/SwiftUI 宏环境下做独立类型检查。尚待完整设备验收的有 iCloud/第三方文件提供方断连与重新授权、锁屏后的后台任务、实况导入照片、存储不足和真实账号切换后的播放
