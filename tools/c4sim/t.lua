-- t: tiny test runner for c4sim tests. Lua 5.1 and 5.4 compatible.
local t = {}
local tests = {}

function t.test(name, fn)
  tests[#tests + 1] = { name = name, fn = fn }
end

function t.eq(a, b, msg)
  if a ~= b then
    error((msg or "eq") .. ": expected " .. tostring(b) .. ", got " .. tostring(a), 2)
  end
end

function t.ok(cond, msg)
  if not cond then error(msg or "ok failed", 2) end
end

-- Runs all registered tests, prints one summary line and one line per failure.
-- Exits the process with status 1 if anything failed.
function t.finish(suite)
  local passed, failed, fails = 0, 0, {}
  for _, tc in ipairs(tests) do
    local ok, err = pcall(tc.fn)
    if ok then
      passed = passed + 1
    else
      failed = failed + 1
      local msg = tostring(err):match("^[^\r\n]*") or ""
      fails[#fails + 1] = "FAIL " .. tc.name .. ": " .. msg
    end
  end
  io.write(string.format("c4sim %s: %d passed, %d failed\n", suite or "tests", passed, failed))
  for _, line in ipairs(fails) do io.write(line .. "\n") end
  os.exit(failed > 0 and 1 or 0)
end

return t
