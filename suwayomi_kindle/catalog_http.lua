local json = require("dkjson")

local user_agent = "zjsycwmrbig/suwayomi-kindle-client (https://github.com/zjsycwmrbig/suwayomi-kindle-client)"
local max_bytes = 192 * 1024

-- LuaSocket connects directly. If the macOS emulator cannot reach a public
-- metadata service, retry through the HTTPS proxy configured in System Settings.
local function retry_via_system_proxy(url, body)
    local settings = io.popen("/usr/sbin/scutil --proxy", "r")
    if not settings then return end
    local config = settings:read("*a")
    settings:close()
    if not config:match("HTTPSEnable%s*:%s*1%s") then return end
    local host = config:match("HTTPSProxy%s*:%s*([^%s]+)")
    local port = tonumber(config:match("HTTPSPort%s*:%s*(%d+)"))
    if not host or not port or port < 1 or port > 65535 then return end
    if host:find(":", 1, true) and host:sub(1, 1) ~= "[" then host = "[" .. host .. "]" end
    local command = require("util").shell_escape{"/usr/bin/curl", "-q", "--silent",
        "--max-time", "8", "--max-filesize", tostring(max_bytes), "--proxy", "http://" .. host .. ":" .. port,
        "--user-agent", user_agent, "--header", "Content-Type: application/json", "--data-binary", body,
        "--write-out", "\n%{http_code}", url}
    local pipe = io.popen(command, "r")
    if not pipe then return end
    local response = pipe:read(max_bytes + 5) or ""
    pipe:close()
    local content, status = response:match("^(.*)\n(%d%d%d)$")
    return content, tonumber(status)
end

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
        headers={ ["User-Agent"]=user_agent, ["Content-Type"]="application/json", ["Content-Length"]=tostring(#body) },
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
                if size > max_bytes then return nil, "response too large" end
                chunks[#chunks+1] = chunk
            end
            return 1
        end,
    })
    https.TIMEOUT = timeout
    local response
    if (not called or not ok) and jit.os == "OSX" then
        response, code = retry_via_system_proxy("https://" .. host .. path, body)
        called, ok = response ~= nil, response ~= nil
    end
    if called and ok and code == 429 then return nil, service .. " 请求过多，请稍后再试。" end
    if not called or not ok or code ~= 200 then return nil, "无法获取 " .. service .. " 数据。" end
    local decoded = json.decode(response or table.concat(chunks))
    if type(decoded) ~= "table" or type(decoded.data) ~= "table" or decoded.errors then
        return nil, service .. " 响应不完整。"
    end
    return decoded.data
end

return post
