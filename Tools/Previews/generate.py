"""Render source-referenced layout previews, without claiming iOS runtime screenshots.

All content is local sample data. Generated files belong under dist/Previews.
"""
from pathlib import Path
import hashlib
import html
import json
import subprocess

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "dist" / "Previews" / "2026-11-13"
OUT.mkdir(parents=True, exist_ok=True)

SOURCES = {
    "home": ["Library/Feed.swift", "Library/CatalogGrid.swift", "Settings/MainNavShell.swift", "Settings/NavigationRules.swift"],
    "video": ["Playback/DetailView.swift", "Playback/PlaybackPanels.swift", "Playback/ArchiveMetadata.swift", "Playback/ArchiveDescription.swift"],
    "search": ["Discover/SearchView.swift", "Discover/DiscoveryContracts.swift", "Discover/SearchHit.swift", "Library/PageList.swift"],
    "profile": ["Account/ProfileView.swift", "Account/ProfileOverview.swift", "Settings/MainNavShell.swift"],
    "settings": ["Settings/Settings.swift", "Social/CreatorSectionViews.swift", "Settings/ThemePicker.swift"],
    "fullscreen": ["Playback/Theater.swift", "Playback/PlayerViewport.swift", "Settings/NativeGlass.swift"],
}
for files in SOURCES.values():
    if "Settings/NativeGlass.swift" not in files:
        files.append("Settings/NativeGlass.swift")
TITLES = {"home": "发现 · 推荐", "video": "视频 · 简介", "search": "搜索 · 视频结果", "profile": "我的 · 示例账号", "settings": "设置", "fullscreen": "全屏播放 · 悬浮控件"}

PATHS = {
    "home": '<rect x="3" y="5" width="18" height="14" rx="3"/><path d="m10 9 5 3-5 3z"/>',
    "search": '<circle cx="10.5" cy="10.5" r="6.5"/><path d="m16 16 5 5"/>',
    "people": '<circle cx="8" cy="8" r="3"/><path d="M2 20v-2a6 6 0 0 1 12 0v2M17 5a3 3 0 0 1 0 6m1 3a5 5 0 0 1 4 5"/>',
    "person": '<circle cx="12" cy="12" r="9"/><circle cx="12" cy="9" r="3"/><path d="M5.5 19a6.6 6.6 0 0 1 13 0"/>',
    "chevron": '<path d="m9 5 7 7-7 7"/>',
    "back": '<path d="m15 4-8 8 8 8"/>',
    "grid": '<rect x="3" y="3" width="7" height="7" rx="1.5"/><rect x="14" y="3" width="7" height="7" rx="1.5"/><rect x="3" y="14" width="7" height="7" rx="1.5"/><rect x="14" y="14" width="7" height="7" rx="1.5"/>',
    "dots": '<circle cx="5" cy="12" r="1"/><circle cx="12" cy="12" r="1"/><circle cx="19" cy="12" r="1"/>',
    "pause": '<path d="M8 5v14M16 5v14" stroke-width="4"/>',
    "full": '<path d="M9 3H3v6m0-6 6 6m6 12h6v-6m0 6-6-6"/>',
    "list": '<path d="M8 6h13M8 12h13M8 18h13M3 6h.1M3 12h.1M3 18h.1"/>',
    "capture": '<rect x="3" y="6" width="18" height="14" rx="3"/><path d="m8 6 1-3h6l1 3"/><circle cx="12" cy="13" r="4"/>',
    "speed": '<path d="M4 18a9 9 0 1 1 16 0M12 12l5-4M7 8l1 1m8 0 1-1M5 14h1m12 0h1"/>',
    "airplay": '<path d="M8 18H4a1 1 0 0 1-1-1V5a1 1 0 0 1 1-1h16a1 1 0 0 1 1 1v12a1 1 0 0 1-1 1h-4"/><path d="m12 15-5 6h10z"/>',
    "filter": '<path d="M3 5h18M6 12h12M10 19h4"/>',
    "envelope": '<rect x="3" y="5" width="18" height="14" rx="2"/><path d="m3 6 9 7 9-7"/>',
    "bubble": '<path d="M5 4h14a2 2 0 0 1 2 2v11a2 2 0 0 1-2 2h-9l-5 3v-3a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2z"/>',
    "heart": '<path d="M12 21S2 14 2 8a5 5 0 0 1 10-2 5 5 0 0 1 10 2c0 6-10 13-10 13z"/>',
    "star": '<path d="m12 2 3 6.5 7 1-5 5 1.2 7L12 18l-6.2 3.5 1.2-7-5-5 7-1z"/>',
    "coin": '<circle cx="12" cy="12" r="9"/><circle cx="12" cy="12" r="5"/>',
    "share": '<path d="M8 9H4v12h16V9h-4M12 15V2m-5 5 5-5 5 5"/>',
    "lock": '<rect x="5" y="10" width="14" height="11" rx="3"/><path d="M8 10V6a4 4 0 0 1 8 0"/>',
    "close": '<path d="m6 6 12 12M18 6 6 18"/>',
    "panel": '<rect x="3" y="4" width="18" height="16" rx="3"/><path d="M15 4v16"/>',
    "timeline": '<path d="M3 12h18M7 7v10M17 7v10"/><circle cx="12" cy="12" r="3"/>',
    "pip": '<rect x="2" y="4" width="20" height="16" rx="3"/><rect x="12" y="11" width="8" height="6" rx="1"/>',
}

