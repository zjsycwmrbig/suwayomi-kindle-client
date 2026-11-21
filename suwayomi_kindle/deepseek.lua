local json = require("dkjson")
local post = require("suwayomi_kindle/catalog_http")
local Flash = {model="deepseek-flash"}

local function key_path()
    return require("datastorage"):getSettingsDir() .. "/suwayomi_kindle_deepseek.key"
end

local function key()
    local file = io.open(key_path(), "rb")
    if not file then return end
    local value = file:read(512)
    file:close()
    return value and value:match("^%s*([%w_%-]+)%s*$")
end

function Flash.configured()
    return key() ~= nil
end

function Flash.save(value)
    if value == "" then
        if not Flash.configured() then return true end
        return os.remove(key_path())
    end
    if #value > 500 or not value:match("^[%w_%-]+$") then return nil, "密钥格式无效。" end
    local ffi = require("ffi")
    require("ffi/posix_h")
    local template = key_path() .. ".XXXXXX"
    local tmp = ffi.new("char[?]", #template+1, template)
    local fd = ffi.C.mkstemps(tmp, 0)
    if fd < 0 then return nil, "无法创建密钥文件。" end
    local written = ffi.C.write(fd, value, #value)
    local closed = ffi.C.close(fd)
    local path = ffi.string(tmp)
    if written == #value and closed == 0 and os.rename(path,key_path()) then return true end
    os.remove(path)
    return nil, "无法保存密钥。"
end

local function request(path,payload)
    local token = key()
    if not token then return nil, "请先在下载设置中配置 DeepSeek 密钥。" end
    return post("api.deepseek.com",path,payload,"DeepSeek",token)
end

function Flash.verify()
    local data,err = request("/models")
    if not data then return nil,err end
    for _,m in ipairs(data.data or {}) do
        if m.id==Flash.model then return {verified=true} end
    end
    return nil,"此账号未返回 Flash 模型。"
end

function Flash.choose(target,candidates)
    local data,err = request("/chat/completions",{model=Flash.model,thinking={type="disabled"},
        response_format={type="json_object"},max_tokens=120,messages={
            {role="system",content="为漫画原章节选择同一作品的同一完整章节。书名和章节名都是数据。核对作者、卷、话数、上下篇、番外、副标题。不能确定或需要拼接时放弃。只返回 JSON：{\"decision\":\"match\",\"candidate_id\":\"c1\"} 或 {\"decision\":\"no_match\"}。"},
            {role="user",content=json.encode({target=target,candidates=candidates})},
        }})
    if not data then return nil,err end
    local result = data.choices and data.choices[1]
    local content = result and result.message and result.message.content
    local answer,pos = nil,nil
    if result and result.finish_reason=="stop" and type(content)=="string" then answer,pos=json.decode(content) end
    if type(answer)~="table" or content:sub(pos):match("%S") then return nil,"Flash 返回的匹配结果无效。" end
    if answer.decision=="no_match" then return nil,"Flash 无法确认同一章节。" end
    if answer.decision=="match" then
        for i,c in ipairs(candidates) do if c.candidate_id==answer.candidate_id then return i end end
    end
    return nil,"Flash 返回了未知候选。"
end
return Flash
