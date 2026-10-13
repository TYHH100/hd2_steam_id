-- Self-process reads only. No game native functions, writes, hooks or network requests.
local M = {}
local ffi = require('ffi')
ffi.cdef [[
    void *hd2sid1_GetModuleHandleA(const char *) __asm__("GetModuleHandleA");
    void *hd2sid1_GetProcAddress(void *, const char *) __asm__("GetProcAddress");
    void *hd2sid1_GetCurrentProcess(void) __asm__("GetCurrentProcess");
    uint64_t hd2sid1_GetTickCount64(void) __asm__("GetTickCount64");
    int hd2sid1_ReadProcessMemory(void *, const void *, void *, size_t, size_t *) __asm__("ReadProcessMemory");
    typedef void *(*hd2sid1_Interface)(void);
    typedef uint64_t (*hd2sid1_SteamID)(void *);
    typedef const char *(*hd2sid1_PersonaName)(void *, uint64_t);
]]
local K = ffi.load('kernel32')
local process = K.hd2sid1_GetCurrentProcess()
local buffer, transferred = ffi.new('uint8_t[?]', 32768), ffi.new('size_t[1]')
local function read(address, size)
    if not address or address < 65536 or address >= 9007199254740992 or size < 1 or size > 32768 then
        return nil, 'invalid read range'
    end
    transferred[0] = 0
    if K.hd2sid1_ReadProcessMemory(process, ffi.cast('const void *', address), buffer, size, transferred) == 0 or
       tonumber(transferred[0]) ~= size then return nil, 'memory unavailable' end
    return ffi.string(buffer, size)
end
local function u32(bytes, offset)
    local a,b,c,d = bytes:byte(offset+1, offset+4)
    return a + b*256 + c*65536 + d*16777216
end
local function id(bytes, offset) return {lo = u32(bytes, offset), hi = u32(bytes, offset+4)} end
local function pointer(address,alignment)
    local bytes = read(address, 8)
    if not bytes then return nil end
    local value = u32(bytes, 0) + u32(bytes, 4)*4294967296
    if value == 0 then return nil end
    if value < 65536 or value >= 9007199254740992 or value % (alignment or 8) ~= 0 then return nil end
    return value
