-- Cocoa's multithreaded process cannot safely resolve hosts in a fork child.
-- Launch a clean copy of KOReader's LuaJIT, sharing only anonymous job files.
local ffi = require("ffi")
require("ffi/posix_h")

ffi.cdef[[
char ***_NSGetEnviron(void);
int posix_spawn(int *, const char *, void *const *, void *const *, char *const [], char *const []);
int posix_spawn_file_actions_init(void **);
int posix_spawn_file_actions_destroy(void **);
int posix_spawn_file_actions_adddup2(void **, int, int);
int posix_spawnattr_init(void **);
int posix_spawnattr_destroy(void **);
int posix_spawnattr_setflags(void **, short);
]]
local C = ffi.C
local entry = assert(debug.getinfo(1, "S").source:sub(2):match("^(.*)/")) .. "/worker_main.lua"

return function(request, output)
    local input = io.tmpfile()
    if not input then return nil end
    local written = input:write(request)
    if not written or not input:seek("set", 0) then input:close(); return nil end
    local actions, attr = ffi.new("void *[1]"), ffi.new("void *[1]")
    local pid = ffi.new("int[1]")
    local rc = C.posix_spawn_file_actions_init(actions)
    if rc == 0 then
        rc = C.posix_spawnattr_init(attr)
        if rc == 0 then
            -- POSIX_SPAWN_CLOEXEC_DEFAULT. Child reads stdin and writes fd 3.
            rc = C.posix_spawnattr_setflags(attr, 0x4000)
            if rc == 0 then rc = C.posix_spawn_file_actions_adddup2(actions, C.fileno(input), 0) end
            if rc == 0 then rc = C.posix_spawn_file_actions_adddup2(actions, C.fileno(output), 3) end
            if rc == 0 then
                -- Keep stdout/stderr valid for KOReader's startup diagnostics.
                for fd = 1, 2 do
                    rc = C.posix_spawn_file_actions_adddup2(actions, fd, fd)
                    if rc ~= 0 then break end
                end
            end
            if rc == 0 then
                local argv = ffi.new("const char *[3]", {"./luajit", entry})
                rc = C.posix_spawn(pid, "./luajit", actions, attr, ffi.cast("char **", argv), C._NSGetEnviron()[0])
            end
            C.posix_spawnattr_destroy(attr)
        end
        C.posix_spawn_file_actions_destroy(actions)
    end
    input:close()
    return rc == 0 and tonumber(pid[0]) or nil
end
