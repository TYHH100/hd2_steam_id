local Panel=dofile('src/panel.lua')
local json_identity=dofile('src/identity.lua')
local created,destroyed,texts,rects=0,0,{},{}
local world,main={},{}
local active_worlds={main,world}
local width,height=1920,1080
local engine={Application={worlds=function() return active_worlds end,main_world=function() return main end},
    World={create_screen_gui=function() created=created+1;texts={};rects={};return {} end,
           destroy_gui=function() destroyed=destroyed+1 end},
    Vector2=function(x,y) return {x=x,y=y} end,Vector3=function(x,y,z) return {x=x,y=y,z=z} end,
    Color=function(a,r,g,b) return {a,r,g,b} end,IdString64={from_hex=function(h) return h end},
    Material={set_scalar=function() end,set_vector2=function() end,set_vector4=function() end,set_texture=function() end}}
engine.Gui={resolution=function() return width,height end,material=function() return {} end,
    text=function(_,value,_,size,_,pos,c) texts[#texts+1]={value=value,size=size,pos=pos,color=c} end,
    rect=function(_,pos,extent,c) rects[#rects+1]={pos=pos,extent=extent,color=c} end,
    text_extents=function(_,value,_,size)
        local cells=0
        for char in value:gmatch('[%z\1-\127\194-\244][\128-\191]*') do cells=cells+(#char>1 and 1 or 0.55) end
        return {x=0,y=-size*0.2},{x=cells*size,y=size}
    end}
local steam={name='baijing000',steam_name='UNKNOWN',status='STEAM',steam_id64='76561198711733435',
    profile_url='https://steamcommunity.com/profiles/76561198711733435'}
local runtime={status='OK',revision=1,members={{name='jhmolvig',platform_name='主机平台'},
    {name='jumbo-bay9',platform_name='主机平台'},steam}}
local state={screen=10,font='f',material='m',atlas='a'}
local input={x=0,y=0,down=false};local copy_count,copied=0,nil
local desktop={sample=function() return input end,copy_link=function(link) copy_count=copy_count+1;copied=link;return true end}
local now,current_result=100,{status='OK',members={steam}}
local reader={menu_state=function() return state end,now=function() return now end,snapshot=function() return current_result end}
local panel=Panel.new(engine,desktop)
assert(panel.update(reader,runtime)=='visible')
assert(panel.visible and #panel.regions==1)
local initial_created=created
for i=1,120 do panel.update(reader,runtime) end
assert(created==initial_created,'retained GUI must not rebuild every frame')
local r=panel.regions[1]
input={x=r.x+r.w/2,y=r.y+r.h/2,down=true}
panel.update(reader,runtime);assert(copy_count==1 and copied==steam.profile_url)
for i=1,20 do panel.update(reader,runtime) end
assert(copy_count==1,'held mouse must not repeatedly copy')
local found=false;for _,text in ipairs(texts) do if text.value=='已复制 Steam 链接' then found=true end end
assert(found,'copy success visible')
input.down=false;panel.update(reader,runtime)
current_result=nil;input.down=true;panel.update(reader,runtime)
assert(copy_count==1,'stale former squad member must not be copied')
state=nil;panel.update(reader,runtime);assert(not panel.visible and #panel.regions==0)
state={screen=11,font='f',material='m',atlas='a'}
current_result={status='OK',members={steam}}
panel.update(reader,runtime);assert(copy_count==1,'opening with held mouse does not copy')
input.down=false;panel.update(reader,runtime)
r=panel.regions[1];input={x=r.x+r.w/2,y=r.y+r.h/2,down=true};panel.update(reader,runtime);assert(copy_count==2)
input=nil;panel.update(reader,runtime)
input={x=r.x+r.w/2,y=r.y+r.h/2,down=true};panel.update(reader,runtime)
assert(copy_count==2,'regaining focus with held mouse does not copy')
local function check_bounds(w,h)
    width,height=w,h;input={x=0,y=0,down=false};panel.update(reader,runtime)
    local b=Panel.layout(w,h,#runtime.members)
    for _,r in ipairs(panel.regions) do
        assert(r.x>=b.x and r.y>=b.top-b.h and r.x+r.w<=b.x+b.w and r.y+r.h<=b.top)
    end
    for _,r in ipairs(rects) do
        assert(r.pos.x>=0 and r.pos.y>=0 and r.pos.x+r.extent.x<=w+0.01 and r.pos.y+r.extent.y<=h+0.01)
    end
    for _,t in ipairs(texts) do assert(t.pos.x>=0 and t.pos.x<w and t.pos.y>=0 and t.pos.y<h) end
end
for _,size in ipairs({{1920,1080},{2560,1080},{1136,798},{1280,720},{640,480}}) do check_bounds(unpack(size)) end
runtime.members[3].name=string.rep('很长的中文昵称',30);runtime.revision=2;check_bounds(1136,798)
local truncated=false;for _,t in ipairs(texts) do if t.value:find('…',1,true) then truncated=true end end
assert(truncated,'long UTF-8 names truncated without breaking code points')
runtime.members[3].name='baijing000';runtime.revision=3;panel.update(reader,runtime)
-- Save the actual draw commands for reproducible offline previews.
local function save_preview(path)
    local function quote(s) return '\"'..s:gsub('\\','\\\\'):gsub('\"','\\\"')..'\"' end
    local output={string.format('{"width":%d,"height":%d,"texts":[',width,height)}
    for i,t in ipairs(texts) do
        if i>1 then output[#output+1]=',' end
        output[#output+1]=string.format('{"value":%s,"size":%.3f,"x":%.3f,"y":%.3f,"color":[%s]}',
            quote(t.value),t.size,t.pos.x,t.pos.y,table.concat(t.color,','))
    end
    output[#output+1]='],"rects":['
    for i,r in ipairs(rects) do
        if i>1 then output[#output+1]=',' end
        output[#output+1]=string.format('{"x":%.3f,"y":%.3f,"w":%.3f,"h":%.3f,"color":[%s]}',
            r.pos.x,r.pos.y,r.extent.x,r.extent.y,table.concat(r.color,','))
    end
    output[#output+1]=']}'
    local file=assert(io.open(path,'wb'));file:write(table.concat(output));file:close()
end
now=110;check_bounds(1920,1080)
local full=Panel.layout(1920,1080,3)
assert(full.x>=480+20 and full.x+full.w<=1450-60,'dock must leave native squad and orders unobscured')
assert(1080-full.top==190,'align with squad heading')
save_preview('build/panel-preview.json')
runtime.members={};runtime.revision=4;panel.update(reader,runtime);assert(#panel.regions==0)
local empty=Panel.layout(1920,1080,0)
assert(rects[1].extent.y==empty.h and empty.h<full.h/3,'empty room must collapse panel height')
save_preview('build/panel-empty-preview.json')
local prior_destroyed=destroyed;active_worlds={main};assert(panel.update(reader,runtime)=='UI world unavailable')
assert(not panel.visible and destroyed==prior_destroyed,'never destroy a GUI in a dead world')
print('PASS panel: Esc visibility, retained rendering, layout and UTF-8 names, URL hit boxes, one-click copy, focus/release gates, fresh membership check')
