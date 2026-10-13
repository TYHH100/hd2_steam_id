"""Run offline checks in the installed game's Lua VM without copying its DLL."""
import ctypes as c
from pathlib import Path


class LuaVM:
    def __init__(self, dll: Path):
        self.api = a = c.CDLL(str(dll.resolve()))
        a.luaL_newstate.restype = c.c_void_p
        a.luaL_openlibs.argtypes = [c.c_void_p]
        a.lua_close.argtypes = [c.c_void_p]
        a.luaL_loadbuffer.argtypes = [c.c_void_p, c.c_char_p, c.c_size_t, c.c_char_p]
        a.lua_pcall.argtypes = [c.c_void_p, c.c_int, c.c_int, c.c_int]
        a.lua_tolstring.argtypes = [c.c_void_p, c.c_int, c.POINTER(c.c_size_t)]
        a.lua_tolstring.restype = c.c_void_p
        a.lua_settop.argtypes = [c.c_void_p, c.c_int]
        self.state = a.luaL_newstate()
        if not self.state:
            raise RuntimeError('luaL_newstate failed')
        a.luaL_openlibs(self.state)

    def close(self):
        if self.state:
            self.api.lua_close(self.state)
            self.state = None

    def check(self, status):
        if status:
            length = c.c_size_t()
            value = self.api.lua_tolstring(self.state, -1, c.byref(length))
            message = c.string_at(value, length.value).decode('utf-8', 'replace') if value else 'Lua error'
            self.api.lua_settop(self.state, 0)
            raise RuntimeError(message)

    def load(self, source: bytes, name: str):
        self.check(self.api.luaL_loadbuffer(self.state, source, len(source), name.encode()))

    def run(self, source: bytes, name='@test'):
        self.load(source, name)
        self.check(self.api.lua_pcall(self.state, 0, 0, 0))
        self.api.lua_settop(self.state, 0)
