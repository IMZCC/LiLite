# 离线、听视频与系统媒体最终分项

固定版本：PiliPlus d9e9626f1a3f89cd9ca85e18f61aaba02634e12a。机器表见 [offline-listening-signoff.json](offline-listening-signoff.json)，其中 implemented 指应用代码的端到端调用链已接通；设备行为单列

|固定上游入口与动作|Swift 入口与核查结果|
|---|---|
|audio/view、controller：音频投稿与视频音轨，来源队列、上一页/下一页、正反序、选 P、四种服务播放模式、继续、倍速、进度/歌词、内容操作|ListenView → ListenQueue / ListenerCatalog → Listener 的目录与取流。媒体按当前身份回包及平台支持的音轨播放；课程/影视沿本集播放权；无可用音轨时显示服务错误。播放信息、歌词、收藏、转发与举报走原资源编号。详见 [音频逐动作](listener-audio-audit.md) 和 [队列转移](audio-queue-order.md)|
|download_panel 与 download/{download,page,detail,search,downloading}：选画音质、多选、合集内分 P、分组/排序、搜索作者/标题、删除/更新附件、下载中暂停续下|详情内的 CacheSelection、EpisodeCacheView、SeasonBatchCache → Downloads.resolve；列表和分 P 多选 → OfflineShelfView / OfflineGroupView / OfflineBatchPanel。缓存实际使用原版一般档音画质而非蜂窝播放档；默认显示可取得的实际档位，多选跨集可逐集匹配。显式选档只在真正取得该档时缓存|
|下载管理器与服务：分段/单文件的入队、失败、重试、后台恢复、媒体持久化|原生后台 URLSession，原账号、授权资源和表示指纹一致才继续；校验长度、区段与实体校验器，写盘后提交检查点。每个条目的媒体、附件、分组和进度可由本地读回。iOS Files 授权目录是实际缓存位置并支持等待/重试。原版 Flutter 旧文件夹可按条目重新获得授权后下载；不把原版未标明下载身份的字节直接登记给任意账户。[逐动作](offline-files-audit.md) · [授权目录](storage-locations.md) · [离线解码](offline-native-decode.md)|
|离线播放、分集导航与记忆|OfflinePlayer / OfflineQueuePlayer 从指定包和视频账号建本机 AVPlayerItem，读取本地音画轨、字幕、分段弹幕和空降片段；切换账号/资源撤销监听，观看进度分人。影院/课程序列沿正式提供的分集权利，[课程与剧集缓存](episode-offline.md)|
|audio_handler：锁屏/控制中心、耳机命令、媒体封面/信息、前后曲和定位，以及退出详情后上一项信息|SystemMediaControls 根据实际正在用的播放器选主。替换标题或重设命令时保留当前暂停项；关闭正在显示的媒体后恢复上一项可用的控制，保持其原有播放状态。此前仅预热过的视频不会抢占控制。旧回调检查绑定代次，关闭系统媒体或退出当前账号会释放相应注册。直播不显示不可用的定点跳转|
|audio_session：音乐类别，通话中断、耳机断开，与后台恢复|PlaybackSessionEvents 使用 iOS 27 的 didBecomeInactive 和 resumptionRecommendation，区分应用主动退出会话、系统中断与路由丢失；iOS 17–26 用 interruption + shouldResume。ListenQueue 的票绑定播放代次，视频用 AVPlayer 的真实 rate 变化原因、原 item 与倍率；收到允许后须成功启用会话才恢复一次。用户暂停、切换能发声的媒体、账号变化、睡眠停止或耳机断开会作废相应票。单独的应用前台恢复不能绕过电话/路由结果。Swift 的时间基准模块也改用对应代际的失活通知。参见 Apple [Handling audio interruptions](https://developer.apple.com/documentation/avfaudio/handling-audio-interruptions) 与 [Responding to audio route changes](https://developer.apple.com/documentation/avfaudio/responding-to-audio-route-changes)|
|service_locator 的两个注册，关闭程序/切换账号|原版 setupServiceLocator 只装 audio handler 和 session；原生单例/播放器在确有媒体时注册，对应页面退场、角色切换与后台任务有原生清理。仅主账号改变时重开其听队列；独立视频角色改变后释放旧角色音轨，即使 AVPlayer 仍留有缓冲数据。与后台下载的 UIApplicationDelegate 回调分开|
|shutdown_timer_service 的预设/自定、剩余时间、到时/播完、退出|15/30/45/60 分钟、自定 1–1499 分钟、倒计时/取消；点播/离线/听视频可播完本集，无结束位置的直播立即停止。准备未自动播放的视频不再暂停在听的内容或夺走定时器；定时器先于媒体就绪时，延后的就绪回调不再偷偷起播。默认暂停，可选择返回首页或明确选择退出应用；iPad 等支持多窗口的设备调用 [UIKit 关闭场景](https://developer.apple.com/documentation/uikit/uiapplication/requestscenesessiondestruction(_:options:errorhandler:))。单窗口 iPhone 自签构建采用原版的 Darwin 正常 exit(0)，不调用私有 UIKit 方法。苹果 [QA1561](https://developer.apple.com/library/archive/qa/qa1561/_index.html) 不推荐应用自行结束进程|

退出时先按真正的播放时间保存本机观看位置；启用了云历史的当前账号正常提交进度并等待。未结束的网络提交、Keychain 改动、备份恢复、账号清理与缓存收件/搬移由事务计数拦住最后一步。下载记录系统任务 ID + 包代次和分轨，用原子文件存储后挂起正在进行的任务；取消退出或重开应用，只恢复来源账号、任务 ID 和当前状态相符的任务。用户主动暂停的不动。未设置退出倒计时、已取消、期限未到、正在等本集播完以及仍有写入，都不能触发进程结束；忽略重复通知。准备期间存储失败则保留应用并显示错误，用户也可以取消

复验（WSL/Linux，除 iOS SDK 类型检查外全都在临时文件内运行）：

- bash Checks/listen_interruption.sh：运行现有生产 gate / 新的视频恢复状态机、不同来源、负建议、单次恢复、自定义速率、手动取消、睡眠时点、歌词解析；以计数替身核对实际退出许可（无计时、取消、到期等待当前集、写事务阻止、只触发一次），从真实临时文件读回挂起清单，验证跨账号/错代次/用户手动暂停不会恢复；同时验证缓存预设独立于蜂窝播放档
- python3 Checks/offline_resume.py：实际编译权限和离线读写，换所有人/错误 CID、分段确认、崩溃尾、断点续传和按观看者删除/进度通过
- bash Checks/storage_locations.sh：真实临时文件不覆盖、成对/事务、目录重试、封装轨错误身份/密钥/截断均通过
- python3 Checks/vod_probe.py：实际 URLSession 到主机回环，媒体备用线、完整/短尾/错误状态与取消通过
- arm64 iOS 17.0 部署目标，Apple iPhoneOS 27.1 SDK 定点类型检查，包含 Offline、Listen、实际 PlayerModel / 系统会话/定时器及根账号切换。未签名安装、没有账号写入或媒体服务请求

最终真机要验的是设备后台 URLSession 的系统唤醒、断网读已经许可并缓存的分轨、iCloud 等文件提供方离线/重授权、锁屏蓝牙/耳机和来电之后的出声、跨窗口 PiP/后台音频交接。以上是设备检查；本轮没有在真实设备上执行退出
