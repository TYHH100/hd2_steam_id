# 身份读取证据与验收边界

## 当前布局

2026-10-13 对当前运行的游戏进行限定范围的 ReadProcessMemory 读取；不暂停线程、不调用游戏原生函数、不写入游戏进程。模块 SHA-256、PE 时间戳和关键机器码固定在 `config/build-25480438.json`。

游戏 DLL SHA-256：`2e2c3b7c2500646dadd5f2b4c6e0504dbb7e7896139f64cddc0d1813c718f51e`。

EXE SHA-256：`f5fee03dcfdb2e553a4752c283590950ac13316b376d8196aa556ff0400d5f06`。

| 位置 | 读取含义 | 证据 |
| --- | --- | --- |
| game.dll + `0x347CEF0` | network context 指针 | 上游布局，本机代码复核 |
| context + `0xB398` | local PlayFab peer ID | 本机成员与平台映射核对 |
| context + `0x16390` / `0x16398` | 当前 session 成员数与 32 字节记录 | game.dll `0x134FA90` 读取此列表 |
| game.dll + `0x347CED8` | 名册，8 个 0xC0 记录；peer +0、名字 +8 | 游戏原生 UI 在 `0x19A69DC` 起按 peer 查找，最大8条 |
| EXE + `0x235E3C8` → +`0x5D0` → +`0xA0` → +`0x60` | 平台用户缓存容器 | EXE `0x8C7DA0` 原生身份查询 |
| 容器 +`0xA0` / +`0xA8` | 用户数量 / 记录指针数组 | 同一原生查询的循环 |
| 用户记录 +`0x18` / +`0x20` / +`0x28` | PlayFab peer / 平台账号 / 平台代码 | 同一原生查询复制到输出结构 |

本机单人样本：local peer 出现在当前 session 中；平台记录代码为1，账号是格式正确的 SteamID64，低32位与 Steam 客户端 `HKCU/Software/Valve/Steam/ActiveProcess/ActiveUser` 一致。名册中存在已经离房者的名字和 Steam 账号，但它们的 peer 已清零，因此不能直接导出整个名册。平台缓存还包含大量好友和历史记录，模组只匹配当前最多4个 session peer。

模组内部进一步使用已加载 `steam_api64.dll` 的 `SteamAPI_SteamUser_v021` 与 `SteamAPI_ISteamUser_GetSteamID` 取得自己，要求与 local peer 的平台映射完全相同。没有初始化/关闭 Steam SDK，也没有运行其回调队列。

平台代码1与 Steam 身份的关联已在本机本地玩家上确认；已现场匹配一名 Steam 队友。用户确认同一现场的前两名（平台代码0）为主机玩家，0.2.0据此显示“主机平台”，继续使用 `NO_STEAM_MAPPING`，不猜测具体主机类型或账号。

## Esc 面板布局

菜单根指针位于 `game.dll + 0x347CE38`，其 +200 为 Esc screen。screen +8 的页号0为“游戏”；content = screen +281480，content +1989808 的 hidden 为0、+1989648 的 dialog inactive 非0、+1989649 的 opening 为0时绘制。运行时先校验独立菜单机器码证明，错误只禁用 UI。偏移与精确代码保存在 `config/build-25480438.json` 的 `ui` 节。

游戏字体、atlas、材质 globals 分别为 `0x3772268`、`0x3772EE8`、`0x37C5478`；材质指针 +24 提供资源 hash。引用代码在 RVA `0x1388030`、`0x1388044`、`0x1388054` 复核。内存小端8字节必须倒序为整数十六进制，再传入 `IdString64.from_hex`。

2026-10-13的0.2.0未显示现场：用户重新启动并留在单人舰桥，外部只读工具复用实际 Lua reader，读到 GAME 页号0、hidden=0、dialog inactive=1/opening=0；全部 UI 机器码证明通过，却返回 `menu font unavailable`。限定读取发现材质 handle 为 `0x2423F2410CC`，仅4字节对齐；+24 可读，hash 内存字节为 `4d31c046fd65ade1`，整数表示 `e1ad65fd46c0314d`。旧通用 pointer 函数拒绝非8字节对齐地址，是该隐藏故障的直接原因。0.2.1仅对材质 handle 允许4字节对齐；回归 fixture 使用只按4字节对齐的 handle，验证 hash 成功取得。会话与菜单指针检查继续保留。

0.2.2面板采用居中1920×1080坐标，x=510、顶部距190、宽820，与小队标题对齐；原生小队面板右边约x=480，重要指令左边约x=1450，面板右边为x=1330。空房间/读取状态高132；有成员时高112+144×成员数，最多544，以短边比例缩放。按用户实机反馈缩窄并左移，避免原0.2.1布局覆盖重要指令。文本裁剪与链接点击区域使用游戏 `Gui.text_extents`；关闭菜单、切页或世界销毁时释放所创建的 GUI。`build/panel-preview.png` 与 `build/panel-empty-preview.png` 是根据测试绘制指令和用户截图生成的离线示意，替代字体仅用于检查位置，不代表游戏字体或新版实机结果。

