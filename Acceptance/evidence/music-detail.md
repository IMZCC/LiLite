固定来源：lib/pages/music（详情、video、widget/music_video_card_h）、lib/pages/video/introduction/ugc/view.dart 的 _buildTags、lib/http/music.dart 和 lib/models_new/music

从视频简介点 BGM 标签会按服务给的 MA ID 打开音乐；话题标签去指定话题，普通标签去搜索，长按可以复制。换分 P 后重新读取对应 CID 的标签。音乐详情支持封面查看、复制歌名、艺人空间或复制艺人、发行日期/专辑/出处/原唱、榜单成就、热度及总播放数。拖动趋势图或用 VoiceOver 逐日访问数值。MV 只在有真实 mv_cid 时按其 BV 或 AV 开启并选中具体分 P。评论用服务下发的 oid，原版缺省类型 47；阅读分栏、发评论和分享沿用全局入口。想听读写绑定当前主账号，推荐稿件读取使用推荐账号

使用稿件列表呈现标签、作者、时长、播放量、弹幕量、封面长按及对应 BV/CID；没有 CID 的视频交给视频详情读取正式分 P，不会拿前一条 CID。想听写入仅由用户手动触发。原生 Swift 的 Checks/music_content.sh 可读离线样例或传入普通访客取得的 [tags, detail, recommendations] 原始 JSON

2026-11-12 访客从音乐分区排行榜点到 BV17VZpY1ENA，获得 5 个标签（含 BGM、话题、普通），BGM 为 MA400016552499358923。原生程序实际解码到 1 位艺人、30 天热度、300 条有合法 BV 的关联投稿；该回包无可播放 MV。独立分 P、同 BV 不同 CID、曲线异常数据和想听字段另以实际 Swift 模型样例核对；iPhoneOS 27.1 arm64 定点类型检查通过
