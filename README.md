# Suwayomi Kindle Client

面向 Kindle 的独立 KOReader 漫画客户端。通过「工具 → 更多工具 → Suwayomi Kindle」打开，底部有书架、浏览、设置三个入口。

## 连接与使用

1. 在「设置 → 连接」输入 Suwayomi Server 地址，选择无认证、Basic Auth 或账号登录，点击「保存并验证」。
2. 进入「书架」。首次打开会从服务器拉取漫画，以后优先显示本地索引。点击标题左侧菜单打开抽屉，再点「从服务器刷新」可更新成员和摘要。列表和三列书架都显示封面、章节数和未读数。断网时仍能翻看已保存的书架和缓存封面。
3. 在「浏览」选择服务器已安装的漫画源，查看热门、最新或搜索结果。支持最新更新的源才会显示「最新」。浏览首页可以搜索漫画源，进入漫画源后可在页内输入框搜索漫画。热门、最新、刷新和详情页的加入书架操作位于左侧抽屉。点抽屉外的页面或左滑即可收起。
4. 底部标签切换栏正上方的 `<< < 页码/总页数 > >>` 支持首末页、前后翻页和点击页码跳转。漫画源尚未返回末页时总数显示为 `?`，点末页或跳到未访问页才会按需向后查找，期间可从菜单取消。

## 设置

| 入口 | 可选项 |
| --- | --- |
| 连接 | 地址、认证方式、账号、验证。密码默认隐藏，点击密码旁的「显示」或「隐藏」切换 |
| 下载 | 长按选择下载目录，最大并行数 1–3。已读文件可直接删除、保留最近 1／3／5／10 章或不删除，默认不删除 |
| 书架 | 列表或三列封面书架 |
| 浏览 | 可分页多选漫画源语言（中文含简繁），或选择全部语言，独立的列表或封面布局。默认中文 |

下载和清理策略在此版保存，实际执行随章节下载队列接入。

## 本地存储

每类设置在首次保存时分别写入 KOReader 的 `settings/suwayomi_kindle_<section>.lua`。已有的 `suwayomi_kindle.lua` 连接配置会自动沿用。每个服务器和账号有独立的 SQLite 漫画索引，位于数据目录的 `suwayomi_kindle/library/`。

刷新在后台每批读取 64 部，核对总数、分页结束标志和漫画 ID 唯一性后统一提交。失败时保留上次完整结果。翻页按标题和 ID 从本地按页读取。封面视图只为当前页加载缩略图，缓存位于 `cache/suwayomi_posters/`，使用 256 个有界缓存槽。

## 本机测试

测试配置中的插件目录可链接至仓库：

```sh
ln -s /Users/xiyu/code/suwayomi-kindle-client \
  /Users/xiyu/code/koreader-test-profile/plugins/suwayomi-kindle.koplugin
```

在仓库中运行 `luajit tests/run.lua`。连接、SQLite 和后台任务测试使用 KOReader 自带的 LuaJIT：

```sh
cd /Users/xiyu/code/koreader-emulator/KOReader.app/Contents/koreader
./luajit -e 'require("setupkoenv"); dofile("/Users/xiyu/code/suwayomi-kindle-client/tests/connection.lua"); dofile("/Users/xiyu/code/suwayomi-kindle-client/tests/catalog.lua")'
```

后续的章节目录、下载和阅读同步设计见[功能规格](docs/功能规格.md)。
