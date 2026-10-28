local ship = {}

local CH_FRONT, CH_MID, CH_BACK = 9010, 9011, 9012
local CH_TURN, CH_SPEED, CH_CLUTCH = 9000, 9001, 9002
local REPLY_GPS = { [CH_FRONT] = 9005, [CH_MID] = 9006, [CH_BACK] = 9007 }
local REPLY_CMD = 9008
local REPLY_WAIT = 0.4
local RETRIES = 3
local STALL_TIME = 15
local MIN_MOVE = 0.2
local STEER_GAIN = 0.1
local MAX_BURST = 2
local DEAD_PULSES = 4
local INVERT_TURN = true

local modem = peripheral.find("modem")
assert(modem, "no modem attached")
modem.open(REPLY_CMD)

local atan2 = math.atan2 or math.atan

local function listen(wait)
  local timer = os.startTimer(wait)
  while true do
    local ev = { os.pullEvent() }
    if ev[1] == "modem_message" then
      os.cancelTimer(timer)
      return ev[5] -- message
    elseif ev[1] == "timer" and ev[2] == timer then
      return nil
    end
  end
end

local function drainQueue()
  local timer = os.startTimer(0)
  while true do
    local ev = { os.pullEvent() }
    if ev[1] == "timer" and ev[2] == timer then return end
  end
end

local openGps
local function closeGpsChannels()
  if openGps then
    modem.close(openGps[1])
    modem.close(openGps[2])
    openGps = nil
  end
end

local function repr(v)
  if type(v) == "table" then return textutils.serialise(v) end
  return tostring(v)
end

local function askGPS(channel, name)
  local replyChannel = REPLY_GPS[channel]
  local raws = {}
  closeGpsChannels() -- the previous unit's late reply must not arrive here
  openGps = { channel, replyChannel }
  modem.open(channel) -- also listen on the unit's own channel, in case it
  modem.open(replyChannel) -- answers there instead of the reply channel
  for _ = 1, RETRIES do
    drainQueue()
    local nums = {}
    modem.transmit(channel, replyChannel, "get_gps")
    local timer = os.startTimer(REPLY_WAIT)
    while true do
      local ev = { os.pullEvent() }
      if ev[1] == "modem_message" then
        local msg = ev[5]
        table.insert(raws, msg)
        if type(msg) == "table" and msg.message ~= nil then msg = msg.message end -- rednet envelope
        if type(msg) == "table" then
          if msg.x and msg.y and msg.z then
            return { x = msg.x + 0, y = msg.y + 0, z = msg.z + 0 }
          elseif #msg >= 3 then
            return { x = msg[1] + 0, y = msg[2] + 0, z = msg[3] + 0 }
          end
        elseif type(msg) == "string" or type(msg) == "number" then
          for n in tostring(msg):gmatch("-?%d+%.?%d*") do
            table.insert(nums, tonumber(n))
          end
        end
        if #nums >= 3 then return { x = nums[1], y = nums[2], z = nums[3] } end
      elseif ev[1] == "timer" and ev[2] == timer then
        break
      end
    end
    if #nums >= 3 then return { x = nums[1], y = nums[2], z = nums[3] } end
  end
  closeGpsChannels()
  if #raws == 0 then
    return nil, name .. " (port " .. channel .. ") did not reply"
  end
  return nil, name .. " (port " .. channel .. ") sent unparseable reply: " .. repr(raws):sub(1, 120)
end

function ship.getPositions()
  local p = {}
  for _, it in ipairs({ { "front", CH_FRONT }, { "mid", CH_MID }, { "back", CH_BACK } }) do
    local c, err = askGPS(it[2], it[1])
    if not c then closeGpsChannels(); return nil, err end
    p[it[1]] = c
  end
  closeGpsChannels()
  return p
end

function ship.getPositionsRetry(attempts)
  local err
  for _ = 1, attempts or 3 do
    local p, e = ship.getPositions()
    if p then return p end
    err = e
    sleep(0.1)
  end
  return nil, err
end

local function sendCommand(channel, msg)
  closeGpsChannels() -- a stray GPS reply must not stand in for the ack
  drainQueue()
  modem.transmit(channel, REPLY_CMD, msg)
  local reply = listen(REPLY_WAIT)
  return reply ~= nil and tostring(reply):find("200") ~= nil
end

function ship.clutch(state) -- "on" engaged (default) / "off" disengaged
  return sendCommand(CH_CLUTCH, state)
end

function ship.turn(dir) -- "left" / "right"
  return sendCommand(CH_TURN, dir)
end

function ship.speed(s) -- "speed_stop" / "speed_mid" / "speed_max"
  return sendCommand(CH_SPEED, s)
end

function ship.heading(pos)
  local dx = pos.front.x - pos.back.x
  local dz = pos.front.z - pos.back.z
  if dx == 0 and dz == 0 then return nil end
  return (math.deg(atan2(dx, -dz)) % 360 + 360) % 360
