local real_ffi=require('ffi')
local source=assert(io.open('src/desktop.lua','rb'));local code=source:read('*a');source:close()
local function fixture()
    local world={pid=123,foreground=123,down=false,freed=0,closed=0,empty=0,sent=0}
    local blocks={}
    local U={
        hd2sid2_GetForegroundWindow=function() return real_ffi.cast('void *',1) end,
        hd2sid2_GetWindowThreadProcessId=function(_,p) p[0]=world.foreground;return 1 end,
        hd2sid2_GetCursorPos=function(p) p[0].x=320;p[0].y=180;return 1 end,
        hd2sid2_ScreenToClient=function() return 1 end,
        hd2sid2_GetClientRect=function(_,r) r[0].left=0;r[0].top=0;r[0].right=1280;r[0].bottom=720;return 1 end,
        hd2sid2_GetAsyncKeyState=function() return world.down and -32768 or 0 end,
        hd2sid2_OpenClipboard=function() return world.fail=='open' and 0 or 1 end,
        hd2sid2_EmptyClipboard=function() world.empty=world.empty+1;return world.fail=='empty' and 0 or 1 end,
        hd2sid2_SetClipboardData=function(kind,memory)
            assert(kind==13);world.sent=world.sent+1
            if world.fail=='set' then return nil end
            local ptr=real_ffi.cast('uint16_t *',memory);local s={};local i=0
            while ptr[i]~=0 do s[#s+1]=string.char(ptr[i]);i=i+1 end
            world.copied=table.concat(s);return memory
        end,
        hd2sid2_CloseClipboard=function() world.closed=world.closed+1;return 1 end}
    local K={hd2sid2_GetCurrentProcessId=function() return world.pid end,
        hd2sid2_GlobalAlloc=function(flags,size)
            assert(flags==2)
            if world.fail=='alloc' then return nil end
            local block=real_ffi.new('uint8_t[?]',size);blocks[#blocks+1]=block;return real_ffi.cast('void *',block)
        end,
        hd2sid2_GlobalLock=function(memory) if world.fail=='lock' then return nil end;return memory end,
        hd2sid2_GlobalUnlock=function() return 1 end,
        hd2sid2_GlobalFree=function() world.freed=world.freed+1 end}
    local ffi=setmetatable({load=function(name) return name=='user32' and U or K end},{__index=real_ffi})
    local env=setmetatable({require=function(name) if name=='ffi' then return ffi end;return require(name) end},{__index=_G})
    local chunk=assert(loadstring(code));setfenv(chunk,env);world.desktop=chunk().new()
    return world
end
local link='https://steamcommunity.com/profiles/76561198711733435'
local w=fixture();local p=w.desktop.sample(1920,1080)
assert(p.x==480 and p.y==810 and not p.down,'client top-left maps to GUI bottom-left')
w.down=true;assert(w.desktop.sample(1920,1080).down)
assert(w.desktop.copy_link(link) and w.copied==link and w.closed==1 and w.freed==0)
assert(not w.desktop.copy_link('https://example.com') and w.sent==1)
w.foreground=999;assert(not w.desktop.sample(1920,1080) and not w.desktop.copy_link(link))
for _,failure in ipairs({'alloc','lock','open','empty','set'}) do
    w=fixture();w.fail=failure;assert(not w.desktop.copy_link(link),failure)
    assert(w.freed==(failure=='alloc' and 0 or 1),'free untransferred memory: '..failure)
    assert(w.closed==((failure=='empty' or failure=='set') and 1 or 0),'close only opened clipboard: '..failure)
end
print('PASS desktop: foreground and coordinates, Unicode clipboard contents, ownership transfer, failed alloc/lock/open/empty/set cleanup')
