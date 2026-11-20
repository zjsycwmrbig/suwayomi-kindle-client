-- Boundary: Suwayomi connection verification.
--
-- Responsibility: build minimal GraphQL requests, authenticate when requested,
-- bound the response, and classify failures without exposing credentials.
-- Owned state: none in the UI process.
-- Dependencies: LuaSocket, LuaSec, ltn12, KOReader JSON.

local json = require("dkjson")
local Config = require("suwayomi_kindle/config")

local Connection = {}

local MAX_RESPONSE_BYTES = 256 * 1024
local REQUEST_TIMEOUT_SECONDS = 15
local BASE64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local VERIFY_QUERY = [[
query ConnectionCheck {
  categories(first: 1) {
    nodes { id }
  }
}
]]

local LOGIN_MUTATION = [[
mutation ConnectionLogin($input: LoginInput!) {
  login(input: $input) {
    accessToken
    refreshToken
  }
}
]]

local SOURCES_QUERY = [[query KindleSources {
  sources { nodes { id name displayName lang supportsLatest } }
}]]
local LIBRARY_QUERY = [[query KindleLibrary($first: Int!, $offset: Int!) {
  mangas(filter: {inLibrary: {equalTo: true}}, first: $first, offset: $offset,
      order: [{by: ID, byType: ASC}]) {
    totalCount pageInfo { hasNextPage }
    nodes { id title author inLibraryAt unreadCount chapters { totalCount } thumbnailUrl source { displayName } }
  }
}]]
local SOURCE_MANGA_QUERY = [[mutation KindleSourceManga($input: FetchSourceMangaInput!) {
  fetchSourceManga(input: $input) {
    hasNextPage mangas { id title author description chapters { totalCount } thumbnailUrl inLibrary }
  }
}]]
local ADD_MUTATION = [[mutation KindleAdd($input: UpdateMangaInput!) {
  updateManga(input: $input) { manga { id inLibrary inLibraryAt } }
}]]

