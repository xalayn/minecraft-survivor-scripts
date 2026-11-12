-- rpc: requests from pocket computers to regiond over rednet.
--
-- Needs a wireless or ender modem on both ends (ender modems work at any range
-- and across dimensions). The server registers itself with rednet.host, so
-- clients find it without configuration.
--
-- Password: if the server computer has the setting region.secret set (`set
-- region.secret <password>`), requests must carry the same value, which
-- clients send from their own region.secret setting. With no password set on
-- the server, every request is accepted. Rednet isn't encrypted, so this keeps
-- out casual misuse, not a determined eavesdropper.

local M = {}

M.PROTOCOL = "ccregion"
M.HOSTNAME = "regiond"
M.SECRET_SETTING = "region.secret"

--- Open a modem for rednet, preferring wireless/ender ones. Returns its side
-- (peripheral name), or nil and an error.
function M.openModem()
  local wired
  for _, side in ipairs(peripheral.getNames()) do
    if peripheral.getType(side) == "modem" then
      if peripheral.call(side, "isWireless") then
        rednet.open(side)
        return side
      end
      wired = wired or side
    end
  end
  if wired then
    rednet.open(wired)
    return wired
  end
  return nil, "No modem attached. Attach a wireless or ender modem."
end

--- Handle one request message with a table of handlers (name -> function
-- returning ok, result). Returns the response to send back.
function M.handle(handlers, msg, secret)
  if type(msg) ~= "table" or type(msg.method) ~= "string" then return nil end
  local function reply(ok, result)
    return { id = msg.id, ok = ok, result = result }
  end
  if secret and secret ~= "" and msg.secret ~= secret then
    return reply(false, "Wrong or missing password (region.secret)")
  end
  local h = handlers[msg.method]
  if not h then return reply(false, "Unknown request: " .. msg.method) end
  local params = type(msg.params) == "table" and msg.params or {}
  local okCall, ok, result = pcall(h, table.unpack(params, 1, params.n or #params))
  if not okCall then return reply(false, "Server error: " .. tostring(ok)) end
  return reply(ok, result)
end

--- Serve requests forever (run alongside other work with the parallel API).
-- log(text) is called for each request.
function M.serve(handlers, log)
  rednet.host(M.PROTOCOL, M.HOSTNAME)
  while true do
    local sender, msg = rednet.receive(M.PROTOCOL)
    local response = M.handle(handlers, msg, settings.get(M.SECRET_SETTING))
    if response then
      if log then log(string.format("#%d %s%s", sender, msg.method, response.ok and "" or " (refused)")) end
      rednet.send(sender, response, M.PROTOCOL)
    end
  end
end

local server

--- Call a method on regiond. Returns ok, result (or false, error message).
function M.call(method, timeout, ...)
  if not server then
    server = rednet.lookup(M.PROTOCOL, M.HOSTNAME)
    if not server then return false, "Can't reach regiond. Is it running, with a modem?" end
  end
  local id = tostring(math.random(1, 2 ^ 30)) .. tostring(os.epoch("utc"))
  rednet.send(server, {
    id = id, method = method, params = table.pack(...),
    secret = settings.get(M.SECRET_SETTING),
  }, M.PROTOCOL)
  local deadline = os.clock() + (timeout or 10)
  while true do
    local remaining = deadline - os.clock()
    if remaining <= 0 then
      server = nil -- look it up again next time, in case it moved
      return false, "regiond didn't answer in time."
    end
    local sender, response = rednet.receive(M.PROTOCOL, remaining)
    if sender == server and type(response) == "table" and response.id == id then
      return response.ok, response.result
    end
  end
end

return M
