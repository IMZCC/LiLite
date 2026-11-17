# 播放器运行时性能修复

日期：2026-11-13
复核分支及基线：`native/ios`，`2d16f01f53474b0f5b59523ecdc1324a4bc626e6`
用户反馈版本：源码 `b7e128c12`，iPhone 15 Pro Max，iOS 27.3

已核对两提交间本报告涉及的原播放器、弹幕、字幕、超分与 Decoder 文件没有差异，因此下列原路径同样存在于已安装版本

## 实际热点及修复

| ID | 原路径与开销 | 修改后的生产路径 |
| --- | --- | --- |
| PERF-PLAYER-01 | `PlayerModel.startClock` 在主队列以 15 Hz 回调，每次无条件赋值 `@Published seconds/playing/duration`；正常时长已知时每秒约 45 次模型通知，连带重算观察整模型的详情、播放器和全屏视图 | 普通进度以 4 Hz 发布，播放状态及总时长仅变化时发布；跳转、暂停状态变化和普通字幕边界立即刷新；内部采样仍 15 Hz，片头片尾、空降助手、弹幕分段、心跳和本地进度保存使用实际采样时间；显式 seek 继续立即赋值；主队列回调直接进入已知 MainActor，移除每次额外排入一个 Task |
| PERF-PLAYER-02 | `BulletOverlay` 的 `.task` 继承视图 actor，整段过滤、正则匹配、UIFont 测量与排轨均在该任务内同步执行；每条弹幕重新测量正文及重复计数，即使文字相同 | 新 `BulletLayoutPlan` 在 `Task.detached` 中准备，测量按正文/计数缓存；纯值快照交给后台，完成后才更新视图；取消向真实 worker 传播，过滤和排轨分批检查取消，过期布局不会回写；取消低透明度不可见弹幕的排轨及动画 |
| PERF-PLAYER-03 | `BulletOverlay.Canvas` 每帧为每条普通弹幕重新构造 Text/resolve，描边绘制 8 遍加正文 1 遍；高级弹幕也重新排文字 | 新 `BulletRasterCache` 共享不可变字形图像，NSCache 配置 32 MiB 成本、512 条目标上限，每张图像像素数有单独限制；常见弹幕每帧只画 1 张图，描边、VIP 渐变、合并计数及高级弹幕阴影在缓存缺失时准备；初始可见窗口在后台预热，Canvas 请求异步绘制；超大导入文字保留原矢量路径；颜色、大小、字重、描边、缩放和文字均参与缓存键，自己的绿色外框仍按当前轨迹绘制 |
| PERF-PLAYER-04 | `SubtitleSession.reload` 在 MainActor 构造最多 50,000 条字幕的边界排序与 Fenwick 索引；双语需再次构建；离线字幕的验证/排序也在视图 actor | `SubtitleTimeline.prepare` 使用可取消 detached 任务；索引内检查取消，返回后重新核对字幕选择 stamp；离线字幕文档准备也移到后台，回到 UI 前核对 epoch；`interval(at:)` 用小整数标识字幕边界，使 15 Hz 采样无需重复拼接字幕字符串 |
| PERF-PLAYER-05 | 每次外层视图更新调用 `StyledSubtitleLayer.configure` 都立即 tick，在自己的 30 Hz display link 之外追加渲染请求 | 仅脚本、播放器或画面适配模式发生变化时 configure 主动 tick，其余帧保持原 display link；libass 仍在专用串行队列运行，最多一个待处理请求，保留 epoch 与 unchanged-frame 处理 |
| PERF-PLAYER-06 | `ViewportClock` 的状态与 loadedTimeRanges KVO 即使结果相同也发布，已有主队列周期回调又创建 Task | 播放状态和缓冲区间去重，周期回调直接在 MainActor 更新，时间仍维持原 0.25 秒步长 |

PERF-PLAYER-01 的通知减少来自实际赋值分支，约 45 → 4 次/秒指普通连续播放、播放状态和总时长不变且没有字幕边界的情况；字幕切换、状态与业务事件仍正常发布

## 其余媒体链核查

- `DecoderSegment.convert`、`AudioSegment.convert` 和 `LegacyMovieRemux.convert` 的 C 解码、音频滤镜及封装已在 detached worker，取消传入原 C 回调；`DecoderSegments` 本身合并请求并串行处理，不在本轮引入第二套解码或改变播放质量
- `ProgressiveDecoderBridge` 的本地 MP4 索引建立已移交 detached，DASH/旧式媒体的网络监听使用各自队列；本轮不修改 URL、视频传输或授权链，真机“错误的 URL”由根任务独立追踪
- `UpscaleMetal.shared` 的权重读取、Metal 库及管线编译已在单个共享后台 Task；`UpscaleSurface` 的帧消费有 busy 限制，GPU 完成后才释放像素缓冲，未发现 CPU 等待 GPU 的 `waitUntilCompleted`；`UpscaleSession.status` 已去重，默认关闭、HDR/外部播放回退条件保留
- `SystemMediaControls` 的 Now Playing 更新间隔为 2 秒，封面加载为异步且有 stamp/ownership 核对，不属于上述逐帧广播；本轮不修改共享图片加载和界面布局

## 验证

1. 现有 `ContentContractCheck.swift` 扩展生产 `BulletLayoutPlan` 的大段后台准备及中途取消路径，并由既有 `Checks/run.sh` 加入新生产源依赖
   - 50,000 条合成弹幕，25 种重复正文加空计数：只做 **26 次** 独立宽度测量，生成 **19,232** 条有效排轨
   - worker 内测量确实不在主线程，中途取消在后续批次停止并抛出 `CancellationError`
   - 本次 WSL 无优化主机运行准备约 **85 ms**，该数值只描述主机算法与合成测量回调，不是 iPhone 文字栅格或整机帧率
   - 原 XML/protobuf、模式 7 动画、截断包、云端/本地过滤、合并、自发弹幕与轨道避让断言继续通过
2. `bash Checks/caption_domain.sh`：PASS；原 BCC/JSON、VTT/SRT、ASS、双语重叠、5,000 条密集字幕和迟到字幕取消通过；新增后台构建结果与同步基准一致，以及边界标识在 cue 进出时变化的检查
3. `python3 dist/player-performance-sdk.py`：PASS；以真实 arm64 iOS SDK 定点编译本轮所有播放器/弹幕/字幕生产文件，并检查 SystemMediaControls、UpscaleSurface、ProgressiveDecoderBridge 与 DecoderSegment；最终日志无 error 或 warning
4. 本域 `git diff --check`：PASS

只扩展既有复杂媒体行为检查，没有为简单属性去重或界面文案新增测试套件

## 冻结清单

- 新增：`Danmaku/BulletLayoutPlan.swift`、`Danmaku/BulletRasterCache.swift`
- 修改：`Danmaku/BulletOverlay.swift`、`Danmaku/Danmaku.swift`、`Danmaku/DanmakuStyle.swift`、`Danmaku/SpecialBullet.swift`
- 修改：`Playback/PlayerModel.swift`、`Playback/ViewportTimeline.swift`、`Playback/SubtitleDocument.swift`、`Playback/SubtitleSession.swift`、`Playback/StyledSubtitleLayer.swift`
- 检查：`Checks/ContentContractCheck.swift`、`Checks/CaptionDomainCheck.swift`；`Checks/run.sh` 新源依赖由根任务加入

本报告对应代码已冻结，未提交、签名或安装；根任务统一构建 release 后在真机复测滚动交互、视频解码与音画、弹幕外观/点击/暂停/seek、字幕切换和超分开启后的耗时与热状态，并记录整机结果
