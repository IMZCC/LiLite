# 设置与 WebDAV 数据迁移

以下是初次迁移的记录。后续新增的加密、分项导入、失败回滚、角色归属和真实环回 WebDAV 验证见[备份与恢复二次核查](backup-restore-audit.md)

基线：PiliPlus 2.2.0.2，lib/utils/storage.dart:80、lib/utils/storage_key.dart、lib/utils/storage_pref.dart、lib/pages/webdav/webdav.dart:27–113

- 原版设置 JSON 有 setting 和 video 两个盒。映射表分别处理布尔、整数、倍速数组和枚举，不把 1 当成 true。恢复只覆盖能对应的设置；未映射的原版项在确认时计数。兼容第一版原生设置 JSON
- 备份保留原生专有设置；更新同一个远端文件时保留原版未知键，但不把未知键、密码和账号会话复制到另一个服务器。对旧版备份的所有模型校验与可抛出的序列化在修改当前设置之前完成
- 服务器模式按目录创建 PiliPlus/piliplus_settings_phone.json 或平板的 pad 文件。旧的完整 JSON 地址仍可用。HTTPS 不跟随重定向，按服务器地址及用户名保存钥匙串密码，不用 B 站账号的 Cookie 或系统默认凭据
- Checks/BackupCheck.swift 在 Linux 运行同一套 Swift 迁移和 WebDAV 状态逻辑：验证旧版往返、原版枚举和键名、未知字段、目录与普通文件区分、建目录竞争、条件创建、服务器 412 冲突和只读恢复。请求由测试传输记录，不需真实用户密码或远程写入
- WebDAV 页仍列部分完成：未对真实 WebDAV 用户端点、钥匙串和 iPhone 文件选择器实测；设置映射范围以 BackupFormat.fields 为准。原版本地完整 ZIP 数据包另有独立格式，不能用设置 JSON 代替

## 本地完整数据包

基线另见 lib/utils/config_archive.dart、lib/utils/accounts/account.dart、lib/utils/font_utils.dart，以及 lib/common/widgets/dialog/export_import.dart。该路径使用 ZIP，不经过 WebDAV；iOS 端可以选择要迁移的数据，登录凭据默认不选

| 成员 | 导入与导出 |
| --- | --- |
| meta.json | 校验 data_archive 类型、主版本 1、文件清单，手机和平板分别标记 |
| setting.json | 共用设置格式和校验，黑名单独立选择 |
| search.json、blacklist.json | JSON 字符串列表、UID 数组，恢复到实际搜索与推荐筛选使用的存储 |
| reply.json | 对照原版 ReplyInfo 的 Proto3 JSON；合并至所属账号的本地评论，不发帖 |
| account.json | 按 UID 合并 cookies、accessKey、refresh、buvid 和角色，持久化到钥匙串；保留已有账号，只有勾选登录账号才会导出或合并凭据 |
| customFont.otf | 传输字体字节，导入时交给 Core Text 注册，使用实际可用的字体名 |

ArchiveKit 测试使用 Python zipfile 生成的压缩输入，反向用 Python 验证 Swift 的导出、CRC 和元数据；另验缺少清单成员、合成账号 UID 不一致及角色冲突。没有读取本机的真实账户来做测试。原版 ZIP 带来的账号角色记录保留在本机，是否用于每类请求仍要在账号模块逐项核验
