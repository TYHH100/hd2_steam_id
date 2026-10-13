-- Domain logic; IDs are pairs of exact uint32 values, never Lua doubles.
local M = {}
local format, concat = string.format, table.concat

function M.key(id) return format('%08X%08X', id.hi, id.lo) end
function M.same(a, b) return a.lo == b.lo and a.hi == b.hi end
function M.zero(id) return id.lo == 0 and id.hi == 0 end

function M.decimal(id)
    local lo, hi, chunks = id.lo, id.hi, {}
    repeat
        local rem = hi % 1000000
        hi = (hi - rem) / 1000000
        local value = rem * 4294967296 + lo
        local part = value % 1000000
        lo = (value - part) / 1000000
        table.insert(chunks, 1, format((hi > 0 or lo > 0) and '%06d' or '%d', part))
    until lo == 0 and hi == 0
    return concat(chunks)
end

-- Public universe, individual account, desktop instance, nonzero account ID.
function M.steam(id)
    return id and id.hi == 0x01100001 and id.lo > 0
end

function M.collect(snapshot, local_steam)
    if not M.steam(local_steam) then return nil, 'local Steam identity unavailable' end
    if not snapshot or M.zero(snapshot.local_peer) then return nil, 'local peer unavailable' end
    if #snapshot.peers < 1 or #snapshot.peers > 4 then return nil, 'invalid session size' end
    local seen, local_present, local_profile = {}, false, nil
    for _, peer in ipairs(snapshot.peers) do
        local key = M.key(peer)
        if M.zero(peer) or seen[key] then return nil, 'invalid or duplicate session peer' end
        seen[key] = true
        if M.same(peer, snapshot.local_peer) then local_present = true end
    end
    if not local_present then return nil, 'local peer absent from session' end
    local_profile = snapshot.profiles[M.key(snapshot.local_peer)]
    if not local_profile or local_profile.platform ~= 1 or
       not M.same(local_profile.account, local_steam) then
        return nil, 'local platform mapping does not match Steam'
    end
    local result, used_accounts = {}, {[M.key(local_steam)] = true}
    for _, peer in ipairs(snapshot.peers) do
        if not M.same(peer, snapshot.local_peer) then
            local key, profile = M.key(peer), snapshot.profiles[M.key(peer)]
            local row = {peer_id = M.decimal(peer), name = snapshot.names[key] or 'UNKNOWN',
                         status = 'UNKNOWN', steam_id64 = 'UNKNOWN', steam_name = 'UNKNOWN'}
            if profile then
                row.platform_code = profile.platform
                if profile.platform == 1 and M.steam(profile.account) then
                    local account_key = M.key(profile.account)
                    if used_accounts[account_key] then return nil, 'duplicate or local Steam account in remote mapping' end
                    used_accounts[account_key] = true
                    row.status = 'STEAM'
                    row.steam_id64 = M.decimal(profile.account)
                    row.account_id = profile.account.lo
                    row.profile_url = 'https://steamcommunity.com/profiles/' .. row.steam_id64
                    row.steam_name = profile.steam_name or 'UNKNOWN'
                elseif profile.platform ~= 1 then
                    row.status = 'NO_STEAM_MAPPING'
                    if profile.platform == 0 then row.platform_name = '主机平台' end
                end
            end
            result[#result + 1] = row
        end
    end
    return {status = 'OK', self_excluded = true, members = result}
end

local function quote(value)
    local escapes = {['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t'}
    return '"' .. tostring(value):gsub('[%z\1-\31\\"]', function(c)
        return escapes[c] or format('\\u%04x', c:byte())
    end) .. '"'
end

function M.json(result, timestamp)
    local rows = {}
    for _, row in ipairs(result.members) do
        local fields = {}
        for _, key in ipairs({'peer_id', 'name', 'status', 'steam_id64', 'steam_name', 'profile_url', 'platform_name'}) do
            if row[key] ~= nil then fields[#fields + 1] = quote(key) .. ':' .. quote(row[key]) end
        end
        for _, key in ipairs({'platform_code', 'account_id'}) do
            if row[key] ~= nil then fields[#fields + 1] = quote(key) .. ':' .. format('%d', row[key]) end
        end
        rows[#rows + 1] = '{' .. concat(fields, ',') .. '}'
    end
    return '{"schema":1,"status":' .. quote(result.status) .. ',"reason":' .. quote(result.reason or '') ..
        ',"observed_at":' .. quote(timestamp) .. ',"self_excluded":true,"members":[' .. concat(rows, ',') .. ']}\n'
end

function M.text(result, timestamp)
    local rows = {'HD2 当前房间 Steam 信息（已排除自己）', '时间：' .. timestamp,
                  '状态：' .. result.status .. (result.reason and (' / ' .. result.reason) or ''),
                  '其他成员：' .. #result.members, ''}
    for i, row in ipairs(result.members) do
        rows[#rows + 1] = i .. '. ' .. row.name:gsub('[\r\n\t]', ' ')
        rows[#rows + 1] = '   平台：' .. (row.platform_name or (row.status=='STEAM' and 'Steam' or '未知'))
        rows[#rows + 1] = '   Steam 昵称：' .. row.steam_name:gsub('[\r\n\t]', ' ')
        rows[#rows + 1] = '   SteamID64：' .. row.steam_id64 .. ' (' .. row.status .. ')'
        if row.profile_url then rows[#rows + 1] = '   ' .. row.profile_url end
        rows[#rows + 1] = ''
    end
    return concat(rows, '\n') .. '\n'
end

return M
