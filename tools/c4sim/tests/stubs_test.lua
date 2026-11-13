-- Checks the simulator's own stubs (JSON, Base64, url*, net). No driver involved.
local sim = require("c4sim")
local t = require("t")
local C4 = sim.C4

t.test("JSON round-trips nested data and escapes strings", function()
  sim.reset()
  local src = { name = 'a "q"\n', list = { 1, 2.5, true }, empty = {} }
  local text = C4:JsonEncode(src)
  t.eq(text, '{"empty":[],"list":[1,2.5,true],"name":"a \\"q\\"\\n"}', "encoded")
  local back = JsonDecode(text)
  t.eq(back.name, 'a "q"\n', "string")
  t.eq(back.list[2], 2.5, "number")
  t.eq(back.list[3], true, "bool")
end)

t.test("JSON decode of a \\u escape and bad input", function()
  sim.reset()
  t.eq(JsonDecode('"\\u0041b"'), "Ab", "unicode escape")
  local ok = pcall(JsonDecode, "{bad")
  t.ok(not ok, "bad input errors")
end)

t.test("Base64 known vectors both ways", function()
  sim.reset()
  t.eq(Base64Encode("Man"), "TWFu", "3 bytes")
  t.eq(Base64Encode("Ma"), "TWE=", "2 bytes")
  t.eq(Base64Encode("M"), "TQ==", "1 byte")
  t.eq(Base64Decode("TWE="), "Ma", "decode")
  t.eq(Base64Decode(Base64Encode("\0\255hello")), "\0\255hello", "binary round-trip")
end)

t.test("url requests are recorded and answered on advance", function()
  sim.reset()
  sim.queue_http("/state$", '{"on":true}', 200)
  local got
  C4:urlGet("http://10.0.0.5/state", {}, function(ctx, data, code, _, err)
    got = { ctx = ctx, data = data, code = code, err = err }
  end, "ctx1")
  t.eq(#sim.http, 1, "recorded")
  t.eq(sim.http[1].method, "GET", "method")
  t.ok(got == nil, "not delivered before advance")
  sim.advance(0)
  t.eq(got.ctx, "ctx1", "context")
  t.eq(got.data, '{"on":true}', "body")
  t.eq(got.code, 200, "code")
end)

t.test("unqueued url request answers with an error and warns", function()
  sim.reset()
  local code
  urlPost("http://x/y", "b", {}, function(_, _, c) code = c end, nil)
  sim.advance(0)
  t.eq(code, 0, "code 0")
  t.ok(sim.warnings[1]:find("no queued http response", 1, true) ~= nil, "warning")
end)

t.test("network sends are recorded and receive calls ReceivedFromNetwork", function()
  sim.reset()
  local got
  _G.ReceivedFromNetwork = function(b, p, d) got = { b, p, d } end
  C4:CreateNetworkConnection(7, "10.0.0.9", "TCP")
  NetConnect(7, 4000, "TCP")
  SendToNetwork(7, 4000, "hi")
  t.eq(sim.net.sent[1].data, "hi", "sent")
  sim.net_receive(7, "reply")
  t.eq(got[1], 7, "binding")
  t.eq(got[2], 4000, "port")
  t.eq(got[3], "reply", "data")
  _G.ReceivedFromNetwork = nil
end)

t.test("os.time in a driver follows the simulated clock", function()
  sim.reset()
  local lua = os.tmpname()
  local f = assert(io.open(lua, "w"))
  f:write("T0 = os.time()\nfunction OnDriverInit() end\n")
  f:close()
  sim.load_driver(lua, {})
  os.remove(lua)
  sim.advance(5000)
  t.eq(sim.env.os.time() - sim.env.T0, 5, "5 s later")
end)

t.test("pairs over Properties works under Lua 5.4", function()
  sim.reset()
  sim._store.A = "1"
  if _VERSION ~= "Lua 5.1" then
    local seen = 0
    for k in pairs(Properties) do
      if k == "A" then seen = seen + 1 end
    end
    t.eq(seen, 1, "walked")
  end
end)

t.finish("stubs")
