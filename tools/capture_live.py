"""Read-only live verification using the actual Lua reader and remote RPM.

The game is never injected or called. Steam getters are replaced by the local
Steam client's ActiveUser; persona-name lookup is disabled in this verifier.
"""
import argparse
import ctypes as c
from ctypes import wintypes as w
import datetime as dt
import json
from pathlib import Path
import winreg
from build import ROOT, bundle, verify_inputs
from lua_vm import LuaVM


class ModuleEntry(c.Structure):
    _fields_ = [('dwSize',w.DWORD),('th32ModuleID',w.DWORD),('th32ProcessID',w.DWORD),
                ('GlblcntUsage',w.DWORD),('ProccntUsage',w.DWORD),('modBaseAddr',c.c_void_p),
                ('modBaseSize',w.DWORD),('hModule',w.HMODULE),('szModule',w.WCHAR*256),('szExePath',w.WCHAR*260)]


def lua_quote(value):
    return '"'+''.join('\\'+str(b) for b in str(value).encode('utf-8'))+'"'


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pid',type=int,required=True)
    parser.add_argument('--output',type=Path,default=ROOT/'reports/live-current.json')
    args=parser.parse_args()
    K=c.WinDLL('kernel32',use_last_error=True)
    for name,types,result in [
        ('CreateToolhelp32Snapshot',[w.DWORD,w.DWORD],w.HANDLE),
        ('Module32FirstW',[w.HANDLE,c.POINTER(ModuleEntry)],w.BOOL),
        ('Module32NextW',[w.HANDLE,c.POINTER(ModuleEntry)],w.BOOL),
        ('OpenProcess',[w.DWORD,w.BOOL,w.DWORD],w.HANDLE),
        ('CloseHandle',[w.HANDLE],w.BOOL)]:
        getattr(K,name).argtypes=types;getattr(K,name).restype=result
    handle=K.CreateToolhelp32Snapshot(0x18,args.pid)
    if handle==c.c_void_p(-1).value: raise c.WinError(c.get_last_error())
    modules={}
    try:
        row=ModuleEntry();row.dwSize=c.sizeof(row)
        ok=K.Module32FirstW(handle,c.byref(row))
        if not ok: raise c.WinError(c.get_last_error())
        while ok:
            modules[row.szModule.lower()]={'base':row.modBaseAddr,'path':row.szExePath}
            ok=K.Module32NextW(handle,c.byref(row))
    finally:K.CloseHandle(handle)
    game=Path(modules['helldivers2.exe']['path']).parents[1]
    spec=json.loads((ROOT/'config/build-25480438.json').read_text())
    hashes=verify_inputs(game,spec)
    with winreg.OpenKey(winreg.HKEY_CURRENT_USER,r'Software\Valve\Steam\ActiveProcess') as key:
        account=winreg.QueryValueEx(key,'ActiveUser')[0]
    if not account: raise ValueError('Local Steam ActiveUser unavailable')
    remote=K.OpenProcess(0x410,False,args.pid)
    if not remote: raise c.WinError(c.get_last_error())
    args.output.parent.mkdir(parents=True,exist_ok=True)
    # A proxy swaps only the source process handle and module/export lookup.
    # All bytes are parsed by the actual src/native.lua running in the game VM.
    source=bundle(spec).decode('utf-8')
    source=source[:source.index("if rawget(_G,'HD2RoomSteamInfo')")]
    module_table=','.join('['+lua_quote(name)+']='+str(modules[name]['base'])
                          for name in ('game.dll','helldivers2.exe','steam_api64.dll'))
    bootstrap='''
local real_ffi=require('ffi')
local real_require=require
local modules={MODULE_TABLE}
local exports={
  SteamAPI_SteamUser_v021=function() return real_ffi.cast('void *',1) end,
  SteamAPI_ISteamUser_GetSteamID=function() return real_ffi.cast('uint64_t',0x01100001)*4294967296ULL+ACCOUNT end
}
local kernel
local proxy=setmetatable({load=function(name)
  local real=real_ffi.load(name)
  if name~='kernel32' then return real end
  kernel=setmetatable({
    hd2sid1_GetCurrentProcess=function() return real_ffi.cast('void *',PROCESS) end,
    hd2sid1_GetModuleHandleA=function(name) return modules[name] and real_ffi.cast('void *',modules[name]) end,
    hd2sid1_GetProcAddress=function(_,name) return exports[name] end
  },{__index=real})
  return kernel
end,cast=function(signature,value)
  if type(value)=='function' then return value end
  return real_ffi.cast(signature,value)
end},{__index=real_ffi})
require=function(name) if name=='ffi' then return proxy end return real_require(name) end
'''.replace('MODULE_TABLE',module_table).replace('ACCOUNT',str(account)).replace('PROCESS',str(remote))
    suffix='''
local reader,why=Native.new(Spec,Identity)
assert(reader,why)
local result,reason=reader.snapshot()
result=result or {status='UNKNOWN',reason=reason,members={}}
local file=assert(io.open(OUTPUT,'wb'))
assert(file:write(Identity.json(result,os.date('%Y-%m-%d %H:%M:%S'))))
assert(file:close())
local text=assert(io.open(TEXT_OUTPUT,'wb'))
assert(text:write(Identity.text(result,os.date('%Y-%m-%d %H:%M:%S'))))
assert(text:close())
local menu,menu_reason=reader.menu_state()
local ui={status=menu and 'ready' or tostring(menu_reason)}
if menu then ui.screen=menu.screen;ui.font=menu.font;ui.atlas=menu.atlas;ui.material=menu.material end
-- All values below are reader-owned fixed reasons, hex hashes or addresses.
local function ui_quote(value) return '"'..tostring(value)..'"' end
local ui_file=assert(io.open(UI_OUTPUT,'wb'))
assert(ui_file:write('{"status":'..ui_quote(ui.status)))
for _,key in ipairs({'screen','font','atlas','material'}) do
    if ui[key] then assert(ui_file:write(','..ui_quote(key)..':'..ui_quote(ui[key]))) end
end
assert(ui_file:write('}'))
assert(ui_file:close())
'''.replace('UI_OUTPUT',lua_quote(args.output.with_suffix('.ui.json').resolve())).replace('TEXT_OUTPUT',lua_quote(args.output.with_suffix('.txt').resolve())).replace('OUTPUT',lua_quote(args.output.resolve()))
    vm=LuaVM(game/'bin/lua51.dll')
    try:
        vm.run((bootstrap+source+suffix).encode('utf-8'),'@read_only_live_verifier')
        ui=json.loads(args.output.with_suffix('.ui.json').read_text(encoding='utf-8'))
        # Bounded diagnostic reads explain a failed UI proof or visibility gate.
        rpm=K.ReadProcessMemory
        rpm.argtypes=[w.HANDLE,c.c_void_p,c.c_void_p,c.c_size_t,c.POINTER(c.c_size_t)]
        rpm.restype=w.BOOL
        def read_ui(address,size):
            if not address or not 65536 <= address < (1 << 47) or not 1 <= size <= 128:
                return None
            buffer=c.create_string_buffer(size)
            count=c.c_size_t()
            if not rpm(remote,address,buffer,size,c.byref(count)) or count.value != size:
                return None
            return buffer.raw
        def pointer_ui(address):
            value=read_ui(address,8)
            return int.from_bytes(value,'little') if value else None
        base=modules['game.dll']['base']
        ui['proofs']=[]
        for proof in spec['ui']['proofs']:
            actual=read_ui(base+proof['rva'],len(bytes.fromhex(proof['hex'])))
            ui['proofs'].append({'rva':hex(proof['rva']),'expected':proof['hex'],
                                 'actual':actual.hex() if actual else None,
                                 'match':actual==bytes.fromhex(proof['hex'])})
        menu=pointer_ui(base+spec['ui']['menu'])
        screen=pointer_ui(menu+200) if menu else None
        ui['menu_pointer']=menu;ui['screen_pointer']=screen
        ui['resources']={}
        for key in ('font','atlas','material'):
            raw=read_ui(base+spec['ui'][key],8)
            ptr=int.from_bytes(raw,'little') if raw else None
            ui['resources'][key]={'global':hex(spec['ui'][key]),'raw':raw.hex() if raw else None,
                                 'pointer':ptr,'head':(read_ui(ptr,64) or b'').hex(),
                                 'plus24':(read_ui(ptr+24,8) or b'').hex() if ptr else None}
        if screen:
            ui['shown_bytes']=(read_ui(screen+8,4) or b'').hex()
            ui['hidden_bytes']=(read_ui(screen+281480+1989808,1) or b'').hex()
            ui['dialog_bytes']=(read_ui(screen+281480+1989648,2) or b'').hex()
        args.output.with_suffix('.ui.json').write_text(json.dumps(ui,indent=2)+'\n',encoding='utf-8')

    finally:
        vm.close();K.CloseHandle(remote)
    result=json.loads(args.output.read_text(encoding='utf-8'))
    result.update(pid=args.pid,captured_at=dt.datetime.now(dt.timezone(dt.timedelta(hours=8))).isoformat(),
                  method='Actual Lua memory reader; remote ReadProcessMemory; local identity from Steam ActiveUser; no game calls',
                  input_hashes=hashes,in_game_mod_loaded=False)
    args.output.write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print(args.output)
    print('Status:',result['status'],'Remote members:',len(result['members']))
    if result.get('reason'):print('Reason:',result['reason'])
    print('Esc menu:',ui['status'])


if __name__=='__main__':main()