def icon(name, size=22):
    return f'<svg width="{size}" height="{size}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">{PATHS[name]}</svg>'

def landscape(kind=0):
    colors = [("#c0dfec", "#8ab5bc", "#427d73", "#234f4c"), ("#e2d5bc", "#c8b29c", "#7a8b75", "#4c615b"), ("#bacddf", "#8eaac9", "#55769c", "#344f78"), ("#dfc8c4", "#b59bb0", "#706d99", "#3b4c73")]
    sky, a, b, c = colors[kind % len(colors)]
    return f'<svg class="landscape" viewBox="0 0 800 450" preserveAspectRatio="xMidYMid slice"><defs><linearGradient id="sky{kind}" x2="0" y2="1"><stop stop-color="{sky}"/><stop offset="1" stop-color="#f4efdb"/></linearGradient></defs><rect width="800" height="450" fill="url(#sky{kind})"/><circle cx="620" cy="101" r="44" fill="#fff5dc" opacity=".9"/><path d="M0 265 136 117 225 200 340 85 490 235 597 135 800 272V450H0" fill="{a}"/><path d="m136 117-35 102 35-25 34 17zm204-32-48 125 42-29 36 27z" fill="#eef4ec" opacity=".8"/><path d="M0 333 190 214 318 325 467 199 641 327 800 219V450H0" fill="{b}"/><path d="M0 359q160-103 325 8T800 328v122H0" fill="{c}"/><path d="M580 310q-110 42-175 140h130q25-95 45-140" fill="{sky}" opacity=".55"/><g fill="#173b38" opacity=".7"><path d="m65 275-30 82h60zM65 306l-39 92h78zM748 268l-32 86h64zM748 304l-43 99h86z"/></g></svg>'

def status():
    return '<div class="status"><b>9:41</b><span class="island"></span><span class="radio">▂▄▆█&nbsp; <svg width="18" height="14" viewBox="0 0 20 16"><path d="M1 4Q10-3 19 4M4 7q6-5 12 0M7 10q3-3 6 0" fill="none" stroke="currentColor" stroke-width="2"/><circle cx="10" cy="13" r="1.2" fill="currentColor"/></svg><span class="battery"></span></span></div>'


SOURCES["home"].append("Settings/NativeTabReselect.swift")
SOURCES["profile"].extend(["Account/ProfileComponents.swift","Account/ProfileShelf.swift"])
SOURCES["settings"].append("Settings/SettingsRow.swift")
SOURCES["video"].append("Playback/ArchivePlaybackOptions.swift")
PATHS.update({
 "clock": '<circle cx="12" cy="12" r="9"/><path d="M12 6v6l4 2"/>',
 "folder": '<path d="M3 5h7l2 3h9v12H3z"/>',
 "download": '<path d="M12 3v12m-5-5 5 5 5-5M4 18v3h16v-3"/>',
 "headphones": '<path d="M4 15V12a8 8 0 0 1 16 0v3"/><rect x="3" y="12" width="4" height="8" rx="2"/><rect x="17" y="12" width="4" height="8" rx="2"/>',
 "gear": '<circle cx="12" cy="12" r="4"/><path d="m9 2-1 3-3 1-3 3 2 3-1 4 4 1 2 4h5l1-3 4-2 1-4-2-3-1-4-4 1z"/>',
 "palette": '<path d="M12 3a9 9 0 1 0 1 18c4-1-1-4 1-6 1-1 6 1 7-3 1-5-4-9-9-9z"/><circle cx="7" cy="9" r="1"/><circle cx="12" cy="6" r="1"/><circle cx="17" cy="9" r="1"/>',
 "half": '<circle cx="12" cy="12" r="9"/><path d="M12 3a9 9 0 0 1 0 18z" fill="currentColor"/>',
 "hand": '<path d="M9 20 4 13q-1-3 1-3l3 3V5q0-3 2-1v7-8q2-2 3 0v8-6q2-2 3 1v6-4q2-2 3 1v7q0 5-5 6z"/>',
 "type": '<path d="M3 5h12M9 5v16M17 11h6M20 11v10"/>',
 "moon": '<path d="M20 14A9 9 0 0 1 10 3 9 9 0 1 0 20 14z"/>',
 "sliders": '<path d="M3 6h5m5 0h8M3 12h11m5 0h2M3 18h2m5 0h11"/><circle cx="10" cy="6" r="2"/><circle cx="16" cy="12" r="2"/><circle cx="7" cy="18" r="2"/>',
 "user": '<circle cx="12" cy="8" r="4" fill="currentColor" stroke="none"/><path d="M4 22v-3a8 8 0 0 1 16 0v3z" fill="currentColor" stroke="none"/>',
})

