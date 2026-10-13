# HD2 Lua 模组 UI 快速参考

适用：游戏内 LuaJIT + Stingray GUI，通过 BSL API 1 兼容入口加载的自建信息面板。整理日期：2026-10-13，参考项目版本：0.2.2，游戏 Steam build：25480438。

0.2.1的用户实机截图已确认 GUI 能显示；0.2.2的紧凑布局通过离线回归与预览，尚待实机确认。本文的资源参数、内存偏移是此游戏版本的观察结果，不是跨版本通用常量。

## 从哪里开始

| 要复用的部分 | 本项目源码 | 作用 |
| --- | --- | --- |
| 面板、文字、布局、点击区域 | [src/panel.lua](../src/panel.lua) | `Panel.layout()`、`Panel.new()`、`update()`、`clear()` |
| 前台窗口、鼠标、复制 | [src/desktop.lua](../src/desktop.lua) | `Desktop.new()`、`sample()`、`copy_link()` |
| 实际菜单状态、字体资源 | [src/native.lua](../src/native.lua) | `Native.new()`、`reader.menu_state()` |
| update 共存、日志、故障隔离 | [src/main.lua](../src/main.lua) | 保留原回调返回值，UI 出错不影响读取 |
| 注入模块与打包 | [tools/build.py](../tools/build.py) | 多个源码合为一个声明式 Lua 资源 |
| 布局/点击回归与绘制指令 | [tests/test_panel.lua](../tests/test_panel.lua) | 模拟 GUI，导出预览 JSON |
| 只读实机诊断 | [tools/capture_live.py](../tools/capture_live.py) | 菜单状态、代码证明、资源检查 |

先复制绘制与布局部分，再接新功能的数据源。新模组要更换资源名、GUID、全局运行状态名和私有 FFI 前缀；不要原样保留 Steam 查询与剪贴板代码，除非新需求确实需要。

## 最小接入流程

1. 从 `_G.stingray` 取得 `Application`、`World`、`Gui`、`Material`、`IdString64` 与向量/颜色构造器。
2. 读取目标菜单的真实可见状态，以及当前有效的 font、atlas、material 资源 hash。
3. 按本项目做法，在 `Application.worlds()` 中选择非 `Application.main_world()` 的 UI world；不存在时等待，不能凭空造 world 指针。
4. 使用 `World.create_screen_gui(world, 'scale', 1, 1)` 创建自己的 retained GUI。
5. 配置字体材质，调用 `Gui.rect()`、`Gui.text()` 绘制。
6. 每帧检查菜单/世界/输入，内容或尺寸变化时重新绘制；隐藏时销毁自己的 GUI。

下面是可直接参考的绘制片段。`engine` 为实际引擎表，`world` 为上述有效 world，`state` 来自通过版本检查的资源读取器；片段不负责生命周期。

```lua
local A, W, G = engine.Application, engine.World, engine.Gui
local id = engine.IdString64.from_hex
local gui = assert(W.create_screen_gui(world, 'scale', 1, 1))
local font, material = id(state.font), id(state.material)
local ink = assert(G.material(gui, material))
local function parameter(hash) return id(hash .. '00000000') end

-- 本游戏字体材质参数；更换材质时需要重新确认。
for _, hash in ipairs({'8035c266','5e8455fe','309e7783','82b803a8'}) do
    engine.Material.set_scalar(ink, parameter(hash), 0)
end
engine.Material.set_vector2(ink, parameter('e13777ce'), engine.Vector2(1,-1))
engine.Material.set_vector4(ink, parameter('7701209e'), engine.Color(0,0,0,0))
engine.Material.set_texture(ink, parameter('88bac99b'), id(state.atlas))

G.rect(gui, engine.Vector3(510,758,970), engine.Vector2(820,132),
       engine.Color(210,8,9,8))
G.text(gui, '小队平台信息', font, 24, material,
       engine.Vector3(530,856,973), engine.Color(255,255,221,72))
-- 隐藏时：先确认 world 仍在 Application.worlds() 中，再 W.destroy_gui(world, gui)。
```

