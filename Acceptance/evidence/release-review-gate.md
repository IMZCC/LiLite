# 冻结源码、执行收据与开发包验收

基线固定为 d9e9626f1a3f89cd9ca85e18f61aaba02634e12a。完成结论独立保存在 Acceptance/final.json，不能靠填写 passed 跳过源文件、具体领域、执行记录和实际 IPA 校验

## 签名前

先提交全部代码、检查程序和证据，再在 WSL 的 Native 目录针对同一完整 Git 提交执行：

```sh
python3 Checks/review_receipts.py capture host --revision <40位提交>
python3 Checks/review_receipts.py capture media --revision <同一提交>
python3 Checks/review_receipts.py capture unsigned --revision <同一提交>
```

三种收据默认位于 dist/final-review，均可用 --artifacts 指定同一目录。host 真实执行 Checks/run.sh；media 包含转封装、视频/音频解码、音画时钟、目录事务、备份恢复、ASS 字幕光栅和超分辨率检查；unsigned 真实构建 --release-personal，逐项核对包内容、源码修订及普通开发配置

每次捕获比对运行前后的工作树和 Git 对象，包含源代码、资源、原生依赖、构建脚本、检查及证据，不允许漏掉新源文件或以 symlink 指向其他位置。失败时保存 failed.log 且撤销同类旧收据。成功收据绑定执行命令、成功退出标志、完整日志 SHA-256；未签名收据还绑定独立保存的 IPA SHA-256

可用以下命令生成仍为 pending 的审查草稿，不会替审查者签收任何领域：

```sh
python3 Checks/review_receipts.py draft --revision <同一提交> > dist/final-review/final-draft.json
```

final.json 的 sourceRevision、fingerprint、三个 receipts 摘要与所有 14 个领域的指定证据必须匹配。结论文件本身不进入源码指纹，因此可以在代码审查后单独提交结论；修改代码、检查、资源或证据则必须重新捕获，只有改结论不会使两个 Git 提交的实现不同

```sh
python3 Checks/parity.py --client-complete --artifacts dist/final-review
```

该命令与 `--complete` 使用相同的严格完成规则，不允许任何 partial/pending 例外。2026-11-13 重审撤销此前两类“发证方事项”：原版 AppSign 所需客户端参数及算法就在固定公开源码内，移动登录、设备列表及投屏签名均须等价实现，不能用缺少特殊签发身份作为豁免。source-note 只允许固定 README 的 120/136/141 三条裸行，并核对原文、章节、没有子项和 Git blame 来源；不能将具体功能改成备注

## 签名后

```sh
python3 Checks/parity.py --verify-delivery --artifacts dist/final-review \
  --ipa <已签名IPA> --ipa-sha256 <完整文件摘要> --device-id <目标设备UDID>
```

签后重复签前审查，并实际检查开发包：SHA-256、原生 arm64 iOS 17、开发 profile/有效日期/目标设备、代码页和资源签章、签发证书属于 profile 授权并在有效期、普通权限配置和 keychain 组匹配。profile 的 CMS 必须链到本仓库固定的 Apple 官方根，且证书包含 profile 签发用途。整个主包与已审的未签名包逐项比较，仅规范化由签名增加的 Mach-O 区域与单独校验过的来源/构建时间字段，不允许替换业务代码或资源

xtool 为个人团队签名时会将原 bundle ID com.liuliuya.PiliNative 加上 XTL-<签名团队>. 前缀。未签名包只接纳原 ID；签名包先验证真实代码/资源签章、profile 与签发证书，再从签名 entitlement 和 profile 核对同一团队，只接纳原 ID 或该团队的精确前缀形式。还须核对 application-identifier、ApplicationIdentifierPrefix 及 profile 授权模式。签后主包对比仅在这些身份验证完成后把主 Info.plist 的已知团队前缀恢复为原 ID，其余字段仍逐项比较；错团队、其他应用名、未签名却带前缀均拒绝

Apple 根的来源与固定摘要见 Checks/trust/README.md。系统信任库未被修改。最后是否允许安装及运行仍由设备上的 iOS 执行；本检查不尝试替代其联网撤销策略。所有检查都是读取或本地计算，不调用安装、签名、账号服务或外部文件写入接口。frozen.sh 的临时 checkout 如需使用已有收据，可显式设置 PILI_REVIEW_ARTIFACTS 为原收据目录，摘要和源码仍逐一核对

## 本轮本地验证

Checks/ReviewEvidenceCheck.py 使用临时 Git 仓库验证同源码的结论提交、跟踪/未跟踪输入变化、目录链接；对日志变动、漏执行步骤、过期指纹、空白账号见证、错误领域证据、扩大例外、错误设备和越权 keychain 组拒绝；合成 Mach-O 只允许签名区域变化，改代码或非零头部填充会失败。另只读检查早期保存的实际签名 IPA，Apple profile 链、当前开发签发者、profile 所列设备与代码/资源签章都通过，修改 CMS 被拒绝。没有生成新签名或操作 iPhone

2026-11-13 补核：10 组本地回归均通过，含上述团队前缀正例及错误团队/应用名/未签名误前缀负例。早期保存的实际签包与本轮 xtool 暂存的新签包均沿真实签章/profile 检查身份。新暂存签包完整通过 inspect_ipa --signed --discovery personal，再经 review_delivery 与原冻结的 unsigned-personal 包逐项对比，Apple 根链、当前开发证书、目标设备与完整包摘要通过，没有输出设备编号。此回读验证定位签名时的合法 ID 变化；代码检查程序已修订，最终交付仍须按新源码重新捕获收据并审查，不能复用旧指纹作为新版本的交付结论
