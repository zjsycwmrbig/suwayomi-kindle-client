-- Entry point for the macOS worker launched from KOReader's runtime directory.
require("setupkoenv")
local root = assert(arg[0]:match("^(.*)/suwayomi_kindle/worker_main%.lua$"))
package.path = root .. "/?.lua;" .. package.path
local output = assert(io.open("/dev/fd/3", "wb"))
local input = assert(require("dkjson").decode(io.read("*a")))
require("suwayomi_kindle/worker").writeResult(output, input.config, input.action, input.input)
output:close()
