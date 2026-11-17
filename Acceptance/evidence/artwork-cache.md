# 图片缓存空间

对应 lib/utils/cache_manager.dart、lib/pages/setting/models/extra_settings.dart 及关于页的清理入口。原生设置接受 MB 数值，保存为字节，默认 1 GiB。图片缓存可查看磁盘及内存用量、改变上限、清理或设零关闭；离线下载和用户文件不在此目录

首页等列表缩略图、相册预览、头像、评论表情、直播表情及醒目留言配图使用统一加载器。请求不附带 Cookie，只有无签名参数的公开图片 CDN 使用独立 URLCache，其余走无磁盘缓存的会话。HTTP 响应要求 200、图片类型、无 Set-Cookie 且没有 private / no-store，缓存的新鲜度仍由 HTTP 处理。保留不同场景的解码尺寸和字节上限。原图导出与实况照片仍走相册文件流程

使用上游公开稿件 av170001 的封面作只读验证：i2.hdslb.com 返回 200、image/jpeg、10,755 字节和 max-age=31536000。主机策略检查缓存许可、private/no-store、签名查询、伪装主机和 Set-Cookie。iOS 沙箱真实磁盘回收及离线再次查看在完整验收中验证
