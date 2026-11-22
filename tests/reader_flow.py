"""Run from KOReader's runtime directory. The fixture uses its own profile and CBZs."""
import os
from pathlib import Path
import struct
import subprocess
import tempfile
import zipfile
import zlib

REPO = Path(__file__).resolve().parents[1]
SETUP = """
require('setupkoenv'); package.path=os.getenv('FIXTURE_PLUGIN')..'/?.lua;'..package.path
local c=assert(require('suwayomi_kindle/settings_store'):new():update('connection',{server_url='http://127.0.0.1:1',auth_method='none'}))
local idx=require('suwayomi_kindle/library_index').new(c)
local ch=require('suwayomi_kindle/chapters')
assert(ch.refresh(idx,{chapterPage=function() return {nodes={{id=91,name='one',isRead=false},{id=6,name='two',isRead=false},{id=38,name='three',isRead=false}},pageInfo={hasNextPage=false},totalCount=3} end},'5'))
for _,id in ipairs({91,6}) do
 local path=ch.downloadPath(idx,{manga='5',id=id,directory=os.getenv('KO_HOME')})
 require('util').makePath(path:match('^(.*)/'))
 assert(idx:with_db(function(db) db:prepare("INSERT INTO files VALUES(?,?,?)"):bind('5',id,path):step(); return true end))
 print('CBZ '..path)
end
"""
DRIVER = """
local UI=require('ui/uimanager')
local fixture=require('ui/widget/container/widgetcontainer'):extend{name='flowfixture',is_doc_only=true}
function fixture:onReaderReady()
 UI:scheduleIn(.15,function()
  local reader=self.ui
  local path=reader.document.file
  if path:match('/91%.cbz$') then
   if package.loaded.flow_stage=='back' then
    assert(reader:getCurrentPage()==2,'previous chapter did not open at its last page')
    package.loaded.flow_stage='returned'
    reader.paging:onGotoPage(2)
    reader.paging:onGotoPageRel(1)
    return
   elseif package.loaded.flow_returned then
    print('NATIVE CBZ FLOW PASSED')
    UI:quit()
    return
   end
   reader.toc:onShowToc()
   local home=reader['suwayomi-kindle'].home
   assert(home.directory and home.reader_origin and home.reader_origin.id==91 and home.pagination.total==1,'native TOC did not open')
   assert(require('suwayomi_kindle/chapters').page(home.index,'5',1,5).count==3)
   home:catalog_back()
   reader.paging:onGotoPage(2)
   reader.paging:onGotoPageRel(1)
  elseif path:match('/6%.cbz$') then
   assert(reader:getCurrentPage()==1)
   if package.loaded.flow_stage~='returned' then
    package.loaded.flow_stage='back'
    reader.paging:onGotoPageRel(-1)
    return
   end
   reader.toc:onShowToc()
   local home=reader['suwayomi-kindle'].home
   assert(home.reader_origin.id==6 and home.directory.target==6)
   local rows=require('suwayomi_kindle/chapters').page(home.index,'5',1,5).items
   assert(rows[1].read and not rows[2].read and not rows[3].path)
   home:catalog_back()
   reader.paging:onGotoPage(2)
   reader.paging:onGotoPageRel(1)
   local confirm=UI:getTopmostVisibleWidget()
   assert(confirm.text:find('three',1,true),'missing chapter prompt')
   confirm:onClose()
   reader.toc:onShowToc()
   home=reader['suwayomi-kindle'].home
   local function find(w)
    if w.label=='one' then return w end
    for _,child in ipairs(w) do local hit=find(child); if hit then return hit end end
   end
   package.loaded.flow_returned=true
   assert(find(home)).callback()
  end
 end)
end
return fixture
"""


def page_image():
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    header = struct.pack(">IIBBBBB", 128, 128, 8, 0, 0, 0, 0)
    pixels = (bytes([0]) + bytes([128]) * 128) * 128
    return bytes.fromhex("89504e470d0a1a0a") + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(pixels)) + chunk(b"IEND", b"")


def run(profile):
    env = dict(os.environ, FIXTURE_PLUGIN=str(REPO), KO_HOME=str(profile),
               EMULATE_READER="1", SDL_VIDEO_DRIVER="dummy", SDL_RENDER_DRIVER="software")
    plugins = profile / "plugins"
    plugins.mkdir()
    (plugins / "suwayomi-kindle.koplugin").symlink_to(REPO)
    fixture = plugins / "testflow.koplugin"
    fixture.mkdir()
    (fixture / "_meta.lua").write_text('return {fullname="Flow fixture",description="Test only"}')
    (fixture / "main.lua").write_text(DRIVER)
    (profile / "settings.reader.lua").write_text('return {language="en",color_rendering=false}')
    setup = subprocess.run(["./luajit", "-"], input=SETUP, env=env, capture_output=True, text=True, check=True)
    paths = [line[4:] for line in setup.stdout.splitlines() if line.startswith("CBZ ")]
    assert len(paths) == 2
    image = page_image()
    for path in paths:
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr("1.png", image)
            archive.writestr("2.png", image)
    result = subprocess.run(["./luajit", "reader.lua", paths[0]], env=env, capture_output=True, text=True, timeout=12)
    if result.returncode or "NATIVE CBZ FLOW PASSED" not in result.stdout:
        raise RuntimeError((result.stdout + result.stderr)[-3200:])
    print("Native CBZ table of contents, previous/next chapter and end-of-book transition passed")


if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix="suwayomi-reader-") as folder:
        run(Path(folder))