颜色构造参数顺序是 **alpha, red, green, blue**。矩形位置是左下角；屏幕 GUI 的坐标原点在屏幕左下。以上 z=970/973 是本项目选择的绘制层，不能当作不同 GUI 之间必定压过原生菜单的保证。

## 字体资源：两个已实机踩过的坑

- font/atlas globals 保存的是8字节资源 hash，不能把它们当指针。material global 保存的是引擎 handle，+24 才是资源 hash。
- 小端内存 hash 需倒序为整数十六进制字符串，再传给 `IdString64.from_hex`：

```lua
local parts = {}
for i = 8, 1, -1 do
    parts[#parts+1] = string.format('%02x', bytes:byte(i))
end
local hex = table.concat(parts)
```

- material handle 实机可能只按 **4 字节对齐**，不能统一套用会话指针的8字节对齐要求。0.2.0因此将有效 handle 判为无效，出现“已加载但不显示”。0.2.1只放宽材质 handle 对齐检查，其他结构保留自己的校验。
- 不用 `ffi.cast` 伪造引擎 Lua API 的 Material handle；绘制时的句柄由 `Gui.material(gui, material_hash)` 返回。
- 使用 `ReadProcessMemory` 复制资源字节并检查读取是否成功。`pcall` 不能保护直接原生解引用造成的访问冲突。

当前资源位置与代码证据见 [evidence.md](evidence.md) 的“Esc 面板布局”；新游戏版本必须重新验证。

## 布局与鼠标必须用同一坐标系

本项目以1920×1080为设计基准，按短边等比缩放，横向居中：

```lua
local s = math.min(width/1920, height/1080)
local offset_x = (width-1920*s)/2
local panel_x = offset_x + 510*s
local panel_top = height - 190*s
-- rx,ry 是面板内的左上式坐标；rw,rh 是基准尺寸。
local rect_x = panel_x + rx*s
local rect_y = panel_top - (ry+rh)*s
local text_baseline_y = panel_top - ry*s
```

在1920基准下，小队面板右边约x=480，重要指令左边约x=1450。0.2.2把信息面板放在x=510至1330，空房间高132，有成员时高112+144×人数（最多3人）。先用完整实机截图确认周围原生 UI，再选择空白区；局部截图的框选不能直接当作全屏比例。

鼠标路径：`GetCursorPos → ScreenToClient → 客户区大小 → Gui.resolution()`。客户端坐标左上为原点，换为 GUI 坐标：`x_gui=x*width/client_width`，`y_gui=(client_height-y)*height/client_height`。先确认前台窗口属于当前游戏，鼠标位于客户区内。

使用 `Gui.text_extents(gui, text, font, scaled_size)` 获取文字的最小/最大向量。同一测量结果同时用于宽度裁剪、下划线和命中区域。长中文昵称按 UTF-8 字符截断；URL可缩小字号，不能只改显示而保留旧点击区域。

## 显示条件与生命周期

Esc 不用按键翻转布尔值猜开关；读取实际 screen、页号、hidden、dialog 状态。当前 GAME 页为0；其他页、关闭菜单或确认框出现时清理自建 GUI。具体版本偏移保存在 `config/build-25480438.json`，不要散落到绘制层。

retained GUI 会保留图形，无需每帧重复创建。签名包含菜单实例、资源 hash、分辨率、数据 revision、hover 和反馈；签名相同且 world 仍有效时复用。签名变化只销毁自己的 GUI，再重建。world 已销毁时忘记旧引用，不再调用其 `destroy_gui`。

本项目每帧先更新布局再做命中检测，避免分辨率或成员变动后使用旧区域；再按新 hover/反馈更新一次。不要在同一帧让两次绘制使用互相冲突的 hover 状态，造成每帧重复重建。

## 点击与复制

鼠标按下上升沿才触发一次动作。进入菜单或失焦后恢复时先等释放；按住不重复触发。不消耗原游戏输入，因此交互区域应避开原生按钮。

