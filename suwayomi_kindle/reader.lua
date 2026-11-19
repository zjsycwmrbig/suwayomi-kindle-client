local Reader = {}
local function target(plugin)
    local document = plugin.ui.document
    local path = document and document.file
    if not path or not path:match("/Suwayomi/%x+/%d+/%d+%.cbz$") then return end
    local config = plugin.settings_store:load("connection")
    if config.server_url == "" then return end
    local index = require("suwayomi_kindle/library_index").new(config)
    local row = index:with_db(function(db)
        local r = db:prepare([[SELECT c.manga,c.id,c.last_page FROM files f JOIN chapter c
            ON c.manga=f.manga AND c.id=f.id WHERE f.path=?]]):bind(path):step()
        if r then return {manga=r[1],id=tonumber(r[2]),page=tonumber(r[3])} end
    end)
    if row then row.index,row.config = index,config end
    return row
end

function Reader:onReaderReady()
    local row=target(self)
    self.reading_chapter=row
    if row and row.page then
        self.ui:registerPostReaderReadyCallback(function()
            local page=math.min(row.page+1,self.ui.document:getPageCount())
            if page>0 and page~=self.ui:getCurrentPage() then self.ui.paging:onGotoPage(page) end
        end)
    end
end

function Reader:onCloseDocument()
    local row=self.reading_chapter
    if not row then return end
    self.reading_chapter=nil
    local page=self.ui:getCurrentPage()
    local total=self.ui.document:getPageCount()
    if not page or page<1 or page>total then return end
    local read = page==total and true or nil
    local result,err=require("suwayomi_kindle/records").mark(row.index,row.manga,row,"single",read,page-1)
    if not result then require("suwayomi_kindle/records").log(row.index,"保存阅读进度失败 · " .. err); return end
    if result.changes>0 then require("suwayomi_kindle/sync_service").schedule(row.index,row.config) end
    local settings=self.settings_store:load("download")
    require("ui/uimanager"):nextTick(function()
        local downloads=require("suwayomi_kindle/downloads")
        local reader=require("apps/reader/readerui").instance
        local active=reader and reader.document and reader.document.file
        downloads.clean(row.index,row.manga,settings.retention,false,active)
        downloads.enqueue(row.index,row.manga,"auto")
        local queue=require("suwayomi_kindle/queue")
        queue.start(queue.attach(row.index,row.config,settings))
    end)
end
return Reader
