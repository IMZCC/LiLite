# 图片与 Live Photo

固定原版数据契约为动态 OpusPicModel 和专栏 Pic 的 url/src、live_url；lib/common/widgets/image_grid、lib/common/widgets/image_viewer 负责同组浏览，lib/utils/image_utils.dart 定义预览质量和单张、整组、实况保存。原版依赖 live_photo_maker 0.0.6；核对了 pubspec.lock 中的包 SHA-256。原生工程直接使用 ImageIO、AVFoundation 和 PhotoKit，没有引入该 Flutter 插件

- 动态、文章和评论从点击的图片进入整组；实况开启时预览配套视频，关闭时仍可看静态封面。长图可纵向滚动，普通图片可捏合或双击缩放，动图按帧延时显示。横屏面板、缩略图长按、静默保存及两种质量值均可配置
- 列表和大图只在支持的站内 CDN 地址应用质量参数。B 站公开样片 170001 的封面实读：原图 HTTP 200、JPEG、120 × 90、10755 字节；10% 版本 HTTP 200、WebP、120 × 90、640 字节。原图保存和分享不使用降质文件
- 点击保存实况时，用同一标识写入 JPEG 和 MOV，在 MOV 中写入定时封面标记并保留音轨与方向；不兼容直接封装时转码后重试。由 PHLivePhoto 检查配对资源，然后通过一次相册写入添加 photo 和 pairedVideo
- Linux 端实际运行了多图块解析、url/src 与 live_url 分离、协议规范化、已有尺寸后缀及原图回退规则的检查。iOS arm64 Release 编译通过；Linux 无 PhotoKit，实况相册导入和真机回放仍须在最终设备验收时检查
