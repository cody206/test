local ship = require("ship")

local ALIGN_TOL = 8 -- degrees, steering holds the ship tighter than this
local HARD_TOL = 45 -- degrees, beyond this a full stop-and-turn is faster
local STOP_DIST = 100 -- blocks; inside this range engines are cut and the
                      -- ship coasts (plus stop-and-turns for any steering), so
local ARRIVE_DIST = 3 -- blocks

local function printStatus(pos, target)
  local h = ship.heading(pos)
  local b = ship.bearingTo(pos.mid, target)
  local d = ship.dist(pos.mid, target)
  print(("heading %d  bearing %d  dist %.0f"):format(h or -1, b or -1, d))
end

local function flyTo(target)
  ship.speed("speed_max")
  local enginesStopped = false
  local lastD, stillCycles = nil, 0

  while true do
    local pos, err = ship.getPositionsRetry(3)
    if not pos then return nil, "gps: " .. err end

    local d = ship.dist(pos.mid, target)
    if d <= ARRIVE_DIST then
      ship.speed("speed_stop")
      ship.clutch("on")
      print("arrived")
      return true
    end

    printStatus(pos, target)

    local h = ship.heading(pos)
    local diff = h and ship.angularDiff(ship.bearingTo(pos.mid, target), h)
    local close = d <= STOP_DIST
    local off = diff and math.abs(diff) or 0

    if not diff then
      sleep(0.3)
    elseif off > HARD_TOL or (close and off > ALIGN_TOL) then
      -- steering inside stop range is done stopped: engines stay off after
      -- the turn so we coast instead of resuming cruise
      local ok, terr = ship.turnToward(pos, target, ALIGN_TOL, nil, not close)
      if not ok then return nil, "turn failed: " .. tostring(terr) end
      enginesStopped = close
      lastD, stillCycles = nil, 0
    elseif close then
      -- aligned and inside stop range: cut the engines, coast to the target
      if not enginesStopped then
        ship.speed("speed_stop")
        enginesStopped = true
        lastD, stillCycles = d, 0
      elseif d < lastD - 0.05 then
        stillCycles = 0 -- still closing under momentum
      else
        stillCycles = stillCycles + 1
      end
      lastD = d
      if stillCycles >= 3 then
        -- drifted to a halt short of the target: creep in, then cut again
        print("coast stalled, creeping (" .. ("%.0f"):format(d) .. " left)")
        ship.speed("speed_mid")
        sleep(1)
        ship.speed("speed_stop")
        stillCycles = 0
      end
    else
      -- far away: normal cruise with rudder corrections
      if enginesStopped then
        enginesStopped = false
        ship.speed("speed_max")
      end
      local ok, serr = ship.steerWhileCruising(pos, target, ALIGN_TOL)
      if not ok then return nil, "steer failed: " .. tostring(serr) end
    end

    sleep(0.3)
  end
end

local function readCoord(prompt)
  while true do
    write(prompt .. " (x z, 'q' to quit): ")
    local line = read()
    if line == "q" then return nil end
    local x, z = line:match("^%s*(-?%d+)%s+(-?%d+)%s*$")
    if x then return { x = tonumber(x), z = tonumber(z) } end
    print("enter as: <x> <z>")
  end
end

print("airship autopilot")
print("gps check...")
local pos, err = ship.getPositions()
if not pos then
  print("gps check failed: " .. err)
  return
end
printStatus(pos, pos.mid)

while true do
  local target = readCoord("target")
  if not target then break end

  print(("nav to %d %d"):format(target.x, target.z))
  local ok, ferr = flyTo(target)
  if ok then
    print("done")
  else
    print("aborted: " .. tostring(ferr))
    ship.speed("speed_stop")
    ship.clutch("on")
  end
end