def nav(title, back=False, trailing="dots", large=True):
    leading='<span class="nav-back">'+icon("back",20)+'</span>' if back else ''
    right=('<span class="toolbar-group">'+(icon("person",25) if title=="发现" else '')+icon(trailing,21)+'</span>') if trailing else ''
    return '<div class="nav"><span>'+leading+'</span><b>'+(html.escape(title) if not large else '')+'</b><span>'+right+'</span></div>'+(f'<div class="large-title">{html.escape(title)}</div>' if large else '')

def tabs(selected):
    items=[("home","home","发现"),("dynamics","people","动态"),("profile","person","我的"),("search","search","搜索")]
    rail=''.join('<div class="tab '+('selected' if selected==key else '')+'">'+icon(symbol,23)+'<small>'+label+'</small></div>' for key,symbol,label in items)
    return '<div class="system-tabs"><div class="tab-rail">'+rail+'</div></div>'

def searchbar(value="搜索"):
    return '<div class="searchbar">'+icon("search",18)+'<span>'+html.escape(value)+'</span></div>'

def toggle(on=True):
    return '<span class="toggle'+(' on' if on else '')+'"></span>'

def row(label,value="",switch=None,symbol=None,tone="#8e8e93"):
    artwork='<span class="settings-icon" style="background:'+tone+'">'+icon(symbol,17)+'</span>' if symbol else ''
    ending=toggle(switch) if switch is not None else '<span class="row-value">'+html.escape(value)+'</span>'+icon("chevron",13)
    return '<div class="row"><span class="row-label">'+artwork+html.escape(label)+'</span><span class="row-tail">'+ending+'</span></div>'

def section(rows,title=""):
    return ('<div class="section-title">'+html.escape(title)+'</div>' if title else '')+'<div class="section">'+''.join(rows)+'</div>'

SAMPLES=[
 ("在山野里，找回生活的节奏","山间来信","12.8万","12:34",0),
 ("给周末留一点空白","拾光记录","8.6万","08:26",1),
 ("和海风一起，慢下来","沿途风景","23.4万","16:09",2),
 ("认真过好每一个平常日","日常放映室","6.2万","10:15",3),
]

def cover(k,duration):
    return '<div class="cover">'+landscape(k)+'<span class="duration">'+duration+'</span></div>'

def home():
    cards=[]
    for i,(title,owner,views,duration,k) in enumerate(SAMPLES+SAMPLES[1:]):
        cards.append('<article class="video-card '+('featured' if i==0 else '')+'">'+cover(k,duration)+'<h3>'+title+'</h3><div class="meta"><span>'+owner+'</span><span>'+icon("home",13)+views+'</span></div></article>')
    channels='<div class="channels">'+''.join('<span class="channel '+('active' if s=="推荐" else '')+'">'+s+'</span>' for s in ["直播","推荐","热门","分区","番剧","影视"])+'</div>'
    return nav("发现",trailing="dots")+channels+'<div class="home-scroll"><div class="video-grid">'+''.join(cards)+'</div></div>'+tabs("home")

