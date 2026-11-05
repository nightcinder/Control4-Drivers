-- Offline test for the SwitchBot signing helpers in driver.lua.
-- Run from the project root:  lua5.1 tests/test_signing.lua [path/to/driver.lua]
-- Uses fake credentials only. Does not touch the network.

-- Stub the Control4 global so driver.lua loads outside Composer.
C4 = C4 or {}
Properties = Properties or {}

local driverPath = arg and arg[1] or "driver.lua"
dofile(driverPath)

local SC = SwitchBotCrypto
local failures, passes = 0, 0

local function check(name, got, want)
  if got == want then
    passes = passes + 1
    print("PASS  " .. name)
  else
    failures = failures + 1
    print("FAIL  " .. name)
    print("      got:  " .. tostring(got))
    print("      want: " .. tostring(want))
  end
end

-- SHA-256 (FIPS 180-2 vectors)
check("sha256('')", SC.to_hex(SC.sha256_raw("")),
  "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
check("sha256('abc')", SC.to_hex(SC.sha256_raw("abc")),
  "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
check("sha256 two-block message", SC.to_hex(SC.sha256_raw(
  "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")),
  "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")

-- HMAC-SHA256 (RFC 4231 test case 2 and a common web vector)
check("hmac RFC4231 TC2", SC.to_hex(SC.hmac_sha256_raw("Jefe", "what do ya want for nothing?")),
  "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
check("hmac 'key' / fox", SC.to_hex(SC.hmac_sha256_raw("key",
  "The quick brown fox jumps over the lazy dog")),
  "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8")

-- Base64
check("base64('foobar')", SC.base64("foobar"), "Zm9vYmFy")
check("base64('fo') padding", SC.base64("fo"), "Zm8=")
check("base64('f') padding", SC.base64("f"), "Zg==")

-- SwitchBot signature: base64(HMAC-SHA256(key=secret, msg=token..t..nonce))
-- Expected value computed independently with Python hmac/hashlib/base64.
local token, secret, t, nonce = "fake-token-123", "fake-secret-456", "1762300000000", "a1b2c3d4"
local sign = SC.sign(token, secret, t, nonce)
check("SwitchBot sign (fake creds)", sign, "eX79Ki46PWTqDiS3/MY8wL9ik/7fyJ9OF34Y5vH4sjQ=")

-- JSON decoder: well-formed sample shaped like a /status response
local sample = '{"statusCode":100,"message":"success","body":{"deviceId":"ABC","slidePosition":42,"battery":87,"moving":false}}'
local ok, obj = pcall(SC.JSON.decode, sample)
check("json decode ok", ok, true)
check("json statusCode", obj and obj.statusCode, 100)
check("json slidePosition", obj and obj.body and obj.body.slidePosition, 42)

-- JSON decoder: malformed input must raise an error, not return data
local bad = { '{"statusCode":100,', '', 'not json', '{"a" 1}' }
for _, s in ipairs(bad) do
  local okBad = pcall(SC.JSON.decode, s)
  check("json rejects malformed: " .. s, okBad, false)
end

print("")
print(string.format("Result: %d passed, %d failed", passes, failures))

-- Print the headers a real request would carry, with fake credentials only.
print("")
print("Signed headers for fake credentials (example request):")
print("  Authorization: " .. token)
print("  sign: " .. sign)
print("  t: " .. t)
print("  nonce: " .. nonce)
print("  Content-Type: application/json; charset=utf8")

os.exit(failures == 0 and 0 or 1)
