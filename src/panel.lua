-- Retained engine GUI beside the Esc GAME-tab squad list. No input consumption.
local M={}
function M.layout(width,height,count)
    local scale=math.min(width/1920,height/1080)
    local rows=math.min(3,math.max(0,count or 3))
    local panel_height=rows==0 and 132 or 112+rows*144
    -- Dock between the native squad (ends x=480) and orders (starts x=1450).
    return {scale=scale,x=(width-1920*scale)/2+510*scale,top=height-190*scale,w=820*scale,h=panel_height*scale}
end
function M.contains(r,x,y)
    return r and x>=r.x and x<r.x+r.w and y>=r.y and y<r.y+r.h
end
function M.new(engine,desktop)
    local A,W,G=engine.Application,engine.World,engine.Gui
    assert(A and W and G and engine.Material and engine.IdString64,'Stingray GUI unavailable')
    local self={regions={},visible=false,armed=false,last_down=false}
    local function alive(world)
        if not world then return false end
        for _,value in ipairs(A.worlds() or {}) do if value==world then return true end end
        return false
    end
    function self.clear()
        if self.gui and alive(self.world) then W.destroy_gui(self.world,self.gui) end
        self.gui,self.world,self.signature=nil,nil,nil
        self.regions={};self.visible=false;self.armed=false;self.last_down=false
        self.hover,self.feedback,self.feedback_until=nil,nil,nil
    end
    local function clean(value) return tostring(value or 'UNKNOWN'):gsub('[%z\1-\31]',' ') end
    local function color(r,g,b,a) return engine.Color(a or 255,r,g,b) end
    local white,muted,gold,link=color(245,245,240),color(175,175,175),color(255,221,72),color(117,205,255)
    local function draw(state,runtime,width,height,hover,feedback)
        local world
        for _,candidate in ipairs(A.worlds() or {}) do
            if candidate~=A.main_world() then world=candidate;break end
        end
        if not world then self.clear();return end
        local parts={width,height,state.screen,state.font,state.atlas,state.material,runtime.status or '',
                     runtime.revision or 0,hover or '',feedback or ''}
        for _,row in ipairs(runtime.members) do
            parts[#parts+1]=clean(row.name);parts[#parts+1]=row.steam_id64 or '';parts[#parts+1]=row.platform_name or ''
        end
        local signature=table.concat(parts,'|')
        if signature==self.signature and self.world==world and alive(world) then return end
        -- Preserve input edge state while recreating only the owned GUI.
        if self.gui and alive(self.world) then W.destroy_gui(self.world,self.gui) end
        self.gui=nil;self.regions={};self.world=world
        local gui=assert(W.create_screen_gui(world,'scale',1,1),'screen GUI unavailable')
        self.gui=gui
        local id=engine.IdString64.from_hex
        local font,material=id(state.font),id(state.material)
        local ink=assert(G.material(gui,material),'font material unavailable')
        local function param(hash) return id(hash..'00000000') end
        for _,hash in ipairs({'8035c266','5e8455fe','309e7783','82b803a8'}) do
            engine.Material.set_scalar(ink,param(hash),0)
        end
        engine.Material.set_vector2(ink,param('e13777ce'),engine.Vector2(1,-1))
        engine.Material.set_vector4(ink,param('7701209e'),engine.Color(0,0,0,0))
        engine.Material.set_texture(ink,param('88bac99b'),id(state.atlas))
        local rows=runtime.status=='OK' and #runtime.members or 0
        local box=M.layout(width,height,rows);local s,x,top=box.scale,box.x,box.top
        local panel_height=box.h/s
        local function rect(rx,ry,rw,rh,c)
            G.rect(gui,engine.Vector3(x+rx*s,top-(ry+rh)*s,970),engine.Vector2(rw*s,rh*s),c)
        end
        local function measure(text,size)
            if type(G.text_extents)=='function' then
                local a,b=G.text_extents(gui,text,font,size*s)
                if a and b then return b.x-a.x,a,b end
            end
            return #text*size*s*0.6,{x=0,y=-size*s*0.2},{x=#text*size*s*0.6,y=size*s}
        end
        local function fit(text,size,max_width)
            text=clean(text)
            if measure(text,size)<=max_width*s then return text end
            local ends={}
            for at in text:gmatch('()[%z\1-\127\194-\244][\128-\191]*') do ends[#ends+1]=at end
            for i=#ends-1,1,-1 do
                local candidate=text:sub(1,ends[i+1]-1)..'…'
                if measure(candidate,size)<=max_width*s then return candidate end
            end
            return '…'
        end
        local function text(value,rx,ry,size,c)
            G.text(gui,value,font,size*s,material,engine.Vector3(x+rx*s,top-ry*s,973),c or white)
        end
        rect(0,0,820,panel_height,color(8,9,8,210))
        rect(0,0,3,panel_height,gold)
        text('小队平台信息',20,34,24,gold)
        text('已排除自己',650,33,17,muted)
        rect(20,48,780,1,color(110,110,102,150))
        if runtime.status~='OK' then
            text('正在读取当前房间成员…',20,88,20,muted)
        elseif #runtime.members==0 then
            text('当前房间没有其他成员',20,88,20,muted)
        end
        for i,row in ipairs(runtime.members) do
            local y=86+(i-1)*144
            local label=row.status=='STEAM' and 'Steam' or row.platform_name or '平台未知'
            text(fit(row.name,22,600),20,y,22,white)
            text(label,650,y,18,row.status=='STEAM' and link or muted)
            if row.status=='STEAM' then
                text('SteamID64  '..row.steam_id64,20,y+29,18,muted)
                if row.steam_name and row.steam_name~='UNKNOWN' and row.steam_name~=row.name then
                    text(fit('Steam 昵称  '..row.steam_name,17,780),20,y+55,17,muted)
                end
                if row.profile_url then
                    local size=18
                    while size>14 and measure(row.profile_url,size)>772*s do size=size-1 end
                    local y_link=y+82
                    local actual_width,low,high=measure(row.profile_url,size)
                    local shown_color=hover==row.profile_url and gold or link
                    text(row.profile_url,20,y_link,size,shown_color)
                    local baseline=top-y_link*s
                    local r={x=x+20*s+low.x-4*s,y=baseline+low.y-6*s,
                             w=math.min(actual_width+8*s,780*s),h=math.max(high.y-low.y+12*s,28*s),url=row.profile_url}
                    self.regions[#self.regions+1]=r
                    rect(20,y_link+5,actual_width/s,1,shown_color)
                end
            else
                text(row.platform_name=='主机平台' and '主机平台玩家 · 无 Steam 主页' or '暂未获取平台账号信息',20,y+32,18,muted)
            end
            if i<#runtime.members then rect(20,y+116,780,1,color(80,80,76,150)) end
        end
        if feedback or #self.regions>0 then
            text(feedback or '点击 Steam 主页链接即可复制',20,panel_height-20,17,feedback and gold or muted)
        end
        self.signature=signature;self.visible=true
    end
    function self.update(reader,runtime)
        local state,why=reader.menu_state()
        if not state then self.clear();return why end
        local width,height=G.resolution()
        if type(width)~='number' or type(height)~='number' or width<640 or height<480 then self.clear();return 'viewport unavailable' end
        local now=reader.now()
        local feedback=self.feedback_until and now<self.feedback_until and self.feedback or nil
        -- Reflow before hit testing if menu, resolution or members changed.
        draw(state,runtime,width,height,self.hover,feedback)
        local input=desktop.sample(width,height)
        local hover
        if input then
            for _,r in ipairs(self.regions) do if M.contains(r,input.x,input.y) then hover=r.url;break end end
            if not input.down then self.armed=true end
            if input.down and not self.last_down and self.armed and hover then
                -- A fresh room read at the action boundary prevents copying a
                -- stale former squad member from the two-second display cache.
                local result=reader.snapshot()
                local current=false
                if result and result.status=='OK' then
                    for _,row in ipairs(result.members) do if row.profile_url==hover then current=true;break end end
                end
                local ok=current and desktop.copy_link(hover)
                self.feedback=current and (ok and '已复制 Steam 链接' or '复制失败，请重试') or '成员已变化，正在刷新'
                self.feedback_until=now+2;feedback=self.feedback
                if not current and runtime.refresh then runtime.refresh() end
            end
            self.last_down=input.down
        else self.armed=false;self.last_down=false end
        self.hover=hover
        draw(state,runtime,width,height,hover,feedback)
        return self.visible and 'visible' or 'UI world unavailable'
    end
    return self
end
return M