def video():
    player='<div class="player">'+landscape(0)+'<span class="bullet b1">这一刻，好安静</span><span class="bullet b2">想去山野走一走</span></div>'
    transport='<div class="transport">'+icon("pause",18)+'<span class="time">02:18</span><div class="progress"><i></i></div><span class="time">12:34</span>'+icon("full",19)+'</div>'
    details='<div class="metadata-title"><h2>'+SAMPLES[0][0]+'</h2>'+icon("dots",20)+'</div><div class="stats muted">'+icon("home",14)+'12.8万'+icon("bubble",14)+'1,286'+icon("heart",14)+'1.2万'+icon("coin",14)+'2,184</div><div class="online muted">328 人正在看</div>'
    controls='<div class="detail-controls"><span class="dm-toggle">'+icon("bubble",17)+'弹幕</span>'+icon("list",20)+'<span class="spacer"></span>'+icon("airplay",21)+icon("sliders",21)+'</div>'
    info='<div class="description-row">'+icon("list",18)+'<span>视频简介</span><span class="spacer"></span>'+icon("chevron",13)+'</div>'
    owner='<div class="owner">'+icon("person",32)+'<b>山间来信</b><span class="spacer"></span><span class="follow">关注</span></div>'
    parts='<div class="episode"><span>选集</span><span class="muted">P1 · 山间漫步⌄</span><span class="spacer"></span><span class="tint">倒序</span></div>'
    listen='<div class="listen-row">'+icon("headphones",18)+'<span>听视频</span><span class="spacer"></span><span class="tint">加入待播</span></div>'
    engagement='<div class="engagement">'+''.join('<span>'+icon(i,22)+'<small>'+label+'</small></span>' for i,label in [("heart","点赞"),("coin","投币"),("star","收藏"),("share","分享")])+'</div>'
    return nav("视频",back=True,trailing=None,large=False)+player+transport+'<div class="segmented"><span class="picked">简介</span><span>评论</span></div><div class="video-info">'+details+controls+'<hr>'+info+owner+parts+listen+engagement+'</div>'

def search():
    rows=''.join('<div class="search-result"><div class="result-cover">'+landscape(k)+'<span class="duration">'+duration+'</span></div><div class="result-text"><h4>'+title+'</h4><div class="muted small">'+owner+'</div><div class="muted small">'+views+'次播放</div></div></div>' for title,owner,views,duration,k in SAMPLES+SAMPLES[:2])
    return nav("搜索")+searchbar("旅行")+'<div class="search-kind"><span>视频 <span class="muted">99+⌄</span></span><span class="tint">'+icon("filter",18)+'筛选</span></div><div class="search-list">'+rows+'</div>'+tabs("search")

def profile():
    header='<div class="profile-header"><div class="account-person"><span class="avatar">'+icon("user",32)+'</span><div><b>示例用户</b><small>UID 12345678</small><small>Lv.5</small></div><span class="spacer"></span>'+icon("chevron",14)+'</div><div class="account-stats"><span><b>28</b><small>动态</small></span><span><b>136</b><small>关注</small></span><span><b>52</b><small>粉丝</small></span></div><div class="experience"><span>128.5 硬币</span><span>经验 16,280/28,800</span></div><div class="profile-progress"><i></i></div></div>'
    shortcuts='<div class="shortcuts">'+''.join('<span style="--icon:'+tone+'">'+icon(symbol,24)+'<small>'+label+'</small></span>' for label,symbol,tone in [("历史","clock","#007aff"),("稍后再看","list","#ff9500"),("收藏","star","#e8ab20"),("离线","download","#af52de")])+'</div>'
    folders='<div class="folder-shelf">'+''.join('<article>'+landscape(k)+'<b>'+label+'</b><small>收藏夹 · '+str(n)+' 项</small></article>' for label,n,k in [("留给周末",32,1),("慢慢看世界",18,2)])+'</div>'
    body=section([shortcuts])+section([folders],"我的收藏")
    body+=section([row("听视频",symbol="headphones",tone="#ff2d55"),row("图文、话题和笔记",symbol="list",tone="#007aff"),row("收藏的课程",symbol="home",tone="#5856d6")],"资料库")
    body+=section([row("追番追剧",symbol="home",tone="#ff2d55"),row("我的订阅",symbol="grid",tone="#ff9500")],"订阅")
    return nav("我的")+'<div class="profile-scroll">'+header+body+'</div>'+tabs("profile")

def settings():
    body=section([
        row("外观模式","跟随系统",symbol="half",tone="#5856d6"),
        row("主题颜色",symbol="palette",tone="#ff2d55"),
        row("导航布局",symbol="grid",tone="#007aff"),
        row("界面与手势",symbol="hand",tone="#007aff"),
        row("字体与字号",symbol="type",tone="#5856d6"),
        row("刷新率",symbol="speed",tone="#ff9500"),
    ],"外观与布局")
    body+=section([row("深色模式使用纯黑背景",switch=False),row("深色模式调暗网络图片",switch=False),'<div class="row"><span>提示不透明度</span><span class="row-value">100%</span></div><div class="slider"><i></i></div>'],"深色与阅读")
    body+=section([row("画面与音轨",symbol="home",tone="#007aff"),row("详情与播放控制",symbol="sliders",tone="#8e8e93"),row("默认倍速","1×",symbol="speed",tone="#ff9500"),row("自定义播放倍速",symbol="speed",tone="#ff9500")],"播放")
    return nav("设置",back=True,trailing=None)+'<div class="form-scroll">'+body+'</div><div class="settings-search">'+searchbar("搜索设置")+'</div>'

