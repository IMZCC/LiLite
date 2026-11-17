# 登录与账号重审

固定 d9e9626f1a3f89cd9ca85e18f61aaba02634e12a，按 lib/pages/login、lib/http/login.dart、lib/utils/accounts 与 lib/pages/{login_devices,login_log,coin_log,exp_log,log_table,space_setting,member_profile} 逐动作复核。机器核查表见同目录 account-messages-signoff.json

扫码保留刷新、保存二维码和官方 App 打开入口，也可显式复制到仅本机且过期自动清理的剪贴板。180 秒是客户端等待上限，服务端如先返回过期即停；仅在点击保存时请求照片库添加许可，不把二维码加入共享素材、日志或普通备份。手工 Cookie 和网页登录仍访问官方 nav 校验返回 UID，网页登录使用临时 WK 会话

2026-11-13 重审撤销此前的“发证方专属能力”结论：AppSign 只使用固定公开源码中的客户端参数、排序编码和 MD5，没有特殊证书或无法取得的远程签发服务。因此移动令牌获取与登录设备不能继续豁免，已作为正常客户端功能补齐

原生流程包含移动二维码申请/轮询、密码公钥与盐值 RSA 加密、全部上游地区码的短信登录、Geetest 人工验证、密码风险分支的短信验证及 OAuth 交换。网页登录、Cookie 登录和找回密码仍保留。Cookie 与移动令牌分别经过 nav/myinfo 的真实 UID 校验，同 UID 才一次写入钥匙串；取消、页面离开和中途切换账号不能迟到保存，重新授权可限定已有 UID

设备列表和 TV 取流复用同一正常客户端签名，真实服务拒绝不会显示成空设备或成功。Web、mobile 与纯本地 owner 的验证用途已拆开，过期移动令牌不再阻塞仍有效的 Cookie 功能与已确认归属的离线文件

具体源码、合成闭环、匿名公钥/二维码读回和 SDK 结果见[本轮账号核查](reaudit-2026-11-13-data.md)及[账号协议见证](account-grant-scope.json)。本轮不代用户发送短信、输入密码、扫码确认或执行真实账号内容写入；这些交互在真机清单中验收
