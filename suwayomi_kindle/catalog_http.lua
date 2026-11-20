local json = require("dkjson")

local function post(host, path, payload, service)
    local https = require("ssl.https")
    local lfs = require("libs/libkoreader-lfs")
    local ca = "/etc/ssl/certs/ca-certificates.crt"
    if not lfs.attributes(ca) then ca = "/etc/ssl/cert.pem" end
    local tls = https.tcp{verify="peer", cafile=ca}
    local body = json.encode(payload)
    local chunks, size = {}, 0
    local timeout = https.TIMEOUT
    https.TIMEOUT = 8
    local called, ok, code = pcall(require("socket.http").request, {
        url="https://" .. host .. path, method="POST", redirect=false,
        headers={ ["User-Agent"]="zjsycwmrbig/suwayomi-kindle-client (https://github.com/zjsycwmrbig/suwayomi-kindle-client)", ["Content-Type"]="application/json", ["Content-Length"]=tostring(#body) },
        source=require("ltn12").source.string(body),
        create=function()
            local conn = tls()
            local connect = conn.connect
            function conn:connect(name, port)
                if name ~= host then return nil, "unexpected host" end
                local ok, err = connect(self, name, port)
                if not ok then return nil, err end
                local cert = self.sock:getpeercertificate()
                local san = cert and cert:extensions()["2.5.29.17"]
                for _, dns in ipairs(san and san.dNSName or {}) do
                    if dns:lower()==host or dns:lower()==host:gsub("^[^.]+%.", "*.") then return 1 end
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
    if called and ok and code == 429 then return nil, service .. " 请求过多，请稍后再试。" end
    if not called or not ok or code ~= 200 then return nil, "无法获取 " .. service .. " 数据。" end
    local decoded = json.decode(table.concat(chunks))
    if type(decoded) ~= "table" or type(decoded.data) ~= "table" or decoded.errors then
        return nil, service .. " 响应不完整。"
    end
    return decoded.data
end

return post