def fullscreen():
    tools=''.join('<span class="glass-circle">'+icon(i,20)+'</span>' for i in ["lock","heart","panel","capture","timeline","close"])
    return '<main class="fullscreen"><div class="fullscreen-image">'+landscape(0)+'</div><span class="bullet" style="top:80px;left:350px">这样的山野，真的想去走一走</span><span class="bullet" style="top:126px;left:90px">把日常过成喜欢的样子</span><div class="full-tools">'+tools+'</div><div class="full-transport">'+icon("pause",22)+'<div class="progress"><i></i></div><span class="time">02:18</span>'+icon("pip",22)+icon("full",22)+'</div><div class="wide-indicator"></div></main>'

CSS=r"""
*{box-sizing:border-box}html,body{margin:0;padding:0}
body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI","Microsoft YaHei UI",sans-serif;color:var(--text);background:var(--bg);font-size:17px;--text:#17191c;--bg:#fff;--muted:#85878d;--tint:#006d3b;--group:#f2f2f7;--line:rgba(60,60,67,.13);--surface:#fff}
body.dark{--text:#f5f5f7;--bg:#000;--muted:#96969c;--tint:#7dda9a;--group:#17171b;--line:#ffffff24;--surface:#222226}
.screen{width:430px;height:932px;overflow:hidden;position:relative;background:var(--bg)}
.status{height:54px;padding:16px 28px 0;display:flex;justify-content:space-between;align-items:flex-start;font-size:16px;position:relative}
.island{width:120px;height:34px;position:absolute;top:10px;left:155px;background:#070707;border-radius:24px}
.radio{display:flex;align-items:center;gap:4px;font-size:11px;padding-top:3px}
.battery{width:25px;height:12px;border:1.2px solid currentColor;border-radius:3px;margin-left:3px;position:relative}
.battery:before{content:"";position:absolute;inset:1.5px;background:currentColor;border-radius:1px}
.battery:after{content:"";width:2px;height:5px;position:absolute;right:-4px;top:2px;background:currentColor;border-radius:1px}
.nav{height:44px;display:flex;align-items:center;justify-content:space-between;padding:0 20px}
.nav>span{min-width:76px;display:flex;align-items:center}.nav>span:last-child{justify-content:flex-end}
.nav-back{display:flex;align-items:center;justify-content:center;height:36px;width:36px;border-radius:50%;background:#f7f7f9d9;box-shadow:0 1px 5px #0000000d}
.toolbar-group{display:flex;align-items:center;justify-content:center;gap:18px;min-height:36px;padding:0 10px;border-radius:30px;background:#f7f7f9b8;box-shadow:0 2px 5px #0000000c}
.large-title{font-size:34px;font-weight:600;line-height:44px;letter-spacing:-.8px;padding:2px 20px 10px}
.tint{color:var(--tint)}.muted{color:var(--muted)}.small{font-size:12px}.spacer{flex:1}
.searchbar{height:42px;margin:4px 20px 12px;display:flex;align-items:center;gap:8px;padding:0 12px;background:var(--group);border-radius:14px;color:var(--muted);font-size:16px}
.settings-search{position:absolute;left:20px;right:20px;bottom:30px;z-index:3}
.settings-search .searchbar{height:56px;margin:0;border-radius:30px;background:#f5f5f5c7;border:1px solid #ffffffb8;box-shadow:inset 0 1px 2px #fff,0 4px 18px #20232d17;backdrop-filter:blur(26px) saturate(1.7);padding:0 18px}
.channels{display:flex;align-items:center;gap:6px;padding:0 20px 10px;height:49px;white-space:nowrap;overflow:hidden}
.channel{font-size:15px;font-weight:400;line-height:20px;padding:8px 13px;color:var(--muted);border-radius:20px}
.channel.active{color:var(--text);font-weight:600;background:#77778413}
.home-scroll{height:720px;padding:12px 20px 80px;overflow:hidden}
.video-grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:24px 12px}
.video-card{min-width:0}.video-card.featured{grid-column:1/-1}
.cover{aspect-ratio:16/9;position:relative;overflow:hidden;border-radius:14px}
.featured .cover{border-radius:20px}.landscape{width:100%;height:100%;display:block}
.duration{position:absolute;right:8px;bottom:8px;background:#0009;color:#fff;font-size:10px;font-weight:500;padding:3px 5px;border-radius:5px;font-variant-numeric:tabular-nums}
.video-card h3{font-size:15px;line-height:22px;font-weight:500;margin:10px 0 6px;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden}
.video-card.featured h3{font-size:20px;line-height:28px;font-weight:600;margin-top:12px}
.meta{display:flex;align-items:center;gap:10px;font-size:12px;line-height:18px;color:var(--muted);overflow:hidden}
.meta span{display:flex;align-items:center;gap:4px;white-space:nowrap}
.system-tabs{position:absolute;left:20px;right:20px;bottom:30px;height:64px;display:flex;gap:12px;z-index:3}
.tab-rail{background:#f5f5f5b8;border:1px solid #ffffffb8;box-shadow:inset 0 1px 2px #fff,0 4px 18px #20232d17;backdrop-filter:blur(26px) saturate(1.7)}
.tab-rail{display:flex;flex:1;border-radius:36px;padding:5px}
.tab{flex:1;display:flex;gap:4px;justify-content:center;align-items:center;flex-direction:column;border-radius:28px;color:#73777a}
.tab small{font-size:10px;line-height:12px}.tab.selected{background:#737b7814;color:var(--tint)}
.screen:after{content:"";height:5px;width:140px;background:var(--text);border-radius:5px;position:absolute;bottom:8px;left:145px;z-index:4}
.player{height:242px;position:relative;background:#000;overflow:hidden}
.bullet{position:absolute;color:#fff;font-size:15px;font-weight:500;white-space:nowrap;text-shadow:0 1px 2px #152b2b,1px 0 #152b2b}
.b1{top:30px;left:220px}.b2{top:78px;left:55px}
.transport{height:40px;display:flex;align-items:center;gap:10px;padding:0 12px;color:var(--text)}
.time{font-size:11px;color:var(--muted);font-variant-numeric:tabular-nums}
.progress{height:3px;flex:1;background:var(--line);border-radius:4px;position:relative}
.progress i{display:block;height:100%;width:18%;background:var(--tint);border-radius:4px}
.transport .progress:after{content:"";height:12px;width:12px;border-radius:50%;background:var(--tint);position:absolute;left:18%;top:-4.5px}
.segmented{display:flex;height:32px;border-radius:9px;margin:5px 8px 12px;background:var(--group);padding:3px}
.segmented span{width:50%;text-align:center;line-height:26px;font-size:13px}
.segmented .picked{background:var(--surface);border-radius:7px;font-weight:500;box-shadow:0 1px 3px #0002}
.video-info{padding:0 20px;overflow:hidden;height:510px}
.metadata-title{display:flex;align-items:flex-start;gap:12px}.metadata-title svg{flex-shrink:0;margin-top:8px;color:var(--muted)}
h2{font-size:20px;font-weight:600;line-height:28px;margin:0 0 10px;flex:1}
.stats{display:flex;align-items:center;gap:6px;font-size:12px;white-space:nowrap}
.online{font-size:12px;margin:14px 0 9px}
.detail-controls{display:flex;align-items:center;gap:16px;min-height:46px}
.dm-toggle{height:32px;padding:0 10px;display:flex;align-items:center;gap:5px;border-radius:8px;background:#77778013;color:var(--tint);font-size:14px}
hr{border:0;border-top:1px solid var(--line);margin:10px 0}
.description-row{display:flex;gap:9px;align-items:center;height:36px;color:var(--muted);font-size:14px}
.owner{display:flex;gap:10px;align-items:center;min-height:55px;font-size:15px}.owner b{font-weight:500}
.follow{color:var(--tint);font-size:13px;background:#006d3b0e;padding:6px 16px;border-radius:8px}
.episode,.listen-row{display:flex;align-items:center;gap:12px;font-size:14px;height:43px}
.listen-row{color:var(--muted)}
.engagement{display:flex;justify-content:space-around;border-top:1px solid var(--line);padding:16px 0;margin-top:10px;color:var(--muted)}
.engagement>span{display:flex;flex-direction:column;align-items:center;gap:7px}.engagement small{font-size:11px}
.search-kind{display:flex;align-items:center;justify-content:space-between;padding:0 20px 5px;height:38px;font-size:14px}
.search-kind>span{display:flex;align-items:center;gap:7px}.search-list{height:650px;overflow:hidden;padding:0 20px}
.search-result{display:flex;align-items:center;gap:13px;padding:16px 0;border-bottom:1px solid var(--line);min-height:120px}
.result-cover{width:133px;height:76px;position:relative;overflow:hidden;border-radius:12px;flex-shrink:0}
.result-text{min-width:0}.search-result h4{font-size:15px;line-height:22px;font-weight:400;margin:0 0 7px}.search-result .small{line-height:18px}
.form-scroll,.profile-scroll{height:756px;background:var(--group);padding:0 20px 100px;overflow:hidden}
.profile-scroll{padding-top:8px}.profile-header{padding:6px 0 28px}
.account-person{display:flex;align-items:center;gap:16px}.avatar{height:64px;width:64px;border-radius:50%;display:flex;align-items:center;justify-content:center;background:#e5e7ed;color:#a3a8b3}
.account-person b{font-size:22px;font-weight:600}.account-person small{display:block;color:var(--muted);font-size:13px;margin-top:5px}.account-person>svg{color:#b8bbc2}
.account-stats{display:flex;justify-content:space-around;margin-top:22px}
.account-stats span{display:flex;flex-direction:column;align-items:center;gap:5px}.account-stats b{font-size:20px;font-weight:600}.account-stats small{font-size:12px;color:var(--muted)}
.experience{display:flex;justify-content:space-between;margin-top:22px;font-size:11px;color:var(--muted)}
.profile-progress{height:3px;background:#d9dee0;margin-top:8px;border-radius:3px}.profile-progress i{display:block;height:3px;background:var(--tint);width:56%;border-radius:3px}
.section-title{font-size:12px;color:var(--muted);padding:12px 16px 8px}.section{background:var(--surface);border-radius:16px;overflow:hidden;margin-bottom:20px}
.row{height:52px;margin-left:16px;padding-right:14px;display:flex;align-items:center;justify-content:space-between;gap:8px;font-size:16px}
.row:not(:last-child){border-bottom:1px solid var(--line)}.row-label{display:flex;align-items:center;gap:12px}
.row-tail{display:flex;align-items:center;gap:9px;color:#b6b7bc;flex-shrink:0}.row-value{font-size:15px;color:var(--muted)}
.settings-icon{height:29px;width:29px;border-radius:7px;color:white;display:flex;align-items:center;justify-content:center;flex-shrink:0}
.toggle{height:31px;width:51px;border-radius:20px;background:#dadbe0;position:relative;display:inline-block}
.toggle:after{content:"";height:27px;width:27px;border-radius:50%;background:white;position:absolute;top:2px;left:2px;box-shadow:0 1px 3px #0002}.toggle.on{background:#34c759}.toggle.on:after{left:22px}
.slider{margin:2px 16px 20px;height:4px;background:#d7d9df;border-radius:5px;position:relative}.slider i{display:block;height:100%;width:96%;background:var(--tint);border-radius:5px}.slider:after{content:"";position:absolute;right:0;top:-9px;height:23px;width:23px;background:#fff;border-radius:50%;box-shadow:0 1px 4px #0003}
.shortcuts{display:flex;padding:10px 4px 13px}.shortcuts>span{display:flex;align-items:center;flex-direction:column;justify-content:center;gap:12px;min-height:72px;width:25%;color:var(--icon)}.shortcuts small{font-size:12px;color:var(--text)}
.folder-shelf{display:flex;gap:12px;padding:15px;overflow:hidden}.folder-shelf article{width:164px;flex-shrink:0}.folder-shelf .landscape{height:96px;border-radius:10px}.folder-shelf b{font-size:14px;line-height:22px;display:block;font-weight:500;margin-top:6px}.folder-shelf small{font-size:11px;display:block;line-height:17px;color:var(--muted)}
.fullscreen{width:932px;height:430px;position:relative;overflow:hidden;color:#fff;background:#000}
.fullscreen-image{position:absolute;inset:0}.full-tools{position:absolute;top:18px;right:22px;display:flex;gap:10px}
.glass-circle{height:40px;width:40px;border-radius:50%;display:flex;align-items:center;justify-content:center;background:#142d3866;border:1px solid #fff5;box-shadow:inset 0 1px 1px #fff6,0 3px 10px #0003;backdrop-filter:blur(18px) saturate(1.4)}
.full-transport{position:absolute;bottom:25px;left:22px;right:22px;height:52px;border-radius:30px;display:flex;align-items:center;gap:18px;padding:0 18px;background:#122a2885;border:1px solid #fff5;box-shadow:inset 0 1px 2px #fff5,0 3px 14px #0004;backdrop-filter:blur(22px) saturate(1.5)}
.full-transport .time{color:#fff;font-size:13px}.full-transport .progress{background:#ffffff38}.full-transport .progress i{background:#c9e7cc}
.wide-indicator{position:absolute;bottom:7px;left:396px;height:4px;width:140px;background:#fff;border-radius:5px}
.dark .tab-rail{background:#25252aaf;border-color:#ffffff24;box-shadow:inset 0 1px 1px #fff2,0 4px 18px #0006}.dark .tab.selected{background:#ffffff13}.dark .channel.active{background:#ffffff14}.dark .toolbar-group,.dark .nav-back{background:#28282b}.dark .profile-progress{background:#333}
body.gallery{background:#edf0f2;color:#202328;min-width:1446px}
.gallery-header{margin:42px auto 26px;display:flex;align-items:flex-end;justify-content:space-between;max-width:1346px}
.gallery-header h1{font-size:29px;letter-spacing:-.5px;font-weight:600;margin:0 0 8px}.gallery-header p{font-size:13px;color:#717780;margin:0}.gallery-header a{font-size:13px;color:#596671;text-decoration:none;margin-left:16px}
.gallery-grid{display:flex;gap:28px;width:max-content;margin:0 auto 38px;align-items:flex-start}
.preview-card{width:430px}.preview-label{font-size:14px;font-weight:500;margin:0 0 13px;color:#545c64}
.device{width:430px;height:932px;overflow:hidden;border-radius:45px;outline:5px solid #1b1c20;box-shadow:0 20px 55px #15232d18;background:white}
.preview-card a{color:inherit;text-decoration:none}.gallery-footer{font-size:11px;color:#838b93;text-align:center;margin-bottom:28px}
"""

