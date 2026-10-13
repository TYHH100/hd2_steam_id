local M = dofile('src/identity.lua')
local own = {lo=1234,hi=0x01100001}
local self = {lo=0x83f81b68,hi=0xe977289b}
local other = {lo=0xffffffff,hi=0xabcdef12}
local historical = {lo=10,hi=22}
local function profile(account, platform, name)
    return {account=account,platform=platform or 1,steam_name=name}
end
local function world()
    return {local_peer=self,peers={self,other},
        names={[M.key(self)]='我',[M.key(other)]='队友 "测试"\n\\'},
        profiles={[M.key(self)]=profile(own),[M.key(other)]=profile({lo=1235,hi=0x01100001},1,'Steam 队友'),
                  [M.key(historical)]=profile({lo=9999,hi=0x01100001},1,'已离开')}}
end
assert(M.decimal({lo=0xffffffff,hi=0xffffffff})=='18446744073709551615')
assert(M.decimal({lo=0,hi=0})=='0')
assert(M.decimal({lo=0,hi=0x01100001})=='76561197960265728')
local result = assert(M.collect(world(),own))
assert(#result.members==1 and result.members[1].steam_id64=='76561197960266963')
assert(result.members[1].steam_name=='Steam 队友')
local encoded=M.json(result,'2026-10-13')
assert(encoded:find('\\"测试\\"\\n\\\\',1,true))
assert(not encoded:find('76561197960266962',1,true))
assert(not encoded:find('已离开',1,true))
local file=assert(io.open('build/test-result.json','wb'));assert(file:write(encoded));assert(file:close())
local w=world();w.peers={self};assert(#assert(M.collect(w,own)).members==0)
w=world();w.peers={other};assert(not M.collect(w,own))
w=world();w.profiles[M.key(self)].account={lo=5,hi=0x01100001};assert(not M.collect(w,own))
w=world();w.profiles[M.key(other)].account=own;assert(not M.collect(w,own))
w=world();w.peers={self,other,other};assert(not M.collect(w,own))
w=world();w.profiles[M.key(other)]=nil;result=assert(M.collect(w,own));assert(result.members[1].status=='UNKNOWN')
w=world();w.profiles[M.key(other)].platform=2;result=assert(M.collect(w,own));assert(result.members[1].status=='NO_STEAM_MAPPING' and not result.members[1].profile_url)
w=world();w.profiles[M.key(other)].account={lo=7,hi=0xe977289b};result=assert(M.collect(w,own));assert(result.members[1].status=='UNKNOWN' and not result.members[1].profile_url)
assert(not M.collect(world(),{lo=0,hi=0}))
print('PASS identity: exact uint64, self exclusion, active members, stale caches, cross-platform, ambiguous identities, JSON escaping')