点击链接时复核当前成员，再向 Windows 剪贴板写入 `CF_UNICODETEXT`。仅在游戏前台、鼠标在链接范围内且产生新按下事件时触发；进入菜单或重新聚焦时需先释放鼠标。使用 `GMEM_MOVEABLE`；成功交付后由系统持有内存，失败释放。不读取剪贴板。

## 一致性与精度

先读取当前成员，按 peer 精确匹配平台记录；读取后复核 local SteamID、session 内容、名册、平台表根指针/数组、命中记录。任何变化返回 UNKNOWN，下一次轮询重新尝试。双读可以拒绝许多进出房中间状态，不能保证无锁读取是原子事务。

ID 用两个32位整数保存；十进制格式化使用精确长除法。地址与身份数值分开处理。Steam 链接仅为经过验证的 Public/Individual/Desktop ID 生成，不根据昵称搜索玩家。

## 验证范围

- 离线：直接在游戏 `lua51.dll` 中做 Lua 语法与五套回归测试，包括自己排除、历史缓存过滤、64位精度、跨平台/缺失映射、房间变化和旧 update 链；另以模拟 GUI/Win32 接口验证菜单状态、字体 hash 字节序、布局/长中文昵称、链接范围、一次点击复制、焦点/释放门槛、成员重新校验及剪贴板失败清理。模拟验证不等于实际绘制或系统剪贴板验收。
- 现场：外部工具复用实际 Lua 内存读取器，Steam getter 替换为本机 Steam 客户端 ActiveUser，名称查询停用；单人房间结果为空；2026-10-13 19:25 的多人样本读取3名队友，其中1名取得 SteamID64/主页，2名平台代码0没有 Steam 映射。验证不会输出自己或历史成员。
- 实机反馈：用户在 MDL 列表确认0.2.0已加载，本机日志确认实际 Steam getter 与成员导出正常。0.2.0因上述材质对齐检查错误没有绘制面板。
- 实机反馈：用户截图确认0.2.1已显示空房间面板，但尺寸和位置覆盖了重要指令；0.2.2按截图调整布局。
- 待实机：0.2.2的新布局、实际鼠标点击与剪贴板、多人进出房/房主迁移、任务与回船、Steam 昵称缓存。本次未向游戏部署0.2.2。

## 外部来源

- [Bingus Shared Loader 作者打包规范](https://github.com/CowboyBingus/BingusSharedLoader/blob/main/docs/AUTHORING.md)：声明式 Lua 资源、ZIP 布局、API1、私有 FFI 名称与 update 共存。
- [Better Lobby Management 游戏布局](https://github.com/CowboyBingus/BetterLobbyManagement/blob/f83aeacb4e1ade26943bd4ef85e1ee45d4c7b82b/src/game.lua) 与 [技术说明](https://github.com/CowboyBingus/BetterLobbyManagement/blob/f83aeacb4e1ade26943bd4ef85e1ee45d4c7b82b/docs/TECHNICAL.md)：当前 peer 是 PlayFab 身份；会话列表与名册布局。上游 0BSD，未打包其游戏修改功能。
- [Steamworks GetSteamID](https://partner.steamgames.com/doc/api/ISteamUser#GetSteamID)：获取调用者身份。
- [Steamworks GetFriendPersonaName](https://partner.steamgames.com/doc/api/ISteamFriends#GetFriendPersonaName)：获取已知玩家的缓存昵称，缓存不足时可能为空或 unknown。
- [Steamworks CSteamID](https://partner.steamgames.com/doc/api/steam_api#CSteamID)：平台账号类型与64位表示。
- [Stingray SteamLobby members](https://help.autodesk.com/cloudhelp/ENU/Stingray-Help/lua_ref/obj_stingray_SteamLobby.html)：通用引擎背景；不能据此假定 HD2 当前房间就是 Steam lobby。本实现读取实际 PlayFab session。
- [Windows ReadProcessMemory](https://learn.microsoft.com/en-us/windows/win32/api/memoryapi/nf-memoryapi-readprocessmemory)：只读复制，读取失败会被检查。
- [Better Lobby Management 菜单实现](https://github.com/CowboyBingus/BetterLobbyManagement/blob/main/src/menu.lua)：Esc screen、GAME 页与 dialog 状态参考；仅采用读取状态，不包含其原生写入功能。
- [Stingray Gui](https://help.autodesk.com/cloudhelp/ENU/Stingray-Help/lua_ref/obj_stingray_Gui.html)：screen GUI 底左坐标、text 与 text_extents 接口。
- [Windows 剪贴板操作](https://learn.microsoft.com/en-us/windows/win32/dataxchg/clipboard-operations)：GMEM_MOVEABLE、CF_UNICODETEXT 与内存所有权规则。
