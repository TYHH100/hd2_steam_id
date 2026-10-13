-- Focus-gated pointer sampling and explicit Steam-link clipboard writes only.
local M={}
function M.new()
    local ffi=require('ffi')
    if not pcall(ffi.typeof,'hd2sid2_Point') then
        ffi.cdef [[
            typedef struct { int32_t x; int32_t y; } hd2sid2_Point;
            typedef struct { int32_t left; int32_t top; int32_t right; int32_t bottom; } hd2sid2_Rect;
            void *hd2sid2_GetForegroundWindow(void) __asm__("GetForegroundWindow");
            uint32_t hd2sid2_GetWindowThreadProcessId(void *,uint32_t *) __asm__("GetWindowThreadProcessId");
            uint32_t hd2sid2_GetCurrentProcessId(void) __asm__("GetCurrentProcessId");
            int hd2sid2_GetCursorPos(hd2sid2_Point *) __asm__("GetCursorPos");
            int hd2sid2_ScreenToClient(void *,hd2sid2_Point *) __asm__("ScreenToClient");
            int hd2sid2_GetClientRect(void *,hd2sid2_Rect *) __asm__("GetClientRect");
            int16_t hd2sid2_GetAsyncKeyState(int) __asm__("GetAsyncKeyState");
            int hd2sid2_OpenClipboard(void *) __asm__("OpenClipboard");
            int hd2sid2_EmptyClipboard(void) __asm__("EmptyClipboard");
            void *hd2sid2_SetClipboardData(uint32_t,void *) __asm__("SetClipboardData");
            int hd2sid2_CloseClipboard(void) __asm__("CloseClipboard");
            void *hd2sid2_GlobalAlloc(uint32_t,size_t) __asm__("GlobalAlloc");
            void *hd2sid2_GlobalLock(void *) __asm__("GlobalLock");
            int hd2sid2_GlobalUnlock(void *) __asm__("GlobalUnlock");
            void *hd2sid2_GlobalFree(void *) __asm__("GlobalFree");
        ]]
    end
    local U,K=ffi.load('user32'),ffi.load('kernel32')
    local point,rect,pid=ffi.new('hd2sid2_Point[1]'),ffi.new('hd2sid2_Rect[1]'),ffi.new('uint32_t[1]')
    local own_pid=K.hd2sid2_GetCurrentProcessId()
    local function window()
        local hwnd=U.hd2sid2_GetForegroundWindow()
        if hwnd==nil then return nil end
        pid[0]=0
        if U.hd2sid2_GetWindowThreadProcessId(hwnd,pid)==0 or pid[0]~=own_pid then return nil end
        return hwnd
    end
    local function sample(width,height)
        local hwnd=window()
        if not hwnd or U.hd2sid2_GetCursorPos(point)==0 or U.hd2sid2_ScreenToClient(hwnd,point)==0 or
           U.hd2sid2_GetClientRect(hwnd,rect)==0 then return nil end
        local w,h=rect[0].right-rect[0].left,rect[0].bottom-rect[0].top
        local x,y=point[0].x-rect[0].left,point[0].y-rect[0].top
        if w<=0 or h<=0 or x<0 or y<0 or x>=w or y>=h then return nil end
        return {x=x*width/w,y=(h-y)*height/h,down=U.hd2sid2_GetAsyncKeyState(1)<0}
    end
    local function copy_link(text)
        if type(text)~='string' or not text:match('^https://steamcommunity%.com/profiles/%d+$') or #text>128 then
            return false,'invalid Steam profile link'
        end
        local hwnd=window()
        if not hwnd then return false,'game is not foreground' end
        local memory=K.hd2sid2_GlobalAlloc(2,(#text+1)*2)
        if memory==nil then return false,'clipboard allocation failed' end
        local address=K.hd2sid2_GlobalLock(memory)
        if address==nil then K.hd2sid2_GlobalFree(memory);return false,'clipboard lock failed' end
        local chars=ffi.cast('uint16_t *',address)
        for i=1,#text do chars[i-1]=text:byte(i) end
        chars[#text]=0
        K.hd2sid2_GlobalUnlock(memory)
        if U.hd2sid2_OpenClipboard(hwnd)==0 then
            K.hd2sid2_GlobalFree(memory);return false,'clipboard busy'
        end
        local transferred=false
        if U.hd2sid2_EmptyClipboard()~=0 then
            transferred=U.hd2sid2_SetClipboardData(13,memory)~=nil -- CF_UNICODETEXT
        end
        U.hd2sid2_CloseClipboard()
        -- Windows owns the HGLOBAL after SetClipboardData succeeds.
        if not transferred then K.hd2sid2_GlobalFree(memory) end
        if transferred then return true end
        return false,'clipboard write failed'
    end
    return {sample=sample,copy_link=copy_link}
end
return M
