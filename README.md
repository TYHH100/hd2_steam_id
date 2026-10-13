# HD2 当前房间 Steam 信息 Lua 模组

读取当前房间除自己以外的成员，输出游戏昵称、Steam 昵称、SteamID64、Account ID 和 Steam 主页链接。采用当前游戏进程内的 LuaJIT 读取内存，并使用游戏已初始化的 Steam 接口确认自己、查询缓存昵称。无需 Web API Key，不发送额外网络请求。

当前版本 **0.2.2**，支持 Steam build **25480438**。已有离线回归、单人和三名队友房间的只读验证；加载、身份导出与0.2.1空房间面板绘制已有用户实机确认；0.2.2新布局、实际点击复制、多人进出房及任务场景仍需实测。

0.2.2调整布局：面板放在小队与重要指令之间，与“小队”标题顶边对齐；宽820像素，空房间高132像素，成员增多时自动增高，最多544像素（1920×1080基准）。空房间不再显示复制提示。

0.2.1修复字体材质指针的对齐判断：实机 handle 为4字节对齐，0.2.0误要求8字节对齐，导致菜单正常却返回 `menu font unavailable`、面板始终隐藏。另增加面板状态变化日志，明确记录隐藏、缺少引擎/世界、代码证明失败和绘制异常。

## 安装

1. 完全退出游戏。
2. 安装并启用 [Bingus Shared Loader v15+ / API 1](https://github.com/CowboyBingus/BingusSharedLoader/releases)。本机使用 v19。
3. 将 `dist/HD2-Room-Steam-Info-0.2.2.zip` 导入模组管理器，替换旧版、启用并重新部署，保留现有加载器。
4. 启动游戏、进入房间；约两秒后按 Esc，在“游戏”页“小队”右侧查看信息。自己无需成为房主，其他玩家无需安装这个模组。

不要手动覆盖其他模组的 `.patch_0`，由管理器分配补丁编号。卸载时在同一管理器停用并重新部署。

## Esc 面板与复制

右侧面板显示当前其他成员的游戏昵称、平台以及 SteamID64；可用时补充缓存 Steam 昵称。点击蓝色 Steam 主页链接即可复制完整链接，显示“已复制 Steam 链接”两秒。复制失败时显示重试提示；复制前重新核对当前房间成员。切页、关闭 Esc 菜单或弹出原游戏确认框时隐藏面板。

平台代码0按本机多人现场的用户确认显示“主机平台玩家 · 无 Steam 主页”，不猜测具体主机类型。该确认不代表存在可读取的关联 Steam 账号。读取结果文件继续保留。

## 输出文件

位于 `%LOCALAPPDATA%/CowboyBingus/Helldivers2/Logs/`：

- `HD2RoomSteamInfo.txt`：直接阅读昵称、SteamID64 和主页链接。
- `HD2RoomSteamInfo.json`：供其他工具读取，ID 使用字符串以避免精度损失。
- `HD2RoomSteamInfo.log`：启动、成员变更和读取失败原因。

每两秒检查，只有成员信息或状态变化才写文件；时间是**最后一次结果变更的时间**。文件在退出游戏后仍保留，不能作为游戏仍在运行的证明。重新启动模组立即清空旧结果；成员离房、读取失败或自己身份不匹配时清空当前成员。JSON 与 TXT 分别写入，外部工具遇到暂时空文件或 JSON 解析失败时应重试。

`STEAM` 表示平台映射与 SteamID 格式通过检查；`NO_STEAM_MAPPING` 表示当前平台记录没有提供 Steam 映射，平台代码0另按用户现场确认标记“主机平台”；`UNKNOWN` 表示当前无法确认。无 Steam 映射的成员不生成 Steam 主页。Steam 昵称来自现有 Steam 缓存，缺失时为 `UNKNOWN`，游戏昵称仍尽量保留。

调试时可通过全局 `HD2RoomSteamInfo.members` 查看当前结果，`HD2RoomSteamInfo.ui_status` 查看面板状态，调用 `HD2RoomSteamInfo.refresh()` 在下一帧刷新。UI 错误独立禁用面板，文件导出继续。

## 本地构建

类似 Lua 游戏内 UI 的制作与复用见 [docs/lua-ui-guide.md](docs/lua-ui-guide.md)，包含字体资源、坐标、生命周期、交互和实机踩坑。

Windows x64、Python 3.11+，不需要额外 Python 包。游戏 DLL 直接加载用于离线 Lua 校验，不复制到测试目录，也不要求游戏进程运行。

```powershell
& 'G:\App\Python\3.11.6\python.exe' -B tools/build.py --game 'G:\AppData\SteamLibrary\steamapps\common\Helldivers 2'
```

输出 ZIP 与 SHA-256 在 `dist/`，Lua 单文件及验证报告在 `build/`。版本或代码不匹配时构建拒绝。运行时检查 PE 时间戳、映像大小和关键机器码；不匹配则输出 UNKNOWN。

只读现场复核（游戏运行时）：

```powershell
& 'G:\App\Python\3.11.6\python.exe' -B tools/capture_live.py --pid (Get-Process helldivers2).Id
```

该工具使用 Steam 客户端的本地 ActiveUser 与游戏的平台映射核对自己；它是外部只读复核，不安装或执行模组。详细证据与外部来源见 [docs/evidence.md](docs/evidence.md)。
