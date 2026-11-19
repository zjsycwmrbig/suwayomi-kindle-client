# Suwayomi Kindle Client

面向 Kindle 的独立 KOReader 漫画客户端。它通过 Suwayomi Server GraphQL API 获取书架、章节、下载和阅读状态。

当前版本为 `0.1.0`，包含：

- 书架、浏览、设置三个底部标签。
- 透明的插件自有 SVG 图标，不依赖带白底的图标缓存。
- 顶部居中标题、左上返回和扁平列表式「设置 → 连接与验证」二级页面。
- Suwayomi 地址、认证方式和账号密码配置。
- 保存配置与真实 GraphQL 连接验证。
- 独立的 `suwayomi_kindle.lua` 设置文件，不与旧 Suwayomi 插件共享状态。

本机开发环境可把仓库直接链接到 KOReader 测试配置的插件目录：

```sh
ln -s /Users/xiyu/code/suwayomi-kindle-client \
  /Users/xiyu/code/koreader-test-profile/plugins/suwayomi-kindle.koplugin
```

纯配置测试：

```sh
luajit tests/run.lua
```

连接与设置持久化测试需要在 KOReader 自带 LuaJIT 环境中运行：

```sh
cd /Users/xiyu/code/koreader-emulator/KOReader.app/Contents/koreader
./luajit -e 'require("setupkoenv"); dofile("/Users/xiyu/code/suwayomi-kindle-client/tests/connection.lua")'
```

完整产品范围和后续里程碑见[功能规格与验收用例](docs/功能规格.md)。
