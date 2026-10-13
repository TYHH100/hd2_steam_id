if rawget(_G,'HD2RoomSteamInfo') then return rawget(_G,'HD2RoomSteamInfo') end
local runtime = {version='0.2.2', status='WAITING', members={},revision=0}
rawset(_G,'HD2RoomSteamInfo',runtime)
local loader = rawget(_G,'CowboyBingusModLoader')
local log, reader, next_attempt, last_content, log_errors = nil, nil, 0, nil, 0
local output_dir
if type(loader)=='table' and type(loader.open_log)=='function' then
    local ok, value = pcall(loader.open_log,'HD2RoomSteamInfo.log')
    if ok then log = value end
    output_dir = loader.log_directory
end
local function note(text)
    if log then pcall(function() log:write(os.date('%Y-%m-%d %H:%M:%S') .. ' ' .. text .. '\n'); log:flush() end) end
end
local function write_file(name, text)
    if not output_dir then return nil,'loader log directory unavailable' end
    local path = output_dir .. '/' .. name
    -- Windows CRT rename cannot replace an existing destination; MoveFileEx is
    -- unnecessary here. Files are small, overwritten only after a complete snapshot.
    local file, why = io.open(path,'wb')
    if not file then return nil,why end
    local ok, reason = file:write(text)
    local closed, close_reason = file:close()
    if not ok or not closed then return nil,reason or close_reason end
    return true
end
local function publish(result)
    runtime.status, runtime.reason, runtime.members = result.status,result.reason,result.members
    local comparable = Identity.json(result,'')
    if comparable == last_content then return end
    runtime.revision=runtime.revision+1
    local timestamp = os.date('%Y-%m-%d %H:%M:%S')
    local json_ok, why = write_file('HD2RoomSteamInfo.json',Identity.json(result,timestamp))
    local text_ok, text_why = write_file('HD2RoomSteamInfo.txt',Identity.text(result,timestamp))
    runtime.output_error = why or text_why
    if json_ok and text_ok then last_content = comparable end
    if runtime.output_error then
        log_errors = log_errors+1
        if log_errors <= 3 then note('Output unavailable: ' .. tostring(runtime.output_error)) end
    else
        note(result.status .. ': ' .. #result.members .. ' remote members' .. (result.reason and ('; ' .. result.reason) or ''))
    end
end
local function unknown(why) return {status='UNKNOWN',reason=tostring(why),members={}} end
publish(unknown('waiting for first session snapshot'))
local previous_update = rawget(_G,'update')
local clock_seconds = 0
local function step(dt)
    -- Until the native timer is available, use only the game's bounded dt.
    if type(dt)=='number' and dt==dt and dt>0 then clock_seconds = clock_seconds+math.min(dt,1) end
    local now = reader and reader.now() or clock_seconds
    if now < next_attempt then return end
    next_attempt = now + 2
    if not reader then
        local ok, value, why = pcall(Native.new,Spec,Identity)
        if not ok or not value then
            publish(unknown(why or value)); return
        end
        reader=value
        next_attempt=reader.now()+2
        note('Read-only memory reader ready; poll every 2 seconds; no network requests.')
    end
    local result, why = reader.snapshot()
    publish(result or unknown(why))
end
local panel,ui_failed,ui_errors,last_ui_status
local function ui_status(value)
    runtime.ui_status=value
    if value~=last_ui_status then note('Panel state: '..tostring(value));last_ui_status=value end
end
local function draw_panel()
    if ui_failed or not reader or type(reader.menu_state)~='function' then return end
    local engine=rawget(_G,'stingray')
    if not engine then ui_status('Stingray GUI unavailable');return end
    if not panel then panel=Panel.new(engine,Desktop.new()) end
    ui_status(panel.update(reader,runtime))
end
local function update_panel()
    local ok,why=pcall(draw_panel)
    if not ok then
        ui_errors=(ui_errors or 0)+1
        ui_status(tostring(why))
        if panel then pcall(panel.clear) end
        if ui_errors<=3 then note('Panel unavailable: '..tostring(why)) end
        -- UI failures stop only the panel; identity exports remain available.
        ui_failed=true
    end
end
local function pack(...) return {n=select('#',...),...} end
local unpack_values=unpack
update = function(dt,...)
    local ok, why = pcall(step,dt)
    if not ok then
        runtime.members={};runtime.status='UNKNOWN';runtime.reason=tostring(why)
        pcall(publish,unknown(why))
    end
    if type(previous_update)=='function' then
        local values=pack(pcall(previous_update,dt,...))
        if not values[1] then
            if panel then pcall(panel.clear) end
            error(values[2],0)
        end
        update_panel()
        return unpack_values(values,2,values.n)
    end
    update_panel()
end
runtime.refresh = function() next_attempt=0 end
note('HD2 Room Steam Info 0.2.2 loaded; Esc GAME-tab panel; click links to copy.')
return runtime