local function base64_encode(input)
    local result = {}
    local index = 1
    while index <= #input do
        local a = input:byte(index) or 0
        local b = input:byte(index + 1) or 0
        local c = input:byte(index + 2) or 0
        local remaining = math.min(3, #input - index + 1)
        local value = a * 65536 + b * 256 + c
        local c1 = math.floor(value / 262144) % 64 + 1
        local c2 = math.floor(value / 4096) % 64 + 1
        local c3 = math.floor(value / 64) % 64 + 1
        local c4 = value % 64 + 1
        result[#result + 1] = BASE64_ALPHABET:sub(c1, c1)
        result[#result + 1] = BASE64_ALPHABET:sub(c2, c2)
        result[#result + 1] = remaining < 2 and "=" or BASE64_ALPHABET:sub(c3, c3)
        result[#result + 1] = remaining < 3 and "=" or BASE64_ALPHABET:sub(c4, c4)
        index = index + 3
    end
    return table.concat(result)
end

local function endpoint(server_url)
    return (server_url or ""):gsub("/+$", "") .. "/api/graphql"
end

local function decode(body)
    local ok, value = pcall(json.decode, body)
    if not ok or type(value) ~= "table" then
        return nil
    end
    return value
end

local function graphql_failure(payload)
    local errors = payload and payload.errors
    if type(errors) ~= "table" or #errors == 0 then
        return nil
    end

    local messages = {}
    for _, err in ipairs(errors) do
        if type(err) == "table" and type(err.message) == "string" then
            messages[#messages + 1] = err.message:lower()
        end
    end
    local combined = table.concat(messages, "\n")
    if combined:find("unauthorized", 1, true)
        or combined:find("forbidden", 1, true)
        or combined:find("authentication", 1, true)
    then
        return "认证失败，请检查用户名、密码和认证方式。"
    end
    if combined:find("not found",1,true) or combined:find("no such",1,true) then return "服务器找不到该记录。" end
    if combined:find("validation",1,true) or combined:find("unknown field",1,true) then return "服务器接口或字段不兼容。" end
    return "服务器返回了 GraphQL 错误。"
end

local function perform_http_request(url, request_body, headers, size_limit)
    local ltn12 = require("ltn12")
    local client = url:match("^https://") and require("ssl.https") or require("socket.http")
    local chunks = {}
    local total = 0

    headers = headers or {}
    if request_body then
        headers["Content-Type"] = "application/json"
        headers["Content-Length"] = tostring(#request_body)
    end

    local ok, code, err = client.request{
        url = url,
        method = request_body and "POST" or "GET",
        headers = headers,
        source = request_body and ltn12.source.string(request_body),
        sink = function(chunk, err_chunk)
            if chunk then
                total = total + #chunk
                if total > (size_limit or MAX_RESPONSE_BYTES) then
                    return nil, "response too large"
                end
                chunks[#chunks + 1] = chunk
            elseif err_chunk then
                return nil, err_chunk
            end
            return 1
        end,
        redirect = false,
        timeout = REQUEST_TIMEOUT_SECONDS,
    }

    if not ok then
        return {
            ok = false,
            error = tostring(code or err or "network failure"),
        }
    end
    if type(code) ~= "number" then
        return {
            ok = false,
            error = tostring(code or err or "invalid HTTP response"),
        }
    end

    return {
        ok = code == 200,
        status = code,
        body = table.concat(chunks),
    }
end

local function auth_headers(settings, session)
    local headers = {}
    if settings.auth_method == "basic_auth" then
        headers.Authorization = "Basic " .. base64_encode(
            tostring(settings.username or "") .. ":" .. tostring(settings.password or "")
        )
    elseif session and session.access_token then
        headers.Authorization = "Bearer " .. session.access_token
    end
    return headers
end

local function request_graphql(settings, query, variables, request_fn, session)
    local body = json.encode({
        query = query,
        variables = variables,
    })
    return (request_fn or perform_http_request)(endpoint(settings.server_url), body, auth_headers(settings, session))
end

local function valid_token(value)
    return type(value) == "string"
        and value ~= ""
        and #value <= 16384
        and not value:find("[\r\n]")
end

local function verify_payload(response)
    if not response.ok then
        if response.status == 401 or response.status == 403 then
            return { ok = false, error = "认证失败，请检查用户名、密码和认证方式。" }
        elseif response.status == 404 then
            return { ok = false, error = "没有找到 Suwayomi GraphQL 接口。" }
        elseif response.status then
            return { ok = false, error = "服务器返回 HTTP " .. tostring(response.status) .. "。" }
        end
        local message = tostring(response.error or "")
        if message:lower():find("timeout", 1, true) then
            return { ok = false, error = "连接超时，请检查地址和网络。" }
        end
        return { ok = false, error = "无法连接服务器，请检查地址和 WiFi。" }
    end

    local payload = decode(response.body)
    if not payload then
        return { ok = false, error = "服务器返回了非 GraphQL 响应。" }
    end
    local failure = graphql_failure(payload)
    if failure then
        return { ok = false, error = failure }
    end

    local categories = payload.data and payload.data.categories
    local nodes = categories and categories.nodes
    if type(nodes) ~= "table" then
        return { ok = false, error = "服务器 API 不兼容，缺少 categories 数据。" }
    end
    return {
        ok = true,
        category_count = #nodes,
        message = "连接验证成功。",
    }
end

local function login(settings, request_fn)
    if settings.auth_method ~= "ui_login" then return nil end
    local response = request_graphql(settings, LOGIN_MUTATION, {
        input = {username = settings.username, password = settings.password},
    }, request_fn)
    if not response.ok then return nil, verify_payload(response).error end
    local payload = decode(response.body)
    local failure = graphql_failure(payload)
    if failure then return nil, failure end
    local token = payload and payload.data and payload.data.login and payload.data.login.accessToken
    if not valid_token(token) then return nil, "账号登录响应无效。" end
    local session = {access_token = token}
    return session
end

-- One session per operation, reused across its pages.
function Connection.open(settings, request_fn)
    local config, err = Config.normalize(settings)
    if not config or config.server_url == "" then return nil, err or "请先填写服务器地址。" end
    local session
    if config.auth_method == "ui_login" then
        session, err = login(config, request_fn)
        if not session then return nil, err end
    end
    return setmetatable({settings = config, session = session, transport = request_fn}, {__index = Connection})
end

function Connection.test(settings, request_fn)
    local client, err = Connection.open(settings, request_fn)
    if not client then return {ok = false, error = err} end
    return verify_payload(client:send(VERIFY_QUERY))
end

function Connection:send(query, variables)
    return request_graphql(self.settings, query, variables, self.transport, self.session)
end

function Connection:request(query, variables)
    local response = self:send(query, variables)
    if not response.ok then return nil, verify_payload(response).error end
    local payload = decode(response.body)
    local err = graphql_failure(payload)
    if err or not payload or type(payload.data) ~= "table" then
        return nil, err or "服务器响应不完整。"
    end
    return payload.data
end

local function string_field(value)
    return type(value) == "string" and value or ""
end

local function is_array(nodes)
    return type(nodes) == "table" and getmetatable(nodes) and getmetatable(nodes).__jsontype == "array"
end

local function manga_rows(nodes)
    if not is_array(nodes) then return nil end
    local rows = {}
    for i, item in ipairs(nodes) do
        if type(item) ~= "table" or not tonumber(item.id) or string_field(item.title) == "" then return nil end
        rows[i] = {id = tostring(item.id), title = item.title, author = string_field(item.author),
            thumbnail = string_field(item.thumbnailUrl), description = string_field(item.description),
            source = type(item.source) == "table" and string_field(item.source.displayName) or "",
            chapters = type(item.chapters) == "table" and tonumber(item.chapters.totalCount) or nil,
            added = tonumber(item.inLibraryAt), unread = tonumber(item.unreadCount), in_library = item.inLibrary == true}
    end
    return rows
end

function Connection:sources(language)
    local data, err = self:request(SOURCES_QUERY)
    local nodes = data and data.sources and data.sources.nodes
    if not is_array(nodes) then return nil, err or "源列表响应无效。" end
    local sources = {}
    for _, item in ipairs(nodes) do
        local lang = string_field(item.lang):lower():gsub("_", "-")
        if language == "all" or lang:match("^[^-]+") == language then
            if type(item.id) ~= "string" or item.id == "" then return nil, "漫画源标识无效。" end
            local name = string_field(item.displayName)
            sources[#sources + 1] = {id = item.id, name = name ~= "" and name or string_field(item.name),
                lang = lang, latest = item.supportsLatest == true}
        end
    end
    table.sort(sources, function(a, b)
        if a.name == b.name then return a.id < b.id end
        return a.name < b.name
    end)
    return {sources = sources}
end

function Connection:sourcePage(input)
    local data, err = self:request(SOURCE_MANGA_QUERY, {input = {
        source = input.source.id, type = input.mode, page = input.page, query = input.search,
    }})
    local page = data and data.fetchSourceManga
    local rows = page and manga_rows(page.mangas)
    if not rows or type(page.hasNextPage) ~= "boolean" then return nil, err or "漫画列表响应无效。" end
    for _, item in ipairs(rows) do item.source = input.source.name end
    return {mangas = rows, has_next = page.hasNextPage}
end

function Connection:libraryPage(offset, limit)
    local data, err = self:request(LIBRARY_QUERY, {offset = offset, first = limit})
    local page = data and data.mangas
    local rows = page and manga_rows(page.nodes)
    if not rows or type(page.totalCount) ~= "number" or type(page.pageInfo) ~= "table"
        or type(page.pageInfo.hasNextPage) ~= "boolean" then
        return nil, err or "书架分页响应不完整。"
    end
    return {rows = rows, total = page.totalCount, more = page.pageInfo.hasNextPage}
end

function Connection:setMembership(id, enabled)
    local data, err = self:request(ADD_MUTATION, {input = {id = tonumber(id), patch = {inLibrary = enabled}}})
    local manga = data and data.updateManga and data.updateManga.manga
    if not manga or tostring(manga.id) ~= id or manga.inLibrary ~= enabled then
        return nil, err or "服务器没有确认书架变更。"
    end
    return true, nil, tonumber(manga.inLibraryAt)
end

function Connection:addManga(id)
    return self:setMembership(id, true)
end

function Connection:manga(id)
    local fields = " id title initialized firstUnreadChapter { id } author description thumbnailUrl unreadCount inLibrary chapters { totalCount } source { displayName } "
    local data, err = self:request("query($id:Int!){manga(id:$id){" .. fields .. "}}", {id = tonumber(id)})
    local item = data and data.manga
    if item and item.initialized == false then
        data, err = self:request("mutation($id:Int!){fetchManga(input:{id:$id}){manga{" .. fields .. "}}}", {id = tonumber(id)})
        item = data and data.fetchManga and data.fetchManga.manga
    end
    if not item or tostring(item.id) ~= id then return nil, err or "没有找到漫画。" end
    local rows = manga_rows(setmetatable({item}, {__jsontype = "array"}))
    if not rows then return nil, "漫画详情响应无效。" end
    rows[1].first_unread_id = item.firstUnreadChapter and item.firstUnreadChapter.id or false
    return rows[1]
end

function Connection:chapterPage(id, offset, limit)
    local data, err = self:request([[query($id:Int!,$first:Int!,$offset:Int!){
        chapters(filter:{mangaId:{equalTo:$id}},first:$first,offset:$offset,
        order:[{by:SOURCE_ORDER,byType:ASC},{by:ID,byType:ASC}]){
        totalCount pageInfo{hasNextPage} nodes{id name scanlator isRead lastPageRead}}}]],
        {id = tonumber(id), offset = offset, first = limit})
    local page = data and data.chapters
    if not page or not is_array(page.nodes) or type(page.totalCount) ~= "number"
        or not page.pageInfo then return nil, err or "目录响应无效。" end
    return page
end

function Connection:chapterOwners(ids)
    local data,err = self:request([[query($ids:[Int!]!){
        chapters(first:32,filter:{id:{in:$ids}}){nodes{id manga{id}}}}]],{ids=ids})
    local nodes = data and data.chapters and data.chapters.nodes
    if not is_array(nodes) then return nil,err or "服务器未返回章节归属。" end
    local owners = {}
    for _,node in ipairs(nodes) do owners[node.id]=tostring(node.manga.id) end
    return owners
end

function Connection:updateRecord(id, read, page, manga)
    local data, err = self:request([[mutation($input:UpdateChapterInput!){
        updateChapter(input:$input){chapter{id isRead lastPageRead manga{id}}}}]],
        {input = {id = id, patch = {isRead = read, lastPageRead = page}}})
    local row = data and data.updateChapter and data.updateChapter.chapter
    if not row or row.id ~= id or (read ~= nil and row.isRead ~= read)
        or (page ~= nil and row.lastPageRead ~= page)
        or (manga and tostring(row.manga and row.manga.id) ~= manga) then
        return nil, err or "服务器未确认该章节的阅读记录。"
    end
    return true
end

function Connection:setRead(id, read)
    return self:updateRecord(id,read)
end

function Connection:pageImage(path)
    if type(path) ~= "string" then return end
    local base = self.settings.server_url
    local url
    if path:sub(1,1) == "/" and path:sub(2,2) ~= "/" then url = base .. path
    elseif path:match("^https?://") then url = path
    elseif path:match("^api/") then url = base .. "/" .. path
    else return end
    local headers = url:sub(1,#base+1) == base .. "/" and auth_headers(self.settings, self.session) or {}
    local r = (self.transport or perform_http_request)(url, nil, headers, 24 * 1024 * 1024)
    if not r.ok then return nil,verify_payload(r).error end
    return r.body
end

function Connection:thumbnail(id)
    if not id:match("^%d+$") then return end
    local url = self.settings.server_url .. "/api/v1/manga/" .. id .. "/thumbnail"
    local response = perform_http_request(url, nil, auth_headers(self.settings, self.session), 1024 * 1024)
    return response.ok and response.body or nil
end

Connection._verify_payload = verify_payload
return Connection
