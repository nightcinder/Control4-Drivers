-- Sensor prep placeholders for Saturday 2026-11-21. Checks the two drafts in
-- docs/sensor-prep-2026-11-21/:
--   dls-presence.rooms.laundry.draft.json  (liesa rooms.json; holds host/key/entity/pir)
--   ea1.rooms-json.laundry.draft.json      (EA-1 Rooms JSON; presence.sources only)
-- Run: python tools/c4sim/run.py test sensor_prep_placeholders
--
-- EXPECTED TO FAIL AS COMMITTED: case 1 fails while the drafts still contain `<<FILL: ...>>`
-- markers. `run.py test all` goes red for the whole suite on any failing case, so case 1 only
-- fails when SENSOR_PREP_STRICT=1 is set (the owner's run on Saturday); otherwise it prints a
-- skip line and passes. Case 2 always runs, on a copy of both drafts filled in memory.
-- require("c4sim") also installs the JsonDecode stub used below.
local sim = require("c4sim")
local t = require("t")

local DIR = "docs/sensor-prep-2026-11-21/"
local DLS = DIR .. "dls-presence.rooms.laundry.draft.json"
local EA1 = DIR .. "ea1.rooms-json.laundry.draft.json"
local MARK = "<<FILL:"
local HINT = "fill the placeholders in docs/sensor-prep-2026-11-21 then re-run"

-- Case 2 fakes. host is a made-up name, the key is a base64-shaped dummy (43 A's and one
-- padding '=' = 44 characters), the object_ids are the usual ESPHome names.
local FAKE = {
  host = "ep-laundry.lan",
  key = string.rep("A", 43) .. "=",
  entity = "occupancy",
  pir = "pir",
}

local function read(path)
  local f = assert(io.open(path, "rb"))
  local s = f:read("*a")
  f:close()
  return s
end

local function decode(path)
  local ok, doc = pcall(JsonDecode, read(path))
  t.ok(ok, path .. ": not valid JSON (" .. tostring(doc) .. ")")
  t.ok(type(doc) == "table", path .. ": JSON is not an object")
  return doc
end

local function child_path(path, k)
  if type(k) == "number" then return path .. "[" .. tostring(k) .. "]" end
  if path == "" then return tostring(k) end
  return path .. "." .. tostring(k)
end

-- Every string below `node` that still carries a marker, with its JSON path.
local function markers(node, path, out)
  local tv = type(node)
  if tv == "string" then
    if node:find(MARK, 1, true) then out[#out + 1] = { path = path, value = node } end
  elseif tv == "table" then
    local keys = {}
    for k in pairs(node) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, k in ipairs(keys) do
      markers(node[k], child_path(path, k), out)
    end
  end
end

-- One line, because t.finish keeps only the first line of a failure message.
-- Returns the report and the number of markers (nil, 0 when the draft is clean).
local function leftover(label, doc)
  local out = {}
  markers(doc, "", out)
  if #out == 0 then return nil, 0 end
  local parts = {}
  for _, m in ipairs(out) do
    parts[#parts + 1] = label .. " " .. (m.path == "" and "<root>" or m.path)
  end
  return table.concat(parts, "; "), #out
end

local function fill(node, path, unknown)
  if type(node) ~= "table" then return end
  for k, v in pairs(node) do
    if type(v) == "string" then
      if v:find(MARK, 1, true) then
        if type(k) == "string" and FAKE[k] then
          node[k] = FAKE[k]
        else
          unknown[#unknown + 1] = child_path(path, k)
        end
      end
    elseif type(v) == "table" then
      fill(v, child_path(path, k), unknown)
    end
  end
end

local function has(list, want)
  if type(list) ~= "table" then return false end
  for _, v in ipairs(list) do if v == want then return true end end
  return false
end

local function nonempty(v)
  return type(v) == "string" and #v > 0
end

t.test("1 drafts have no placeholders left (SENSOR_PREP_STRICT=1)", function()
  local dls = decode(DLS)
  local ea1 = decode(EA1)
  local reports, count = {}, 0
  local function add(r, n)
    if r then reports[#reports + 1] = r; count = count + n end
  end
  add(leftover(DLS, dls))
  add(leftover(EA1, ea1))
  if count == 0 then return end
  if os.getenv("SENSOR_PREP_STRICT") ~= "1" then
    print("skip sensor_prep_placeholders: " .. count .. " placeholder(s) in the drafts, " .. HINT)
    return
  end
  error(HINT .. ": " .. count .. " marker(s) left: " .. table.concat(reports, "; "), 0)
end)

t.test("2 a filled sample passes the checks and has the expected shape", function()
  local dls = decode(DLS)
  local ea1 = decode(EA1)
  local unknown = {}
  fill(dls, "", unknown)
  fill(ea1, "", unknown)
  t.eq(#unknown, 0, "placeholder in a field the test cannot fake; add it to FAKE: "
    .. table.concat(unknown, ", "))

  -- The same check case 1 applies to the real drafts.
  t.eq(leftover(DLS, dls), nil, "markers left in the filled dls copy")
  t.eq(leftover(EA1, ea1), nil, "markers left in the filled EA-1 copy")

  -- dls-presence rooms.json: one room, "Laundry", with an esp entry.
  t.ok(type(dls.rooms) == "table", "dls draft has a rooms object")
  local keys = {}
  for k in pairs(dls.rooms or {}) do keys[#keys + 1] = k end
  t.eq(#keys, 1, "dls draft has exactly one room")
  local room_key = keys[1]
  t.ok(type(room_key) == "string", "dls room key is a string")
  if type(room_key) ~= "string" then return end
  t.eq(room_key, "Laundry", "dls room key is Laundry")
  t.ok(#room_key >= 1 and #room_key <= 32 and room_key:match("^[A-Za-z0-9_%-]+$") ~= nil,
    "room key " .. room_key .. " matches ^[A-Za-z0-9_-]{1,32}$")

  local room = dls.rooms[room_key]
  t.ok(type(room) == "table", "dls room object is present")
  if type(room) ~= "table" then return end
  t.ok(has(room.sources, "esp"), "dls sources contains esp")
  t.ok(has(room.sources, "robot"), "dls sources keeps robot")
  t.ok(type(room.esp) == "table" and #room.esp >= 1, "dls esp is a non-empty list")
  local dev = room.esp[1]
  t.ok(type(dev) == "table", "esp[1] is an object")
  if type(dev) ~= "table" then return end
  t.ok(nonempty(dev.host), "esp[1].host is not empty")
  t.ok(nonempty(dev.key), "esp[1].key is not empty")
  t.ok(nonempty(dev.entity), "esp[1].entity is not empty")
  local key_ok = type(dev.key) == "string" and #dev.key == 44
    and dev.key:match("^[A-Za-z0-9%+/]+=*$") ~= nil
  t.ok(key_ok, "esp[1].key looks like a 44-character base64 API key ("
    .. (type(dev.key) == "string" and #dev.key or "not a string") .. ")")
  t.ok(has(room.robot, "Laundry"), "dls robot maps Laundry")

  -- EA-1 Rooms JSON: the room object only, no sensor details.
  t.eq(ea1.name, "Laundry", "EA-1 room name")
  local light568 = false
  for _, l in ipairs(ea1.lights or {}) do
    if tonumber(l.id) == 568 then light568 = true end
  end
  t.ok(light568, "EA-1 Laundry still lists light 568")
  local pres = ea1.presence or {}
  t.ok(has(pres.sources, "esp"), "EA-1 presence.sources contains esp")
  t.ok(has(pres.sources, "robot"), "EA-1 presence.sources keeps robot")
  t.ok(ea1.esp == nil, "EA-1 room has no esp list")
  t.ok(pres.host == nil and pres.entity == nil and pres.pir == nil,
    "EA-1 presence has no host/entity/pir")
end)

t.finish("sensor-prep")
