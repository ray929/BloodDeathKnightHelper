------------------------------------------------------------------
-- Commands.lua 离线冒烟测试（跨模块：三个文件一起加载）
--   用法：lua cmd_smoke.lua <Commands.lua 的绝对路径>
--
-- 这里管的是"命令表"这件事本身：帮助排版与配色、隐藏命令、分组顺序、参数切分、
-- 同名命令（/bdk debug 两个模块各一条）一起跑、认不出命令时的兜底。
-- 单个模块自己的行为归 smoke.lua / bp_smoke.lua。
------------------------------------------------------------------
local CMDFILE = assert(arg[1], 'need path to Commands.lua')
local ROOT    = CMDFILE:gsub('[^/\\]*$', '')
local HERE    = (arg[0]:gsub('[^/\\]*$', ''))

-- 游戏内文件夹名。WoW 加载 toc 里列出的 lua 时，会把它当第一个参数传进来
-- （模块里是 `local ADDON_NAME = ...`），ADDON_LOADED 事件也带这个名字，
-- 模块靠 `arg1 ~= ADDON_NAME` 认领自己的存档事件。测试必须用同一个名字。
local ADDONNAME = 'BloodDeathKnightHelper'

local ENV = dofile(HERE .. 'wowstub.lua')

local fails, passes = 0, 0
local function check(name, ok, extra)
    if ok then
        passes = passes + 1
        io.write('  \27[32mPASS\27[0m ', name, '\n')
    else
        fails = fails + 1
        io.write('  \27[31mFAIL\27[0m ', name, extra and ('  <- ' .. tostring(extra)) or '', '\n')
    end
end

------------------------------------------------------------------ 搭一个"三个文件都加载"的环境
local function loadAll(lang)
    local env = ENV.install(lang or 'zhCN')
    ENV.installBP(env)
    env._G = env
    setmetatable(env, { __index = _G })
    env.__spec = 1
    env.UnitClass = function() return 'X', 'DEATHKNIGHT', 1 end

    for _, f in ipairs({ 'Commands.lua', 'BoneShield.lua', 'BoilingPoint.lua' }) do
        assert(loadfile(ROOT .. f, 't', env))(ADDONNAME)
    end

    -- ADDON_LOADED 才会建 SavedVariables；命令处理函数依赖它
    for i = 1, #ENV.frames do
        local fr = ENV.frames[i]
        if fr.__scripts and fr.__scripts.OnEvent then
            fr.__scripts.OnEvent(fr, 'ADDON_LOADED', ADDONNAME)
            break
        end
    end

    function env.drain()
        local t, out = env.__lines, {}
        for i = 1, #t do out[i] = t[i] end
        for i = #t, 1, -1 do t[i] = nil end
        return table.concat(out, '\n')
    end
    function env.cmd(m)
        env.BloodDeathKnightDispatch(m or '')
        return env.drain()
    end
    return env
end

local e = loadAll('zhCN')

------------------------------------------------------------------
io.write('\n== C1 帮助：内容、顺序、配色 ==\n')
local help = e.cmd('')
check('第一行是插件名 + "命令："', help:find('[鲜血死亡骑士]', 1, true) ~= nil
    and help:find('命令：', 1, true) ~= nil, help)

