local Identity = dofile('src/identity.lua')
local source = assert(io.open('src/main.lua','rb'));local main=source:read('*a');source:close()
local files, writes, now, previous_calls = {}, 0, 100, 0
local panel_calls,panel_cleared,panel_failure=0,0,false
local response = {status='OK',members={{peer_id='7',name='队友',steam_name='Steam',status='STEAM',steam_id64='76561197960265729'}}}
local reader = {now=function() return now end,snapshot=function() return response,'room changing' end,menu_state=function() end}
local env = setmetatable({Identity=Identity,Spec={},Native={new=function() return reader end},
    stingray={},Desktop={new=function() return {} end},Panel={new=function()
        return {update=function()
            panel_calls=panel_calls+1
            assert(panel_calls==previous_calls,'panel runs after previous update')
            if panel_failure then error('test UI failure') end
        end,clear=function() panel_cleared=panel_cleared+1 end}
    end},
    CowboyBingusModLoader={open_log=function() return {write=function() end,flush=function() end} end,log_directory='mock'},
    io={open=function(path)
        return {write=function(_,text) files[path]=text;writes=writes+1;return true end,close=function() return true end}
    end},update=function(dt,arg) previous_calls=previous_calls+1;return 'kept',nil,arg,nil end}, {__index=_G})
env._G=env
local entry=assert(loadstring(main));setfenv(entry,env)
local runtime=entry()
assert(runtime.status=='UNKNOWN' and files['mock/HD2RoomSteamInfo.json']:find('"members":[]',1,true))
local function pack(...) return {n=select('#',...),...} end
local values=pack(env.update(0.016,'argument'))
assert(values.n==4 and values[1]=='kept' and values[2]==nil and values[3]=='argument' and values[4]==nil and previous_calls==1)
assert(runtime.status=='OK' and #runtime.members==1)
local before=writes
for i=1,120 do env.update(0.016) end
assert(writes==before,'no per-frame output')
now=102;env.update(0.016);assert(writes==before,'unchanged snapshots do not rewrite output')
response=nil;now=104;env.update(0.016)
assert(runtime.status=='UNKNOWN' and #runtime.members==0)
assert(files['mock/HD2RoomSteamInfo.json']:find('"members":[]',1,true),'stale members cleared')
local wrapper=env.update
local again=assert(loadstring(main));setfenv(again,env)
assert(again()==runtime and env.update==wrapper,'duplicate initialization preserves callback')
response={status='OK',members={}};runtime.refresh();env.update(0.016);assert(runtime.status=='OK')
reader.snapshot=function() error('test read failure') end
now=106;env.update(0.016);assert(runtime.status=='UNKNOWN' and #runtime.members==0)
reader.snapshot=function() return response end
now=108;panel_failure=true;env.update(0.016)
assert(panel_cleared==1 and runtime.ui_status:find('test UI failure',1,true))
local stopped_at=panel_calls
response={status='OK',members={}};now=110;env.update(0.016)
assert(panel_calls==stopped_at and runtime.status=='OK' and #runtime.members==0,'UI failure does not stop exports')
env = setmetatable({Identity=Identity,Native={new=function() return nil,'unsupported build' end},Spec={}}, {__index=_G})
env._G=env
entry=assert(loadstring(main));setfenv(entry,env);runtime=entry();env.update(0.016)
assert(runtime.status=='UNKNOWN' and #runtime.members==0 and runtime.output_error)
print('PASS entry: update chain and nil returns, panel ordering and isolated failure, poll interval, changed-only output, stale clearing, duplicate initialization')