点击 Steam 链接前再次读取当前成员，确认完整 URL 仍属于本房间；成员已变化则请求刷新。其他带数据的 UI 可复用这一思路：动作发生时重新确认对象有效性，不能只信轮询缓存。

剪贴板流程是 `GlobalAlloc(GMEM_MOVEABLE) → GlobalLock → 写UTF-16和终止符 → GlobalUnlock → OpenClipboard → EmptyClipboard → SetClipboardData(CF_UNICODETEXT) → CloseClipboard`。成功交付后由 Windows 持有 HGLOBAL，失败释放。当前函数仅处理经过严格限制的 ASCII Steam URL；复制任意中文文本时需另做真正的 UTF-8→UTF-16 转换。

所有 FFI 类型/函数用带版本的私有前缀，并通过 `__asm__` 绑定实际 Windows 符号；共享 VM 中不要声明通用 `POINT` 等类型。复制只由明确点击触发，成功/失败反馈保留两秒。

## update 共存与诊断

保存原 update 并调用，不覆盖其他模组的逻辑。保存可变参数数量和返回值数量，含中间/末尾 nil；原回调异常继续抛出。当前项目先执行数据轮询，调用原 update 后再更新 GUI；UI 用独立 `pcall`，失败清理并禁用面板，数据导出继续。

记录**状态变化**，避免逐帧写日志：“closed / other tab / menu hidden or dialog open / menu font unavailable / UI world unavailable / visible”。代码证明失败记录 RVA；绘制异常记录原 Lua 错误。只有成功创建并绘制才标记 visible。“加载器里显示已加载”只证明入口执行，不能证明 UI 已出现。

未显示时按顺序排查：入口日志 → update 是否运行 → 引擎是否存在 → 菜单状态/版本证明 → 字体资源与对齐 → UI world → GUI 创建/材质错误 → 坐标和覆盖层。不要先猜是其他模组冲突。

## 最小验证与交付

- 先在游戏 `lua51.dll` 中跑离线测试：菜单隐藏/显示、世界失效、返回值共存、长中文、不同分辨率、点击区域、释放门槛、一次复制。
- 从真实模拟绘制指令导出 JSON，在完整截图上合成布局预览。替代字体只用于位置检查，图片标“离线示意”，不能称游戏实拍。
- 独自在舰桥即可检查空状态；不要求为了验证 UI 长期挂机其他人的房间。
- 实机确认文字/层级/关闭/切页后，再检查有数据时的布局和点击。构建成功不等于实机验收完成。
- 打包由管理器分配 `.patch_<number>`；替换版本后重新部署，不手动覆盖其他补丁。临时复制/研究文件用完删除。

本项目构建命令（只构建，不部署、不启动游戏）：

```powershell
& 'G:\App\Python\3.11.6\python.exe' -B tools/build.py --game 'G:\AppData\SteamLibrary\steamapps\common\Helldivers 2'
```

## 外部参考

- [Stingray Gui 官方接口](https://help.autodesk.com/cloudhelp/ENU/Stingray-Help/lua_ref/obj_stingray_Gui.html)：屏幕坐标、retained GUI、rect/text/text_extents、绘制层。
- [BSL 作者规范](https://github.com/CowboyBingus/BingusSharedLoader/blob/main/docs/AUTHORING.md)：声明式入口、资源打包、共享 VM 与私有 FFI。
- [Better Lobby Management 菜单实现](https://github.com/CowboyBingus/BetterLobbyManagement/blob/main/src/menu.lua)：实际 Esc/GAME/dialog 状态参考；本项目只使用读取部分。
- [Windows 剪贴板操作](https://learn.microsoft.com/en-us/windows/win32/dataxchg/clipboard-operations)：打开/关闭、GMEM_MOVEABLE 与内存所有权。
- [Windows ReadProcessMemory](https://learn.microsoft.com/en-us/windows/win32/api/memoryapi/nf-memoryapi-readprocessmemory)：复制进程字节及失败处理。
