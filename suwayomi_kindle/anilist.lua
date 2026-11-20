local json = require("dkjson")
local AniList = {}
local host = "graphql.anilist.co"
local fields = [[id format title{english native romaji} synonyms]]

local function request(query, variables)
    local https = require("ssl.https")
    local lfs = require("libs/libkoreader-lfs")
    local ca = "/etc/ssl/certs/ca-certificates.crt"
    if not lfs.attributes(ca) then ca = "/etc/ssl/cert.pem" end
    local tls = https.tcp{verify="peer", cafile=ca}
    local body = json.encode{query=query, variables=variables}
    local chunks, size = {}, 0
    local timeout = https.TIMEOUT
    https.TIMEOUT = 8
    local called, ok, code = pcall(require("socket.http").request, {
        url="https://" .. host, method="POST", redirect=false,
        headers={ ["Content-Type"]="application/json", ["Content-Length"]=tostring(#body) },
        source=require("ltn12").source.string(body),
        create=function()
            local conn = tls()
            local connect = conn.connect
            function conn:connect(name, port)
                if name ~= host then return nil, "unexpected host" end
                connect(self, name, port)
                local cert = self.sock:getpeercertificate()
                local san = cert and cert:extensions()["2.5.29.17"]
                for _, dns in ipairs(san and san.dNSName or {}) do
                    if dns:lower()==host or dns:lower()=="*.anilist.co" then return 1 end
                end
                self.sock:close()
                return nil, "certificate hostname mismatch"
            end
            return conn
        end,
        sink=function(chunk, err)
            if err then return nil, err end
            if chunk then
                size = size + #chunk
                if size > 192*1024 then return nil, "response too large" end
                chunks[#chunks+1] = chunk
            end
            return 1
        end,
    })
    https.TIMEOUT = timeout
    if called and ok and code == 429 then return nil, "AniList 请求过多，请稍后再试。" end
    if not called or not ok or code ~= 200 then return nil, "无法获取 AniList 数据。" end
    local decoded = json.decode(table.concat(chunks))
    if not decoded or type(decoded.data)~="table" then return nil, "AniList 响应不完整。" end
    return decoded.data
end

local function media(row)
    if type(row)~="table" or not tonumber(row.id) or type(row.title)~="table" then return end
    return {id=row.id, format=row.format, titles=row.title, synonyms=row.synonyms or {},
        title=row.title.english or row.title.romaji or row.title.native}
end

function AniList.recommend(id, title, limit, transport)
    local selection = [[id recommendations(page:1,perPage:$limit,sort:RATING_DESC){
        nodes{mediaRecommendation{type isAdult ]] .. fields .. [[}}}]]
    local query
    if id then
        query = "query($id:Int!,$limit:Int!){Media(id:$id,type:MANGA){" .. selection .. "}}"
    else
        query = [[query($title:String!,$limit:Int!){Page(perPage:1){media(type:MANGA,
            format_in:[MANGA,ONE_SHOT],isAdult:false,search:$title){]] .. selection .. "}}}"
    end
    local data, err = (transport or request)(query, {id=id,title=not id and title or nil,limit=limit})
    if not data then return nil, err end
    local origin = data.Media or (data.Page and data.Page.media and data.Page.media[1])
    if not origin then return nil, "AniList 未找到对应作品。" end
    id = origin.id
    local nodes = origin.recommendations and origin.recommendations.nodes
    if not id or not nodes then return nil, "AniList 未返回推荐列表。" end
    local items, seen = {}, {[id]=true}
    for _, node in ipairs(nodes) do
        local row = node.mediaRecommendation
        local item = media(row)
        if item and item.title and row.type=="MANGA" and not row.isAdult
            and (item.format=="MANGA" or item.format=="ONE_SHOT") and not seen[item.id] then
            seen[item.id] = true
            items[#items+1] = item
        end
    end
    return {items=items, media=id, limit=limit, fetched_at=os.time()}
end

return AniList
