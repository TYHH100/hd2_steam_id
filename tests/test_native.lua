-- Exercise the real Lua reader with a deterministic read-only process fixture.
local ffi = require('ffi')
local Identity = dofile('src/identity.lua')
local function uint32(n)
    local bytes={};for i=1,4 do bytes[i]=string.char(n%256);n=math.floor(n/256) end
    return table.concat(bytes)
end
local function uint64(lo,hi) return uint32(lo)..uint32(hi or 0) end
local function fixture()
    local bytes, reads = {}, {}
    local function put(address,value) for i=1,#value do bytes[address+i-1]=value:byte(i) end end
    local function zeros(address,size) put(address,string.rep('\0',size)) end
    local spec={context=0x100,roster=0x108,local_peer=8,peer_count=24,peers=32,engine_root=0x100}
    local modules={['game.dll']=0x100000,['helldivers2.exe']=0x200000,['steam_api64.dll']=0x300000}
    for key,name in pairs({game='game.dll',exe='helldivers2.exe',steam='steam_api64.dll'}) do
        local base=modules[name];zeros(base,1024)
        put(base,'MZ');put(base+60,uint32(128));put(base+128,'PE\0\0')
        put(base+136,uint32(123));put(base+208,uint32(1024))
        spec[key]={timestamp=123,size=1024,proofs={}}
    end
    spec.game.proofs={{rva=512,bytes='PROOF'}};put(0x100200,'PROOF')
    spec.ui={menu=0x110,font=0x118,atlas=0x120,material=0x128,proofs={{rva=512,bytes='PROOF'}}}
    put(0x100110,uint64(0xc00000));put(0xc000c8,uint64(0xd00000))
    put(0xd00008,uint32(0));put(0xd00000+281480+1989808,string.char(0))
    put(0xd00000+281480+1989648,string.char(1,0))
    put(0x100118,string.char(1,2,3,4,5,6,7,8));put(0x100120,string.rep('A',8))
    put(0x100128,uint64(0xe00004));put(0xe0001c,string.rep('B',8))
    local own={lo=1234,hi=0x01100001}
    local self={lo=7,hi=0xe977289b};local peer={lo=8,hi=0xe977289b}
    local ctx,root,service,manager,users,array=0x400000,0x500000,0x600000,0x700000,0x800000,0x900000
    zeros(ctx,128);put(0x100100,uint64(ctx));put(ctx+8,uint64(self.lo,self.hi));put(ctx+24,uint32(2))
    put(ctx+32,uint64(self.lo,self.hi)..string.rep('\0',24)..uint64(peer.lo,peer.hi)..string.rep('\0',24))
    put(0x200100,uint64(root));put(root+0x5d0,uint64(service));put(service+0xa0,uint64(manager))
    put(manager+0x60,uint64(users));put(users+0xa0,uint32(3)..uint32(0)..uint64(array))
    put(array,uint64(0xa00000)..uint64(0xa00100)..uint64(0xa00200))
    put(0xa00018,uint64(self.lo,self.hi)..uint64(own.lo,own.hi)..uint32(1))
    put(0xa00118,uint64(peer.lo,peer.hi)..uint64(1235,0x01100001)..uint32(1))
    put(0xa00218,uint64(99,99)..uint64(8888,0x01100001)..uint32(1))
    local roster=0xb00000;zeros(roster,1536);put(0x100108,uint64(roster))
    put(roster,uint64(self.lo,self.hi)..'Self\0');put(roster+192,uint64(peer.lo,peer.hi)..'Remote\0')
    put(roster+384,uint64(0,0)..'Historical\0')
    local world={put=put,bytes=bytes,modules=modules,spec=spec,reads=reads,ctx=ctx}
    local exports={SteamAPI_SteamUser_v021=function() return ffi.cast('void *',1) end,
        SteamAPI_ISteamUser_GetSteamID=function() return ffi.cast('uint64_t',own.hi)*4294967296ULL+own.lo end}
    local K={hd2sid1_GetCurrentProcess=function() return ffi.cast('void *',1) end,
        hd2sid1_GetTickCount64=function() return 100000 end,
        hd2sid1_GetModuleHandleA=function(name) return modules[name] and ffi.cast('void *',modules[name]) end,
        hd2sid1_GetProcAddress=function(_,name) return exports[name] end}
    function K.hd2sid1_ReadProcessMemory(_,pointer,buffer,size,transferred)
        local address=tonumber(ffi.cast('uintptr_t',pointer))
        reads[address]=(reads[address] or 0)+1
        if world.mutate then world.mutate(address,reads[address]) end
        local text={}
        for i=0,size-1 do if bytes[address+i]==nil then return 0 end;text[#text+1]=string.char(bytes[address+i]) end
        ffi.copy(buffer,table.concat(text),size);transferred[0]=size;return 1
    end
    local proxy=setmetatable({load=function(name) assert(name=='kernel32');return K end,
        cast=function(signature,value)
            if type(value)=='function' then return value end
            return ffi.cast(signature,value)
        end},{__index=ffi})
    local env=setmetatable({require=function(name) if name=='ffi' then return proxy end;return require(name) end},{__index=_G})
    local chunk=assert(loadfile('src/native.lua'));setfenv(chunk,env)
    world.native=chunk();world.reader=assert(world.native.new(spec,Identity))
    return world
end
local w=fixture();local result=assert(w.reader.snapshot())
assert(#result.members==1 and result.members[1].name=='Remote')
assert(result.members[1].steam_id64=='76561197960266963' and result.members[1].steam_name=='UNKNOWN')
local menu=assert(w.reader.menu_state());assert(menu.font=='0807060504030201','little-endian font hash must reverse for IdString64')
assert(menu.material=='4242424242424242','4-byte-aligned material handle must be accepted')
w=fixture();w.put(0xc000c8,uint64(0));assert(not w.reader.menu_state())
w=fixture();w.put(0xd00008,uint32(1));assert(not w.reader.menu_state())
w=fixture();w.put(0xd00000+281480+1989808,string.char(1));assert(not w.reader.menu_state())
w=fixture();w.put(0xd00000+281480+1989648,string.char(0,1));assert(not w.reader.menu_state())
w=fixture();w.put(0x100118,string.rep('\0',8));assert(not w.reader.menu_state())
w=fixture();w.spec.ui.proofs={{rva=520,bytes='BAD'}}
w.reader=assert(w.native.new(w.spec,Identity))
local _,ui_reason=w.reader.menu_state()
assert(ui_reason=='menu code proof mismatch at RVA 0x208')
assert(w.reader.snapshot(),'unsupported UI must not disable identity reading')
w=fixture();w.put(0xa00118,uint64(8,0xe977289b)..uint64(1235,0x01100001)..uint32(2))
result=assert(w.reader.snapshot());assert(result.members[1].status=='NO_STEAM_MAPPING')
w=fixture();w.put(0xa00020,uint64(5,0x01100001));assert(not w.reader.snapshot())
w=fixture();w.bytes[0xa00118]=nil;assert(not w.reader.snapshot())
w=fixture();w.put(w.ctx+24,uint32(5));assert(not w.reader.snapshot())
w=fixture();w.put(0x100200,'WRONG');assert(not w.native.new(w.spec,Identity))
w=fixture();w.modules['steam_api64.dll']=nil;assert(not w.native.new(w.spec,Identity))
w=fixture();w.mutate=function(address,n)
    if address==w.ctx+32 and n==2 then w.put(address,uint64(9,0xe977289b)) end
end
local _,why=w.reader.snapshot();assert(why=='session changed while reading')
w=fixture();w.mutate=function(address,n)
    if address==0xa00118 and n==2 then w.put(address+8,uint64(999,0x01100001)) end
end
_,why=w.reader.snapshot();assert(why=='platform identity changed while reading')
print('PASS native: real parser, current-peer mapping, stale caches, Steam local check, missing reads/builds, concurrent session and identity changes')
