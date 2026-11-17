# 接口代理

固定上游 lib/http/init.dart 的 _createPool 通过 enableSystemProxy、systemProxyHost 和 systemProxyPort 为请求连接池指定 HTTP CONNECT 中继。原生设置中的「网络连接 → 接口代理」分别填写主机及端口，启用后使用 iOS 的 ProxyConfiguration(httpCONNECTProxy:)。关闭时继续使用系统当前网络设置。这里只覆盖哔哩哔哩接口、扫码登录的新会话和远程图片会话；投屏接收器、用户的 WebDAV 及实时弹幕直连通道各有自己的网络实现

普通请求与移动端接口共用 BiliAPI 的当前会话；设置变化后尚在传输的请求可结束，新请求使用更新后的配置。图片的无缓存和公开图片缓存会话同步切换。对目的站仍按系统信任链校验 HTTPS。恢复文件或 WebDAV 备份时，若将启用代理，确认文本显示主机与端口。三个原版键能往返备份，支持主机、IPv4、IPv6；端口限 1 到 65535，不接受带协议、路径、账号密码的地址

主机检查覆盖 IPv6 恢复、端口正规化和非法地址，iOS SDK 编译检查应用的公共 API。没有更改现场设备的代理，也没有将实际账号或媒体流量发送到测试中继。最终需在用户自己的代理和 iPhone 上分别测量启用、切回与接口响应