end

function ship.bearingTo(from, to)
  local dx = to.x - from.x
  local dz = to.z - from.z
  return (math.deg(atan2(dx, -dz)) % 360 + 360) % 360
end

function ship.angularDiff(a, b)
  return ((b - a + 180) % 360) - 180
end

function ship.dist(a, b)
  local dx, dz = a.x - b.x, a.z - b.z
  return math.sqrt(dx * dx + dz * dz)
end

local function turnDir(diff)
  local d = diff > 0 and "right" or "left"
  if INVERT_TURN then
    d = d == "right" and "left" or "right"
  end
  return d
end

function ship.steerBurst(diff, seconds)
  if not ship.clutch("off") then return nil, "clutch off failed" end
  ship.speed("speed_mid")
  ship.turn(turnDir(diff))
  sleep(seconds)
  ship.clutch("on")
  ship.speed("speed_max")
  return true
end

function ship.steerWhileCruising(pos, target, tolerance)
  tolerance = tolerance or 8

  local h0 = ship.heading(pos)
  if not h0 then return nil, "bad heading: front/back gps came back identical" end
  local diff = ship.angularDiff(ship.bearingTo(pos.mid, target), h0)
  if math.abs(diff) <= tolerance then return true end

  local lastHeading = h0
  local deadPulses = 0

  while true do
    local p = ship.getPositionsRetry(3)
    if not p then
      ship.clutch("on")
      return nil, "gps lost while steering"
    end
    local h = ship.heading(p)
    if h then
      diff = ship.angularDiff(ship.bearingTo(p.mid, target), h)
    end
    if math.abs(diff) <= tolerance then
      ship.clutch("on") -- center the rudder, keep flying
      return true
    end

    if not ship.clutch("off") then return nil, "clutch off failed" end
    ship.speed("speed_mid") -- rudder needs mid speed to bite
    ship.turn(turnDir(diff))
    sleep(math.min(MAX_BURST, math.max(0.3, math.abs(diff) * STEER_GAIN)))
    ship.clutch("on")
    ship.speed("speed_max") -- resume cruise between pulses

    p = ship.getPositionsRetry(3)
    if not p then return nil, "gps lost while steering" end
    h = ship.heading(p)
    if lastHeading and h and math.abs(h - lastHeading) < 0.05 then
      deadPulses = deadPulses + 1
      if deadPulses >= DEAD_PULSES then
        ship.clutch("on")
        return nil, "rudder not responding while steering"
      end
    else
      deadPulses = 0
    end
    lastHeading = h
  end
end

-- resume=false leaves the engines stopped (speed_stop) when the turn ends,
-- so the caller can coast the rest of the way instead of resuming cruise
function ship.turnToward(pos, target, tolerance, timeout, resume)
  if resume == nil then resume = true end
  tolerance = tolerance or 8
  local deadline = timeout and (os.clock() + timeout) or nil

  local h0 = ship.heading(pos)
  if not h0 then return nil, "bad heading: front/back gps came back identical" end
  local diff = ship.angularDiff(ship.bearingTo(pos.mid, target), h0)
  if math.abs(diff) <= tolerance then return true end

  if not ship.clutch("off") then return nil, "clutch off failed" end
  ship.speed("speed_stop") -- stop-and-turn: engines off so the rudder
                            -- pivots in place instead of carving an arc

  local dir = turnDir(diff)
  ship.turn(dir)

  local lastHeading = h0
  local lastMove = os.clock()
  local resent = false

  while true do
    sleep(0.5)
    local p, perr = ship.getPositionsRetry(3)
    if not p then
      ship.clutch("on")
      ship.speed("speed_stop")
      return nil, "gps lost while turning: " .. tostring(perr)
    end

    local h = ship.heading(p)
    if h then
      diff = ship.angularDiff(ship.bearingTo(p.mid, target), h)
    end
    if math.abs(diff) <= tolerance then break end

    if h ~= nil and (lastHeading == nil or math.abs(h - lastHeading) > MIN_MOVE) then
      lastHeading = h
      lastMove = os.clock()
      resent = false
    elseif os.clock() - lastMove > STALL_TIME then
      if resent then
        ship.clutch("on")
        ship.speed("speed_stop")
        return nil, "turn stalled, rudder not moving"
      end
      ship.turn(dir) -- rudder may have stopped, nudge it again
      resent = true
      lastMove = os.clock()
    end

    if deadline and os.clock() > deadline then
      ship.clutch("on")
      ship.speed("speed_stop")
      return nil, "turn timed out, still " .. math.floor(math.abs(diff) + 0.5) .. " deg off"
    end
  end

  ship.clutch("on")
  ship.speed(resume and "speed_max" or "speed_stop")
  return true
end

return ship
