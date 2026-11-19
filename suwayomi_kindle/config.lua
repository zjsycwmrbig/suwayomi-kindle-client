-- Boundary: pure connection-configuration normalization.
--
-- Responsibility: validate URLs and authentication choices without reading
-- settings or performing network I/O.
-- Owned state: none.
-- Dependencies: none.

local Config = {}

Config.AUTH_METHODS = {
    none = {
        label = "无认证",
        description = "服务器未开启用户认证",
    },
    basic_auth = {
        label = "Basic Auth",
        description = "每次请求携带用户名和密码",
    },
    ui_login = {
        label = "账号登录",
        description = "使用 Suwayomi 用户账号登录",
    },
}

function Config.trim(value)
    return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

function Config.normalize_server_url(value)
    local url = Config.trim(value)
    if url == "" then
        return nil, "服务器地址不能为空。"
    end

    if not url:match("^[%a][%w+.-]*://") then
        url = "http://" .. url
    end

    local scheme, authority, path = url:match("^([%a][%w+.-]*)://([^/?#]+)([^?#]*)")
    if not scheme or not authority then
        return nil, "服务器地址格式不正确。"
    end

    scheme = scheme:lower()
    if scheme ~= "http" and scheme ~= "https" then
        return nil, "服务器地址只能使用 http 或 https。"
    end
    if authority:find("@", 1, true) then
        return nil, "请不要把用户名和密码写进服务器地址。"
    end
    if authority:find("%s") then
        return nil, "服务器地址中不能包含空格。"
    end

    path = path or ""
    path = path:gsub("/+$", "")
    path = path:gsub("/api/graphql$", "")
    path = path:gsub("/+$", "")

    local normalized = scheme .. "://" .. authority .. path
    local warning
    if scheme == "http" then
        warning = "当前使用 HTTP；账号和会话可能以明文传输，建议使用 HTTPS。"
    end
    return normalized, nil, warning
end

function Config.normalize(settings)
    settings = settings or {}
    local normalized = {
        server_url = "",
        auth_method = "none",
        username = Config.trim(settings.username),
        password = tostring(settings.password or ""),
    }

    local warnings = {}
    if Config.trim(settings.server_url) ~= "" then
        local server_url, url_error, url_warning = Config.normalize_server_url(settings.server_url)
        if not server_url then
            return nil, url_error
        end
        normalized.server_url = server_url
        normalized.url_warning = url_warning
        if normalized.url_warning then
            warnings[#warnings + 1] = normalized.url_warning
        end
    end

    local auth_method = tostring(settings.auth_method or "none")
    if not Config.AUTH_METHODS[auth_method] then
        return nil, "认证方式无效。"
    end
    normalized.auth_method = auth_method

    if auth_method ~= "none" and normalized.username == "" then
        return nil, "使用认证时必须填写用户名。"
    end
    if auth_method == "ui_login" and normalized.password == "" then
        return nil, "账号登录必须填写密码。"
    end
    if auth_method == "basic_auth" and normalized.password == "" then
        return nil, "使用 Basic Auth 时必须填写密码。"
    end

    normalized.warnings = warnings
    return normalized
end

function Config.auth_label(method)
    return (Config.AUTH_METHODS[method] or Config.AUTH_METHODS.none).label
end

return Config
