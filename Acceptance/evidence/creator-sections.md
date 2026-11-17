# 创作者空间栏目与主页

对照固定上游 2.2.0.2 的 lib/pages/member/controller.dart、view.dart，member_home、member_contribute、member_favorite、member_pgc 及 lib/models/common/member/tab_type.dart。入口为原生 CreatorSpace，按 /x/v2/space 的 tab2 顺序显示可用栏目；关闭小店时忽略 shop，没有主页作品时不显示 home。优先显示用户选择，其次为服务的 default_tab（video 对应 contribute），最后为第一个可用栏目。端点失败有重试，仍可打开空间搜索和作品目录

- 主页：分别读取 archive、favourite2、coin_archive、like_archive、article、audios、comic、season 的 item 和 count。打开视频、PGC 分集、收藏夹、专栏、音乐、漫画、番剧时使用各类实际 ID；收藏夹区分主页的 media_id 和收藏列表的 id。本人可见的公开/私密提示与服务字段相同，直播间入口使用 roomid
- 投稿：按二级栏目展示视频投稿、充电专属、专栏、图文、音频、漫画、独立合集和视频列表；同一 UP 主的多个合集或列表用 season_id / series_id 区分。充电专属沿 /x/v2/space/archive/charging 翻页，播片仍经原生取流。番剧首屏复用主页返回的 season，按 /x/v2/space/bangumi 加载后页；课堂、小店和动态使用相应原生页面
- 收藏：根据 /x/v3/fav/folder/space 分别展示创建、收藏/订阅的列表，可分别展开并通过 created/list、collected/list 分页。普通文件夹可搜索、排序及打开混合收藏，type 21 合集走 /x/space/fav/season/list，失效行没有操作
- 身份与互动：头像、头像框、官方认证、等级、签名和服务给出的统计；点击头像可查看原图，有勋章时能进入粉丝勋章墙。预约卡读 reservation_card_list，可查看关联动态或抽奖说明，由用户选择预约/取消预约；请求绑定发起操作的账号，只在服务返回成功后改计数
- 偏好：memberTab 使用原版序号 0 默认、1 主页、2 动态、3 投稿、4 收藏、5 番剧、6 课堂、7 小店，原生键 creator.initialSection。核查文件：Sources/PiliNative/Social/CreatorSections.swift、CreatorSectionViews.swift、CreatorFavorites.swift、Creators.swift、CreatorLibrary.swift

已运行 Checks/CreatorSectionsCheck.swift：检查默认 video 别名、预选和栏目缺失回退、小店与空主页、服务顺序、不同合集的身份、实际卡片目的地。匿名访问公开账号的 /x/v2/space 返回 HTTP 412，未继续尝试绕过限制；没有执行预约或其他账号写入。真实账号的栏目与已购内容、勋章和预约状态、导航与旋转仍需在最终设备验收中核对