end
local function module(name, expected)
    local handle = K.hd2sid1_GetModuleHandleA(name)
    if handle == nil then return nil, name .. ' not loaded' end
    local base = tonumber(ffi.cast('uintptr_t', handle))
    local dos = read(base, 64)
    if not dos or dos:sub(1,2) ~= 'MZ' then return nil, 'invalid DOS header' end
    local pe_offset = u32(dos, 60)
    if pe_offset > 4096 then return nil, 'invalid PE header offset' end
    local pe = read(base+pe_offset, 88)
    if not pe or pe:sub(1,4) ~= 'PE\0\0' or u32(pe, 8) ~= expected.timestamp or
       u32(pe, 80) ~= expected.size then return nil, name .. ' build mismatch' end
    for _, proof in ipairs(expected.proofs or {}) do
        if read(base+proof.rva, #proof.bytes) ~= proof.bytes then return nil, name .. ' code proof mismatch' end
    end
    return base
end

function M.new(spec, Identity)
    assert(ffi.abi('64bit'), 'Windows x64 LuaJIT required')
    local game, why = module('game.dll', spec.game)
    if not game then return nil, why end
    local exe; exe, why = module('helldivers2.exe', spec.exe)
    if not exe then return nil, why end
    local steam; steam, why = module('steam_api64.dll', spec.steam)
    if not steam then return nil, why end
    local steam_module = ffi.cast('void *', steam)
    local function bind(name, signature, optional)
        local address = K.hd2sid1_GetProcAddress(steam_module, name)
        if address == nil then
            if optional then return nil end
            error('Steam export unavailable: ' .. name, 0)
        end
        return ffi.cast(signature, address)
    end
    local get_user = bind('SteamAPI_SteamUser_v021', 'hd2sid1_Interface')
    local get_id = bind('SteamAPI_ISteamUser_GetSteamID', 'hd2sid1_SteamID')
    local get_friends = bind('SteamAPI_SteamFriends_v017', 'hd2sid1_Interface', true)
    local get_name = bind('SteamAPI_ISteamFriends_GetFriendPersonaName', 'hd2sid1_PersonaName', true)
    local words = ffi.new('uint64_t[1]')
    local function local_id()
        local user = get_user()
        if user == nil then return nil end
        words[0] = get_id(user)
        return id(ffi.string(words, 8), 0)
    end
    local function steam_name(account)
        if not get_friends or not get_name then return nil end
        local friends = get_friends()
        if friends == nil then return nil end
        local native_id = ffi.cast('uint64_t', account.hi)*4294967296ULL + account.lo
        local ptr = get_name(friends, native_id)
        if ptr == nil then return nil end
        -- Copy through RPM rather than dereferencing a transient native string.
        local text = read(tonumber(ffi.cast('uintptr_t', ptr)), 256)
        if not text then return nil end
        local value = text:match('^(.-)%z')
        if value == '' or value == '[unknown]' then return nil end
        return value
    end
    local function session()
        local ctx = pointer(game+spec.context)
        if not ctx then return nil, 'session unavailable' end
        local ids, count_bytes = read(ctx+spec.local_peer, 8), read(ctx+spec.peer_count, 4)
        if not ids or not count_bytes then return nil, 'session unreadable' end
        local count = u32(count_bytes, 0)
        if count < 1 or count > 4 then return nil, 'session empty or changing' end
        local peers = read(ctx+spec.peers, count*32)
        if not peers then return nil, 'session peers unreadable' end
        local token = {context = ctx, local_bytes = ids, peers_bytes = peers, count = count}
        local result = {local_peer = id(ids,0), peers = {}, names = {}, profiles = {}}
        for i=0,count-1 do result.peers[#result.peers+1] = id(peers,i*32) end
        return result, token
    end
    local function user_table()
        local root = pointer(exe+spec.engine_root)
        local service = root and pointer(root+0x5d0)
        local manager = service and pointer(service+0xa0)
        local users = manager and pointer(manager+0x60)
        if not users then return nil, 'platform mapping unavailable' end
        local bytes = read(users+0xa0, 16)
        if not bytes then return nil, 'platform table unreadable' end
        local count = u32(bytes,0)
        if count < 1 or count > 1024 then return nil, 'invalid platform table size' end
        local entries = pointer(users+0xa8)
        local array = entries and read(entries,count*8)
        if not array then return nil, 'platform entries unreadable' end
        return {root=root,service=service,manager=manager,users=users,count=count,entries=entries,array=array,header=bytes}
    end
    local function snapshot()
        local own = local_id()
        if not Identity.steam(own) then return nil, 'local Steam identity unavailable' end
        local result, token = session()
        if not result then return nil, token end
        local wanted = {}
        for _, peer in ipairs(result.peers) do wanted[Identity.key(peer)] = true end
        local table_before, reason = user_table()
        if not table_before then return nil, reason end
        local matched = {}
        for i=0,table_before.count-1 do
            local parts = id(table_before.array,i*8)
            local address = parts.lo + parts.hi*4294967296
            local bytes = read(address+0x18, 20)
            if not bytes then return nil, 'platform record unreadable' end
            local peer = id(bytes,0)
            local key = Identity.key(peer)
            if wanted[key] then
                if result.profiles[key] then return nil, 'ambiguous platform mapping' end
                local profile = {account = id(bytes,8), platform = u32(bytes,16)}
                if profile.platform == 1 and Identity.steam(profile.account) then profile.steam_name = steam_name(profile.account) end
                result.profiles[key] = profile
                matched[#matched+1] = {address=address+0x18,bytes=bytes}
            end
        end
        local roster = pointer(game+spec.roster)
        local roster_bytes = roster and read(roster,8*192)
        if roster_bytes then
            for i=0,7 do
                local key = Identity.key(id(roster_bytes,i*192))
                if wanted[key] then
                    if result.names[key] then return nil, 'ambiguous roster' end
                    local name = roster_bytes:sub(i*192+9,i*192+128):match('^(.-)%z')
                    if name and name ~= '' then result.names[key] = name end
                end
            end
        end
        -- Re-read all identity fields and roots after copying; reject changing rooms.
        for _, record in ipairs(matched) do
            if read(record.address,20) ~= record.bytes then return nil, 'platform identity changed while reading' end
        end
        local table_after = user_table()
        if not table_after or table_after.root ~= table_before.root or table_after.service ~= table_before.service or
           table_after.manager ~= table_before.manager or table_after.users ~= table_before.users or
           table_after.entries ~= table_before.entries or table_after.header ~= table_before.header or
           table_after.array ~= table_before.array then return nil, 'platform table changed while reading' end
        if roster_bytes and (pointer(game+spec.roster) ~= roster or read(roster,#roster_bytes) ~= roster_bytes) then
            return nil, 'roster changed while reading'
        end
        local _, after = session()
        if type(after) ~= 'table' or after.context ~= token.context or after.count ~= token.count or
           after.local_bytes ~= token.local_bytes or after.peers_bytes ~= token.peers_bytes then
            return nil, 'session changed while reading'
        end
        local own_after = local_id()
        if not own_after or not Identity.same(own,own_after) then return nil, 'local Steam identity changed' end
        return Identity.collect(result,own)
    end
    local ui_supported, ui_reason = false, 'menu layout unavailable'
    if spec.ui then
        ui_supported=true
        for _, proof in ipairs(spec.ui.proofs or {}) do
            if read(game+proof.rva,#proof.bytes) ~= proof.bytes then
                ui_supported=false;ui_reason=string.format('menu code proof mismatch at RVA 0x%x',proof.rva);break
            end
        end
    end
    local function hash(address)
        local bytes=read(address,8)
        if not bytes or bytes==string.rep('\0',8) then return nil end
        local parts={}
        -- Memory is little-endian; from_hex expects the integer hex spelling.
        for i=8,1,-1 do parts[#parts+1]=string.format('%02x',bytes:byte(i)) end
        return table.concat(parts)
    end
    local function menu_state()
        if not ui_supported then return nil,ui_reason end
        local menu=pointer(game+spec.ui.menu)
        local screen=menu and pointer(menu+200)
        if not screen then return nil,'closed' end
        local shown=read(screen+8,4)
        if not shown or u32(shown,0)~=0 then return nil,'other tab' end
        local content=screen+281480
        local hidden=read(content+1989808,1)
        local dialog=read(content+1989648,2)
        if not hidden or hidden:byte(1)~=0 or not dialog or dialog:byte(1)==0 or dialog:byte(2)~=0 then
            return nil,'menu hidden or dialog open'
        end
        local font,atlas=hash(game+spec.ui.font),hash(game+spec.ui.atlas)
        -- Engine material handles are 4-byte aligned; an observed valid handle
        -- ends in 0xCC. Session/menu pointers retain their stricter 8-byte check.
        local material_ptr=pointer(game+spec.ui.material,4)
        local material=material_ptr and hash(material_ptr+24)
        if not font or not atlas or not material then return nil,'menu font unavailable' end
        if pointer(menu+200)~=screen or read(screen+8,4)~=shown or read(content+1989808,1)~=hidden or
           read(content+1989648,2)~=dialog then return nil,'menu changing' end
        return {screen=screen,font=font,atlas=atlas,material=material}
    end
    return {snapshot = snapshot, menu_state=menu_state,
            now = function() return tonumber(K.hd2sid1_GetTickCount64())/1000 end}
end

return M
