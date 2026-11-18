-- smoke: load each driver, run 10 simulated minutes, print terse status lines.
-- Args: name|absolute_lua_path|absolute_xml_path (xml may be empty).
local sim = require("c4sim")
local fails = 0

local function out(s) io.write(s .. "\n") end

for i = 1, #arg do
  local name, luapath, xml = arg[i]:match("^([^|]*)|([^|]*)|(.*)$")
  if name then
    sim.load_driver(luapath, { xml = (xml ~= "" and xml) or nil })
    for _ = 1, 600 do sim.advance(1000) end
    -- Destroy must stop the driver's timers; a cancelled timer that still fires is an error.
    sim.call("OnDriverDestroyed")
    sim.advance(60000)

    local live = 0
    for _, timer in ipairs(sim.timers) do
      if not timer.cancelled then live = live + 1 end
    end
    if live > 0 then
      fails = fails + 1
      out("ERR " .. name .. ": " .. live .. " timer(s) still live after OnDriverDestroyed")
    elseif #sim.errors > 0 then
      fails = fails + 1
      out("ERR " .. name .. ": " .. sim.errors[1])
    else
      out("ok " .. name)
    end

    local unstubbed = {}
    for _, w in ipairs(sim.warnings) do
      local mod = w:match("^stubbed common%-library module (.+)$")
      if mod then out("warn " .. name .. ": stubbed common-library module " .. mod) end
      if w:match("^unstubbed ") then unstubbed[#unstubbed + 1] = w:gsub("^unstubbed ", "") end
    end
    if #unstubbed > 0 then
      out("warn " .. name .. ": unstubbed " .. table.concat(unstubbed, ", "))
    end

    local direct = {}
    for _, n in ipairs(sim.xml_names) do
      if sim.props_direct[n] and not sim.props_api[n] then direct[#direct + 1] = n end
    end
    if #direct > 0 then
      out("warn " .. name .. ": Properties[] assigned without C4:UpdateProperty: " .. table.concat(direct, ","))
    end
  end
end

os.exit(fails > 0 and 1 or 0)
