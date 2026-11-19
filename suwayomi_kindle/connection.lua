-- Boundary: Suwayomi connection verification.
--
-- Responsibility: build minimal GraphQL requests, authenticate when requested,
-- bound the response, and classify failures without exposing credentials.
-- Owned state: none in the UI process.
-- Dependencies: LuaSocket, LuaSec, ltn12, KOReader JSON.

local json = require("json")
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
    return "服务器返回了 GraphQL 错误。"
end

local function perform_http_request(url, request_body, headers)
    local ltn12 = require("ltn12")
    local client = url:match("^https://") and require("ssl.https") or require("socket.http")
    local chunks = {}
    local total = 0

    headers = headers or {}
    headers["Content-Type"] = "application/json"
    headers["Content-Length"] = tostring(#request_body)

    local ok, code, err = client.request{
        url = url,
        method = "POST",
        headers = headers,
        source = ltn12.source.string(request_body),
        sink = function(chunk, err_chunk)
            if chunk then
                total = total + #chunk
                if total > MAX_RESPONSE_BYTES then
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

local function request_graphql(settings, query, variables, request_fn)
    local body = json.encode({
        query = query,
        variables = variables or {},
    })
    local headers = {}
    if settings.auth_method == "basic_auth" then
        headers.Authorization = "Basic " .. base64_encode(
            tostring(settings.username or "") .. ":" .. tostring(settings.password or "")
        )
    end
    return (request_fn or perform_http_request)(endpoint(settings.server_url), body, headers)
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

function Connection.test(settings, request_fn)
    local normalized, normalize_error = Config.normalize(settings)
    if not normalized then
        return { ok = false, error = normalize_error }
    end
    if normalized.server_url == "" then
        return { ok = false, error = "请先填写服务器地址。" }
    end

    local response
    if normalized.auth_method == "ui_login" then
        local login_response = request_graphql(normalized, LOGIN_MUTATION, {
            input = {
                username = normalized.username,
                password = normalized.password,
            },
        }, request_fn)
        if not login_response.ok then
            return verify_payload(login_response)
        end
        local login_payload = decode(login_response.body)
        local login_failure = graphql_failure(login_payload)
        if login_failure then
            return { ok = false, error = login_failure }
        end
        local token = login_payload
            and login_payload.data
            and login_payload.data.login
            and login_payload.data.login.accessToken
        if not valid_token(token) then
            return { ok = false, error = "账号登录响应无效。" }
        end

        local body = json.encode({
            query = VERIFY_QUERY,
            variables = {},
        })
        response = (request_fn or perform_http_request)(endpoint(normalized.server_url), body, {
            Authorization = "Bearer " .. token,
        })
    else
        response = request_graphql(normalized, VERIFY_QUERY, nil, request_fn)
    end

    local result = verify_payload(response)
    result.server_url = normalized.server_url
    if result.ok then
        result.warnings = normalized.warnings
    end
    return result
end

Connection._endpoint = endpoint
Connection._base64_encode = base64_encode
Connection._verify_payload = verify_payload

return Connection