-- 只有这 6 条（外加 debug，且 debug 不许出现）
local lines = {}
for line in help:gmatch('[^\n]+') do lines[#lines + 1] = line end
local cmds = {}
for i = 1, #lines do
    local c = lines[i]:match('|cffffd100(/bdk[^|]*)|r')
    if c then cmds[#cmds + 1] = c end
end
check('帮助里正好 6 条命令', #cmds == 6, table.concat(cmds, ' / '))
check('顺序 = /bdk、bp test、bp width、bp text、bs test、bs sound',
    table.concat(cmds, '|') == '/bdk|/bdk bp test|/bdk bp width 数字|/bdk bp text|/bdk bs test|/bdk bs sound',
    table.concat(cmds, '|'))
check('命令是一种颜色、说明是另一种',
    help:find('|cffffd100/bdk bp test|r', 1, true) ~= nil
        and help:find('|cff9d9d9d预览/拖动血沸条|r', 1, true) ~= nil, help)
check('debug 不显示在帮助里', help:find('debug', 1, true) == nil, help)
check('两个组之间空一行', (function()
    -- 空行在 gmatch('[^\n]+') 里看不见，直接数换行挨着换行的地方
    local _, n = help:gsub('\n\n', '')
    return n == 1
end)(), help)

------------------------------------------------------------------
io.write('\n== C2 说明列按显示宽度对齐 ==\n')
-- 汉字 2 列 6 字节：`数字` 那行补的空格比 ASCII 行少 2 个，所以说明列的**字节**位置
-- 比 ASCII 行靠后 2 —— 这正是"按列而不是按字节对齐"的指纹。
local function descCol(text, label)
    for line in text:gmatch('[^\n]+') do
        if line:find(label, 1, true) then return line:find('|cff9d9d9d', 1, true) end
    end
end
local cSelf = descCol(help, '/bdk ')
local cTest = descCol(help, '/bdk bp test')
local cSound = descCol(help, '/bdk bs sound')
local cCjk   = descCol(help, '/bdk bp width')
check('ASCII 各行说明列在同一位置', cSelf ~= nil and cSelf == cTest and cSelf == cSound,
    tostring(cSelf) .. '/' .. tostring(cTest) .. '/' .. tostring(cSound))
check('含汉字的那行按显示宽度补空格（位置比 ASCII 行靠后 2 字节）',
    cCjk == cSelf + 2, tostring(cCjk) .. ' vs ' .. tostring(cSelf + 2))

------------------------------------------------------------------
io.write('\n== C3 英文客户端 ==\n')
local en = loadAll('enUS')
local ehelp = en.cmd('')
check('英文帮助用英文说明',
    ehelp:find('show this help', 1, true) ~= nil
        and ehelp:find('test the bone shield monitor', 1, true) ~= nil, ehelp)
check('英文占位词是 number', ehelp:find('/bdk bp width number', 1, true) ~= nil, ehelp)

------------------------------------------------------------------
io.write('\n== C4 同名命令：/bdk debug 两个模块一起跑 ==\n')
local dbg = e.cmd('debug')
check('骨盾那一侧在场（状态行）', dbg:find('骨盾(CDM):', 1, true) ~= nil, dbg)
check('骨盾那一侧在场（CDM 枚举）', dbg:find('CDM auras:', 1, true) ~= nil, dbg)
check('血沸那一侧在场（门与高亮表）', dbg:find('门已认证', 1, true) ~= nil
    and dbg:find('本会话见过的高亮', 1, true) ~= nil, dbg)
check('debug 不顺手打帮助', dbg:find('命令：', 1, true) == nil, dbg)
check('debug 认领（返回 true）', e.BloodDeathKnightDispatch('debug') == true)

------------------------------------------------------------------
io.write('\n== C5 参数切分与归一化 ==\n')
e.cmd('bp width 240')
check('参数传到了模块手里（宽 240）',
    math.abs(e.findByType('StatusBar').__w - 240) < 0.01, e.findByType('StatusBar').__w)
check('大小写与多余空格都归一化', (function()
    e.cmd('  BP    WIDTH    300  ')
    return math.abs(e.findByType('StatusBar').__w - 300) < 0.01
end)(), e.findByType('StatusBar').__w)
check('bp 组里没有的命令不认领', e.cmd('bp nonsense'):find('没有这条命令', 1, true) ~= nil)
check('缺参数时给用法（不是崩）', e.cmd('bp width'):find('用法', 1, true) ~= nil)
check('bp textoff 不认（不许读成 bp text off）',
    e.BloodDeathKnightDispatch('bp textoff') == false)

------------------------------------------------------------------
io.write('\n== C6 认不出的命令 ==\n')
local unknown = e.cmd('nonsense')
check('提示没有这条命令', unknown:find('没有这条命令：nonsense', 1, true) ~= nil, unknown)
check('顺手打一遍帮助', unknown:find('/bdk bs test', 1, true) ~= nil)
check('返回 false（没人认领）', e.BloodDeathKnightDispatch('nonsense') == false)
check('help / 空串都是帮助', e.BloodDeathKnightDispatch('help') == true
    and e.BloodDeathKnightDispatch('') == true)
check('/bdk 是唯一注册的斜杠命令（旧别名 /bsr 已移除）',
    e.SLASH_BLOODDEATHKNIGHT1 == '/bdk' and e.SLASH_BLOODDEATHKNIGHT2 == nil,
    tostring(e.SLASH_BLOODDEATHKNIGHT1) .. '/' .. tostring(e.SLASH_BLOODDEATHKNIGHT2))

------------------------------------------------------------------
io.write('\n== C7 文件夹名 / toc 文件名 / package-as 三者必须一致 ==\n')
-- WoW 靠「文件夹名 == toc 文件名」找 toc，`package-as` 决定发布 zip 里那个文件夹叫什么。
-- 三者一旦不一致，插件在游戏里的表现是**列表里看得见名字、里面什么都没有**，且不报任何错，
-- 排查起来很费劲 —— 所以在这里钉死。
local function readAll(path)
    local f = io.open(path, 'rb')
    if not f then return nil end
    local s = f:read('a'); f:close()
    return s
end
local meta = readAll(ROOT .. 'pkgmeta.yaml')
check('读得到 pkgmeta.yaml', meta ~= nil, ROOT .. 'pkgmeta.yaml')
local pkg = meta and meta:match('package%-as:%s*([%w_%-%.]+)')
check('pkgmeta.yaml 里写得出 package-as', pkg ~= nil and pkg ~= '', pkg)
check('package-as == 测试用的 addon 名（也 == 游戏内文件夹名）',
    pkg == ADDONNAME, tostring(pkg) .. ' vs ' .. ADDONNAME)
local tocFile = readAll(ROOT .. tostring(pkg) .. '.toc')
check('存在与 package-as 同名的 toc', tocFile ~= nil, tostring(pkg) .. '.toc')
check('toc 里的 SavedVariables 还在（改名别把它捎上）',
    tocFile ~= nil and tocFile:find('## SavedVariables:%s*BloodDeathKnightDB') ~= nil,
    tocFile and tocFile:match('## SavedVariables:[^\n]*'))
-- 声音路径靠 `local ADDON_NAME = ...`（runtime 传进来的文件夹名）拼出来，不许硬编码。
-- 判据：任何一行里同时出现 `AddOns` 和文件夹名，就是有人手写死了（路径在字符串里长这样：
-- `Interface\\AddOns\\%s\\Sounds\\voice-%s.mp3`）。
local bs = readAll(ROOT .. 'BoneShield.lua')
local badPath = nil
for line in (bs or ''):gmatch('[^\n]+') do
    if line:find('AddOns', 1, true) and line:find('BloodDeathKnight', 1, true) then
        badPath = line
    end
end
check('声音路径不硬编码文件夹名（用 ADDON_NAME 拼）', badPath == nil, badPath)
check('声音路径确实用的 ADDON_NAME', bs ~= nil and bs:find('ADDON_NAME', 1, true) ~= nil)

io.write(('\n结果：%d 通过 / %d 失败\n'):format(passes, fails))
os.exit(fails == 0 and 0 or 1)
