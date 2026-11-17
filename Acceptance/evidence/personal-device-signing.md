# 本机开发签名与投屏

固定标识 com.liuliuya.PiliNative。已保存的早期实机开发包包含配套设备描述文件；只检查权限和到期日，未输出证书、密钥、设备编号或账号。该描述文件不含 com.apple.developer.networking.multicast。这个权限不能由应用自行添加

- 完整组播构建使用 SSDP，包括原版电视发现和离开通知。个人签名配置只在暂存目录移除受限 entitlement，同时将打包 Info.plist 的 PiliMulticastDiscovery 置为 false。普通签名使用已列入 NSBonjourServices 的指定 DNS-SD 类型，只接受解析到的局域网终端自己公告的描述地址；不把任意组播或网段扫描当作替代。手动 XML、控制、中继及系统 AirPlay 在两种配置均可用。仅支持传统 SSDP 的电视，使用普通签名时需手动连接。[Apple TN3179：本地网络与组播](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)
- 测试实际生产地址解析，含相对路径、同机 mDNS 别名、更换了端口的公告、异机 URL、文件地址和未提供描述位置的 UDP 服务；随后原先的 87 次模拟电视 SOAP 交换、整文件与跳转逐字节仍通过。NetService + CastDirectory 通过 iPhoneOS SDK 类型检查。没有搜用户真实局域网或连接电视
- 签名后用 openssl 验证描述文件 CMS；另验主程序代码目录的 detached CMS 签名，签发者证书必须属于该 profile 授权项，逐页校验 Mach-O、Info.plist、资源清单和签名 entitlement，按清单核对资源。普通/完整包的实际授权与 Info 必须吻合，开发身份及到期日分别检查。对本机早期真实有效签名回读通过；在内存中替换可执行字节、包元数据或签发者名单均被拒绝。认证链及设备安装策略最终由 iOS 执行