def document(body,extra=""):
    return '<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>PiliPlus 原生布局预览</title><style>'+CSS+'</style><body'+extra+'>'+body+'</body></html>'

for name,render in [("home",home),("video",video),("search",search),("profile",profile),("settings",settings)]:
    body='<main class="screen">'+status()+render()+'</main>'
    (OUT/(name+'.html')).write_text(document(body),encoding='utf-8')
    (OUT/(name+'-dark.html')).write_text(document(body,' class="dark"'),encoding='utf-8')
(OUT/'fullscreen.html').write_text(document(fullscreen()),encoding='utf-8')

def gallery(names):
    width=len(names)*430+(len(names)-1)*28
    cards=''.join('<div class="preview-card"><div class="preview-label">'+TITLES[name]+'</div><a href="'+name+'.html"><div class="device"><iframe title="'+TITLES[name]+'" src="'+name+'.html" width="430" height="932" style="border:0;display:block;pointer-events:none" scrolling="no"></iframe></div></a></div>' for name in names)
    page=document('<header class="gallery-header"><div><h1>PiliPlus · iOS 原生界面</h1><p>按当前源码对照渲染 · 示例内容与材质示意 · 非模拟器或真机截图</p></div><nav><a href="overview.html">全部界面</a><a href="home-dark.html">深色首页</a><a href="fullscreen.html">全屏播放</a></nav></header><main class="gallery-grid">'+cards+'</main><footer class="gallery-footer">系统 Tab 与独立搜索 · 内容优先 · 分组表单</footer>',' class="gallery"')
    return page.replace('min-width:1446px',f'min-width:{width+100}px').replace('max-width:1346px',f'max-width:{width}px')

