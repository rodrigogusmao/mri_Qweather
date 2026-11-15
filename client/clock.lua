QClientClock = {}

-- Anchor of the server minute: seconds in between are filled locally so the sky moves smoothly.
local anchor = { hour = 8, minute = 0, at = 0, ms = 5000, frozen = false }
local transition = nil

-- The engine clock runs by itself at the speed we give it, so NetworkOverrideClockTime
-- only needs to be called when the anchor changes, instead of every frame.
-- FROZEN_MS (~11 real days per game minute) holds the clock still: used while the clock
-- is frozen, while paused, and once the current minute has run out and the next anchor
-- has not arrived yet (the same 59 s cap current() applies).
-- If the engine ignores the rate (the clock keeps running ahead on its own), `legacy`
-- switches back to overriding the clock every frame, as before.
local FROZEN_MS = 1000000000
local DRIFT_TOLERANCE = 3   -- game seconds
local LEGACY_AFTER = 4      -- consecutive bad checks before giving up on the engine rate
local CHECK_INTERVAL = 250  -- ms

local legacy = false
local rate = nil
local forceApply = true

local function toSeconds(hour, minute, second)
    return hour * 3600 + minute * 60 + (second or 0)
end

local function current()
    local seconds = toSeconds(anchor.hour, anchor.minute)
    if not anchor.frozen then
        seconds += math.min(59, math.floor((GetGameTimer() - anchor.at) / anchor.ms * 60))
    end
    return seconds % 86400
end

-- Speed the engine clock should run at right now, mirroring current().
local function wantedRate()
    if QClient.paused or anchor.frozen then return FROZEN_MS end
    -- the minute is over: hold at :59 until the next anchor, like current() does
    if (GetGameTimer() - anchor.at) / anchor.ms * 60 >= 59 then return FROZEN_MS end
    return math.max(1, math.floor(anchor.ms))
end

local function setRate(ms)
    SetMillisecondsPerGameMinute(ms)
    pcall(Citizen.InvokeNative, 0x42BF1D2E723B6D7E, ms) -- NETWORK_OVERRIDE_CLOCK_MILLISECONDS_PER_GAME_MINUTE
    rate = ms
end

local function setClock(seconds)
    NetworkOverrideClockTime(seconds // 3600, (seconds % 3600) // 60, seconds % 60)
end

function QClientClock.time()
    return anchor.hour, anchor.minute
end

local function apply(clock)
    if not clock then return end
    local before = current()
    anchor = { hour = clock.hour, minute = clock.minute, at = GetGameTimer(), ms = clock.ms or 5000, frozen = clock.frozen == true }
    local after = current()
    local gap = (after - before) % 86400
    -- A jump of more than two minutes (admin set the time) rolls forward over 3 s instead of snapping.
    if not clock.jump and gap > 120 and gap < 86400 - 120 then
        transition = { from = before, to = before + gap, started = GetGameTimer(), duration = 3000 }
    else
        transition = nil
    end
    forceApply = true
end

apply(GlobalState[QWeather.keys.clock])

AddStateBagChangeHandler(QWeather.keys.clock, 'global', function(_, _, value)
    apply(value)
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    SetMillisecondsPerGameMinute(2000)
    pcall(Citizen.InvokeNative, 0x42BF1D2E723B6D7E, 2000)
end)

local function target()
    if QClient.paused then return toSeconds(QClient.pausedHour or 20, 0) end
    return current()
end

CreateThread(function()
    local misses = 0
    local wasPaused = QClient.paused
    while true do
        if transition and not QClient.paused then
            local t = (GetGameTimer() - transition.started) / transition.duration
            if t >= 1 then
                transition = nil
                forceApply = true
            else
                setClock(math.floor(transition.from + (transition.to - transition.from) * t) % 86400)
            end
            Wait(0)
        elseif legacy then
            setClock(target())
            Wait(0)
        else
            local seconds = target()
            local ms = wantedRate()
            if QClient.paused ~= wasPaused then
                wasPaused = QClient.paused
                forceApply = true
            end

            if ms ~= rate or forceApply then
                -- changing the rate rescales the seconds inside the minute, so re-anchor too
                setRate(ms)
                setClock(seconds)
                forceApply = false
                misses = 0
            else
                local now = toSeconds(GetClockHours(), GetClockMinutes(), GetClockSeconds())
                local drift = (now - seconds + 43200) % 86400 - 43200
                if math.abs(drift) > DRIFT_TOLERANCE then
                    -- running ahead by itself = the engine is not honouring the rate
                    misses = (drift > 0 and drift <= 300) and misses + 1 or 0
                    if misses >= LEGACY_AFTER then
                        legacy = true
                        SetMillisecondsPerGameMinute(2000)
                        print('^3[mri_Qweather] engine clock rate not honoured; overriding the clock every frame.^0')
                    end
                    setClock(seconds)
                else
                    misses = 0
                end
            end
            Wait(CHECK_INTERVAL)
        end
    end
end)
