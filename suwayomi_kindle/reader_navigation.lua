local UI = require("ui/uimanager")
local Chapters = require("suwayomi_kindle/chapters")
local Downloads = require("suwayomi_kindle/downloads")
local Queue = require("suwayomi_kindle/queue")
local Navigation = {}

local function notice(text)
    UI:show(require("ui/widget/infomessage"):new{text=text,timeout=3})
end

local function cancel_intent(plugin)
    local intent=plugin.chapter_intent
    plugin.chapter_intent=nil
    if intent and intent.unsubscribe then intent.unsubscribe() end
end

Navigation.cancel = cancel_intent

-- KOReader closes the outgoing document before opening the destination on a
-- later UI tick. Its close hook must protect that destination during cleanup.
function Navigation.switchDocument(reader,path,after_open)
    reader.suwayomi_next_file=path
    reader:switchDocument(path,true,after_open)
end

function Navigation.select(plugin,chapter,from_end)
    local origin=plugin.reading_chapter
    if not origin or chapter.id==origin.id then return end
    cancel_intent(plugin)
    local intent={doc=plugin.ui.document,page=plugin.ui:getCurrentPage(),from_end=from_end}
    plugin.chapter_intent=intent
    local function current()
        return plugin.chapter_intent==intent and plugin.reading_chapter==origin and plugin.ui.document==intent.doc
    end
    local function open(path)
        UI:nextTick(function()
            if not current() then return end
            cancel_intent(plugin)
            if require("libs/libkoreader-lfs").attributes(path,"mode")~="file" then notice("章节文件已移走。"); return end
            local first_page
            if from_end then first_page=function(reader) reader.paging:onGotoPage(1) end end
            Navigation.switchDocument(plugin.ui,path,first_page)
        end)
    end
    if chapter.path then open(chapter.path); return end
    local function download(mode)
        if not current() then return end
        local q=Queue.attach(origin.index,origin.config,plugin.settings_store:load("download"))
        local paused,err=origin.index:with_db(function(db)
            return tonumber(db:rowexec("SELECT paused FROM queue_control"))==1
        end)
        if paused or paused==nil or chapter.state=="paused" then
            cancel_intent(plugin)
            notice(err or "下载已暂停，请在下载任务中继续。")
            return
        end
        local result,why=Downloads.enqueue(origin.index,origin.manga,mode,chapter.id)
        if not result then cancel_intent(plugin); notice(why); return end
        -- A download may have finished between displaying the prompt and confirming.
        local latest=Chapters.locate(origin.index,origin.manga,chapter.id)
        if latest and latest.path then open(latest.path); return end
        intent.unsubscribe=Queue.watch(q,{manga=origin.manga,id=chapter.id},function(data,failure)
            if not current() then return end
            if data and data.path then open(data.path)
            else cancel_intent(plugin); notice(failure or "章节下载未完成。") end
        end)
        Queue.start(q,true)
    end
    local policy=Downloads.policy(origin.index,origin.manga)
    if from_end and policy and policy.ahead>0 then download("next_auto")
    else UI:show(require("ui/widget/confirmbox"):new{text="下载《" .. chapter.name .. "》并打开？",
        ok_callback=function() download("single") end,cancel_callback=function() if current() then cancel_intent(plugin) end end}) end
end

function Navigation.contents(plugin)
    local row=plugin.reading_chapter
    if not row then return end
    cancel_intent(plugin)
    if plugin.home and plugin.home.alive then UI:close(plugin.home) end
    plugin.home=require("suwayomi_kindle/ui/home"):new{
        plugin=plugin,settings_store=plugin.settings_store,reader_origin=row,
    }
    UI:show(plugin.home)
    return true
end

function Navigation.install(plugin)
    local row=plugin.reading_chapter
    local reader=plugin.ui
    if not row or not reader.status or not reader.toc or not reader.paging
        or type(reader.paging.onGotoPageRel)~="function" then return end
    local status,toc=reader.status,reader.toc
    local paging=reader.paging
    local original_end,original_toc=status.onEndOfBook,toc.onShowToc
    local original_page_turn=paging.onGotoPageRel
    local function advance(native)
        if not native or not reader.document then return true end
        if plugin.chapter_intent then return true end
        local next_chapter,err=Chapters.locate(row.index,row.manga,row.id,1)
        if err then notice(err); return true end
        if G_reader_settings:isTrue("end_document_auto_mark") then native:markBook(true) end
        local result,save_error=require("suwayomi_kindle/records").mark(row.index,row.manga,row,"single",true,
            reader.document:getPageCount()-1)
        if not result then notice(save_error); return true end
        if result.changes>0 then require("suwayomi_kindle/sync_service").schedule(row.index,row.config) end
        if next_chapter then Navigation.select(plugin,next_chapter,true)
        else notice("已读完本漫画的最后一章。") end
        return true
    end
    local function finish(native,...)
        if plugin.reading_chapter~=row then return original_end(native,...) end
        return advance(native)
    end
    local function page_turn(native,diff,no_page_turn,...)
        if plugin.reading_chapter~=row or no_page_turn then
            return original_page_turn(native,diff,no_page_turn,...)
        end
        if diff<=0 or native.current_page<native.number_of_pages then
            return original_page_turn(native,diff,no_page_turn,...)
        end
        local visible,area=native.visible_area,native.page_area
        local at_right=visible.x+visible.w>=area.x+area.w-1
        local at_bottom=visible.y+visible.h>=area.y+area.h-1
        if not at_right or not at_bottom then
            return original_page_turn(native,diff,no_page_turn,...)
        end
        -- Swallow the native EndOfBook path. It continues panning and repaints
        -- the finished page after the document starts closing, which is the
        -- visible close/reopen flash. The next switch can now replace the
        -- document while the final page is still on screen.
        return advance(status)
    end
    local function contents(native,...)
        if plugin.reading_chapter~=row then return original_toc(native,...) end
        return Navigation.contents(plugin)
    end
    status.onEndOfBook,toc.onShowToc=finish,contents
    paging.onGotoPageRel=page_turn
    plugin.release_chapter_navigation=function()
        cancel_intent(plugin)
        if status.onEndOfBook==finish then status.onEndOfBook=original_end end
        if toc.onShowToc==contents then toc.onShowToc=original_toc end
        if paging.onGotoPageRel==page_turn then paging.onGotoPageRel=original_page_turn end
    end
end

function Navigation.pageChanged(plugin,page)
    local intent=plugin.chapter_intent
    if intent and intent.page~=page then cancel_intent(plugin) end
end

return Navigation