for name,scenes in [('overview',['home','video','search','profile','settings']),('overview-main',['home','video','settings']),('overview-extra',['search','profile'])]:
    (OUT/(name+'.html')).write_text(gallery(scenes),encoding='utf-8')
provenance={
 "kind":"source-referenced-layout-preview","runtimeScreenshot":False,
 "content":"Local fictional sample titles, accounts, covers, progress and counters; no user credentials or account requests",
 "styling":"CSS approximation of current native iOS 27 layout and Liquid Glass; not an iOS rendering engine",
 "defaultPalette":{"lightPrimary":"#006d3b","darkPrimary":"#7dda9a","method":"Actual ThemeSeeds.palette(ThemeSeeds.previous(nil),style:10) executed against ColorKit"},
 "revision":subprocess.check_output(['git','-C',str(ROOT),'rev-parse','HEAD']).decode().strip(),
 "designReferences":["https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass","https://developer.apple.com/design/human-interface-guidelines/tab-bars","https://developer.apple.com/design/human-interface-guidelines/search-fields"],
 "screens":{name:{"title":TITLES[name],"viewport":{"width":932,"height":430} if name=="fullscreen" else {"width":430,"height":932},"sources":{"Sources/PiliNative/"+path:hashlib.sha256((ROOT/'Sources/PiliNative'/path).read_bytes().replace(b'\r\n',b'\n')).hexdigest() for path in paths}} for name,paths in SOURCES.items()},
}
(OUT/'provenance.json').write_text(json.dumps(provenance,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
print(OUT)
