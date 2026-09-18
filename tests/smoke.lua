------------------------------------------------------------------
-- BoneShield.lua 离线冒烟测试
--   用法：lua smoke.lua <BoneShield.lua 的绝对路径>
------------------------------------------------------------------
local ADDON = assert(arg[1], 'need path to BoneShield.lua')
local HERE  = (arg[0]:gsub('[^/\\]*$', ''))

local ENV = dofile(HERE .. 'wowstub.lua')
local env = ENV.install('zhCN')
env._G = env
setmetatable(env, { __index = _G })

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

local function drain()
    local t, out = env.__lines, {}
    for i = 1, #t do out[i] = t[i] end
    for i = #t, 1, -1 do t[i] = nil end
    return table.concat(out, '\n')
end
local function clearLines()
    local t = env.__lines
    for i = #t, 1, -1 do t[i] = nil end
end
-- 状态/诊断走 /bdk debug（/bdk 自己现在只打帮助）
local function cmd(m)
    env.SlashCmdList.BLOODDEATHKNIGHT(m or '')
    return drain()
end
local function sounds() return #env.__sounds end
local function resetSounds() env.__sounds = {} end
-- 语音分三条，与三条判据一一对应（听声音就知道是哪条在响）：
--   voice-cn-1 = 骨盾没了 / voice-cn-2 = 骨盾层数不够 / voice-cn-3 = 骨盾快没了（倒计时到点）
-- 文件名互不为子串，按名字查找不会互相误命中。
-- 注：旧的共用文件 voice-cn.mp3 已退役 —— 下面的断言里它一次都不许出现。
local function soundUsed(sub)
    for i = 1, #env.__sounds do
        if env.__sounds[i]:find(sub, 1, true) then return true end
    end
    return false
end

local function tick(n)
    for _ = 1, (n or 1) do
        ENV.setNow(ENV.now() + 0.5)
        local d = env.__driver
        d.__scripts.OnUpdate(d, 0.5)
        env.runTimers()
    end
end

------------------------------------------------------------------ 搭建 CDM
env.addCooldown(1, { spellID = 195181 })   -- 骨盾
-- 埋骨之所：实测形态是**一个** cooldownInfo 同时带 spellID 与 linkedSpellID
-- （游戏里 /bdk debug 打出来是 spell=219786 linked=219788，同一个 cdID）
env.addCooldown(2, { spellID = 219786, linkedSpellID = 219788 })

local viewer = ENV.makeViewer({ 1, 2 })
env.BuffIconCooldownViewer = viewer
env.BuffBarCooldownViewer  = nil            -- 只用一个 viewer

local bsItem  = viewer.__items[1]
local ossItem = viewer.__items[2]
bsItem.IsActive, ossItem.IsActive = false, false

------------------------------------------------------------------ 加载插件
-- 按 toc 的顺序：Commands.lua（命令表）先加载，模块往它里面登记子命令。
local ROOT = ADDON:gsub('[^/\\]*$', '')
local cmds = assert(loadfile(ROOT .. 'Commands.lua', 't', env))
cmds('BloodDeathKnightHelper')

local chunk = assert(loadfile(ADDON, 't', env))
chunk('BloodDeathKnightHelper')

local driver, evt
for i = 1, #ENV.frames do
    local f = ENV.frames[i]
    if f.__scripts then
        if f.__scripts.OnUpdate then driver = f end
        if f.__scripts.OnEvent  then evt    = f end
    end
end
assert(driver, 'driver frame not found')
assert(evt,    'event frame not found')
env.__driver = driver
env.__alertText = ENV.fonts[1]
assert(env.__alertText, 'alert fontstring not found')

env.SlashCmdList.BLOODDEATHKNIGHT('')                     -- 加载前不许崩
evt.__scripts.OnEvent(evt, 'ADDON_LOADED', 'BloodDeathKnightHelper')
env.__inCombat = true
ENV.setNow(10)
evt.__scripts.OnEvent(evt, 'PLAYER_ENTERING_WORLD')
drain()

io.write('\n== T0 配置识别 ==\n')
local s = cmd('debug')
check('骨盾条目已监控', s:find('骨盾(CDM): 已监控 x1', 1, true) ~= nil, s)
check('埋骨之所条目已监控', s:find('埋骨之所(CDM): 已监控 x1', 1, true) ~= nil, s)
check('未出现"缺失"', s:find('缺失', 1, true) == nil, s)
check('未出现配置提示文字', s:find('拖入冷却管理器', 1, true) == nil, s)
check('状态里能看到蒙版开关', s:find('图标蒙版: 开', 1, true) ~= nil, s)

io.write('\n== T1 骨盾亮起 → WARN_AFTER(24s) 倒计时到点 ==\n')
bsItem.IsActive = true
tick(2)
check('骨盾在场，倒计时启动', cmd('debug'):find('timer: 2', 1, true) ~= nil)
check('提醒前不挂蒙版', #bsItem.__kids == 0)

resetSounds()
tick(45)                                   -- 累计 23.5s < WARN_AFTER(24s)：还没到点
check('到点前不提醒', sounds() == 0, sounds())
tick(4)                                    -- 累计 25.5s：越过 WARN_AFTER
check('到点响了语音', sounds() == 1, sounds())
check('到点用的是第 3 条 voice-cn-3.mp3（骨盾快没了）',
    soundUsed('voice-cn-3.mp3') and not soundUsed('voice-cn-1.mp3')
        and not soundUsed('voice-cn-2.mp3') and not soundUsed('voice-cn.mp3'),
    table.concat(env.__sounds, ' '))
check('到点显示的红字是「骨盾快没了」',
    env.__alertText:GetText() == '骨盾快没了', env.__alertText:GetText())

local ov
for i = 1, #bsItem.__kids do
    if bsItem.__kids[i].fill then ov = bsItem.__kids[i] end
end
check('蒙版挂到了骨盾图标上（是它的子帧）', ov ~= nil)
if ov then
    check('蒙版帧没有 Hide（只用 alpha 开关）', ov.__shown == true)
    check('蒙版帧层级 == 图标帧层级', ov.__level == bsItem.__level,
        ov.__level .. ' vs ' .. bsItem.__level)
    check('蒙版是红色蒙版', ov.fill.r == 1 and ov.fill.g < 0.1)
    local a1 = ov.__alpha
    for _ = 1, 4 do ov.__scripts.OnUpdate(ov, 0.1) end
    local a2 = ov.__alpha
    check('蒙版在脉动', a1 ~= a2, a1 .. ' -> ' .. a2)
    check('蒙版不透明度落在 [0.10, 0.45]', a2 >= 0.099 and a2 <= 0.451, a2)
end
local ossOv = false
for i = 1, #ossItem.__kids do if ossItem.__kids[i].fill then ossOv = true end end
check('蒙版没有挂到埋骨之所图标上', not ossOv)

io.write('\n== T2 "读不到" != "没有了" ==\n')
resetSounds()
-- 受限战斗的典型样子：isActive 变机密，但图标照画（buff 还在）
bsItem.IsActive = ENV.SECRET
tick(4)                                    -- 2 秒
check('isActive 机密但图标在画 → 仍读作在场', cmd('debug'):find('timer: idle', 1, true) == nil)
check('未误报补盾', sounds() == 0, sounds())
check('蒙版仍在闪', ov and ov.__scripts.OnUpdate ~= nil)
bsItem.IsActive = true
tick(2)

io.write('\n== T3 掉线去抖（单拍不算掉） ==\n')
resetSounds()
bsItem.IsActive = false
tick(1)                                    -- 0.5s < DOWN_GRACE
check('掉一拍未触发提醒', sounds() == 0, sounds())
check('倒计时未被打断', cmd('debug'):find('timer: idle', 1, true) == nil)
bsItem.IsActive = true                     -- 立刻回来
tick(2)
check('瞬态回落不触发提醒', sounds() == 0, sounds())

io.write('\n== T9 帧池重建：条目瞬态消失 ==\n')
resetSounds()
local keepID = bsItem.__cooldownID
bsItem.__cooldownID = 999                  -- 池化帧被换绑给别的法术
tick(2)                                    -- 1 秒扫不到骨盾条目
check('条目不在了也不误报补盾', sounds() == 0, sounds())
check('倒计时没被清掉（空列表 = 未知，不是掉了）', cmd('debug'):find('timer: idle', 1, true) == nil)
check('换绑帧上的蒙版已撤（不留在别人图标上）', ov and ov.__alpha == 0, ov and ov.__alpha)
bsItem.__cooldownID = keepID               -- 换回来
tick(3)
check('恢复后倒计时仍在', cmd('debug'):find('timer: idle', 1, true) == nil)
check('恢复后蒙版重新挂上', ov and ov.__scripts.OnUpdate ~= nil)

io.write('\n== T9b 瞬态消失不弹"未配置" ==\n')
env.__inCombat = false
env.__alertText:SetText('')                -- 清掉旧文案，便于判定
bsItem.__cooldownID = 999
tick(2)                                    -- 1 秒 < ABSENT_GRACE(3s)
check('瞬态消失不弹配置提示', env.__alertText:GetText() ~= '请将「骨盾」和「埋骨之所」拖入冷却管理器 (CDM)',
    env.__alertText:GetText())
bsItem.__cooldownID = keepID
env.__inCombat = true
tick(1)

io.write('\n== T4 常暗诱饵帧（埋骨之所拖错条目） ==\n')
resetSounds()
ossItem.IsActive = ENV.SECRET             -- 读不到
ossItem:Hide()                            -- 也从没画出来过
ossItem:SetAlpha(0)
tick(3)
local dump = cmd('debug')
check('诱饵帧被标为 unreadable / proven=no',
    dump:find('isActive=unreadable proven=no', 1, true) ~= nil, dump)
check('诱饵帧不产生提醒', sounds() == 0, sounds())

io.write('\n== T5 施放刷新技能 ==\n')
ossItem.IsActive = false
ossItem:Show()
ossItem:SetAlpha(1)
tick(1)
evt.__scripts.OnEvent(evt, 'UNIT_SPELLCAST_SUCCEEDED', 'player', nil, 195182)
local st = cmd('debug')
check('施放后倒计时重置为 24s', st:find('timer: 24', 1, true) ~= nil, st)
check('施放后蒙版清除（alpha 归零）', ov and ov.__alpha == 0, ov and ov.__alpha)
check('施放后蒙版停止脉动', ov and ov.__scripts.OnUpdate == nil)
check('施放后不再重复播报', env.__sounds and #env.__sounds == 0, #env.__sounds)

io.write('\n== T6 骨盾真正消失（战斗中） ==\n')
resetSounds()
bsItem.IsActive = false
tick(5)                                    -- 2.5s > DOWN_GRACE
check('连续消失后触发一次提醒', sounds() == 1, sounds())
check('骨盾掉了用的是第 1 条 voice-cn-1.mp3',
    soundUsed('voice-cn-1.mp3') and not soundUsed('voice-cn-2.mp3')
        and not soundUsed('voice-cn-3.mp3'),
    table.concat(env.__sounds, ' '))
check('骨盾掉了显示的红字是「骨盾没了」',
    env.__alertText:GetText() == '骨盾没了', env.__alertText:GetText())
check('倒计时已清空', cmd('debug'):find('timer: idle', 1, true) ~= nil)

io.write('\n== T7 非战斗消失 → 静默 ==\n')
resetSounds()
env.__inCombat = false
bsItem.IsActive = true
tick(2)
resetSounds()
bsItem.IsActive = false
tick(3)
check('非战斗掉盾不打扰', sounds() == 0, sounds())

io.write('\n== T8 非鲜血专精待机 ==\n')
env.__spec = 2
clearLines()
tick(2)
check('非鲜血专精无倒计时且无蒙版', cmd('debug'):find('timer: idle', 1, true) ~= nil)
check('非鲜血专精时不打蒙版', ov and ov.__alpha == 0, ov and ov.__alpha)

io.write('\n== T10 一个条目携带两个 ID（埋骨之所的实测形态） ==\n')
-- 回归：/bdk debug 曾经"一个 ID 一行"，于是一条 spell+linked 的条目看起来像两条独立
-- 条目，会被误读成"得在两个 ID 之间挑对的那个"。诊断必须打成一行。
env.__spec = 1
env.__inCombat = false
clearLines()
tick(1)
local dd = cmd('debug')
local function countOf(s, pat)
    local n, pos = 0, 1
    while true do
        local _, b = s:find(pat, pos, true)
        if not b then return n end
        n = n + 1
        pos = b + 1
    end
end
check('两个 ID 只占一个条目行', countOf(dd, '<- OSSUARY') == 1, dd)
check('条目行把两个 ID 摊在同一行', dd:find('(spell=219786 linked=219788)', 1, true) ~= nil, dd)
check('只跟到一个帧，不是两条条目', dd:find('埋骨之所(CDM): frames=1', 1, true) ~= nil, dd)
check('角色标签区分主 ID 与关联 ID', dd:find('ids=spell=219786 linked=219788', 1, true) ~= nil, dd)
env.__inCombat = true

io.write('\n== T11 同一窗口内的重复提醒 ==\n')
-- 倒计时到点 / 骨盾掉了 / 埋骨之所掉了 三条判据各有自己的红字与语音，而它们完全可能在
-- 同一拍或半秒内接连成立。规则是：2 秒内只发一次声（ALERT_GAP），但**红字不吞** ——
-- 会换成最新那条判据的文案（"快没了" → "没了" 本身是升级信息）。下面三种对齐是刻意
-- 构造的：让"骨盾读到不在场"的起始时刻落在倒计时到点前 1.0 秒 / 0.5 秒。
local function armWindow()
    -- 重新摆成"骨盾在场"，跑一拍让状态机认到 → 开一个新窗口（timerEnd = 现在 + 24）
    ossItem.IsActive = true
    ossItem:Show()
    ossItem:SetAlpha(1)
    bsItem.IsActive = true
    bsItem:Show()
    bsItem:SetAlpha(1)
    tick(1)
    resetSounds()
end

local function findFrame(name)
    for i = 1, #ENV.frames do
        if ENV.frames[i].__name == name then return ENV.frames[i] end
    end
end

local function bsOverlay()
    for i = 1, #bsItem.__kids do
        if bsItem.__kids[i].fill then return bsItem.__kids[i] end
    end
end

-- (a) 不在场起始于到点前 1.0 秒：去抖恰好与倒计时到点落在同一拍
armWindow()
tick(45)                        -- 到点前 1.5s
bsItem.IsActive = false
tick(1)                         -- 到点前 1.0s：bsDownSince 起算
tick(1)                         -- 到点前 0.5s
tick(1)                         -- 到点：倒计时 + 去抖同时成立
check('同一拍内只响一次', sounds() == 1, sounds())

-- (b) 不在场起始于到点前 0.5 秒：到点响一次，半秒后去抖成立又想响一次
armWindow()
tick(46)                        -- 到点前 1.0s
bsItem.IsActive = false
tick(1)                         -- 到点前 0.5s：bsDownSince 起算
tick(1)                         -- 到点：响第一次
check('到点响了', sounds() == 1, sounds())
tick(1)                         -- 到点后 0.5s：去抖成立
check('半秒内不重复响', sounds() == 1, sounds())
-- 去重只吞声音：红字要换成最新那条判据的话（这里是"骨盾没了"），蒙版也得留着 ——
-- 掉盾那条路已经 ClearWindow() 撤过一次红字和蒙版。
check('去重后红字换成最新那条「骨盾没了」',
    env.__alertText:GetText() == '骨盾没了', env.__alertText:GetText())
local af = findFrame('BloodDeathKnightAlert')
check('去重后红字仍在屏幕上', af and af.__shown == true)
local mask = bsOverlay()
check('去重后蒙版仍在闪', mask ~= nil and mask.__scripts.OnUpdate ~= nil)

-- (c) 真实情形不能被去重误伤：到点提醒后骨盾又撑了 6 秒才真到期，这一声必须还在
armWindow()
tick(48)                        -- 24s：倒计时到点
check('到点提醒响了', sounds() == 1, sounds())
tick(12)                        -- 再撑 6 秒（骨盾真正的到期时刻）
bsItem.IsActive = false
tick(4)                         -- 2s：去抖成立
check('骨盾随后真的消失，再报一次（不被去重吞掉）', sounds() == 2, sounds())
check('后一声是第 1 条「骨盾没了」voice-cn-1.mp3',
    env.__sounds[2] ~= nil and env.__sounds[2]:find('voice-cn-1.mp3', 1, true) ~= nil,
    tostring(env.__sounds[2]))

-- (d) 埋骨之所先掉、骨盾随后也掉：两条判据各有各的话，但 2 秒内只发一次声
armWindow()
tick(1)
ossItem.IsActive = false
tick(3)                         -- 1.5s：埋骨之所去抖成立，响一次
check('埋骨之所掉了报一次', sounds() == 1, sounds())
check('埋骨之所掉了用的是第 2 条 voice-cn-2.mp3',
    soundUsed('voice-cn-2.mp3') and not soundUsed('voice-cn-1.mp3'),
    table.concat(env.__sounds, ' '))
check('埋骨之所掉了显示的红字是「骨盾层数不够」',
    env.__alertText:GetText() == '骨盾层数不够', env.__alertText:GetText())
bsItem.IsActive = false
tick(3)                         -- 1.5s：骨盾也掉了
check('骨盾随后也掉，2 秒内不重复响', sounds() == 1, sounds())

io.write('\n== T12 命令表：/bdk 帮助排版 ==\n')
local help = cmd('')
check('空命令 = 帮助', help:find('/bdk bs test', 1, true) ~= nil, help)
check('帮助里命令与说明是两种颜色',
    help:find('|cffffd100/bdk', 1, true) ~= nil and help:find('|cff9d9d9d', 1, true) ~= nil, help)
check('帮助里没有 debug（隐藏命令）', help:find('debug', 1, true) == nil, help)
check('帮助里列出骨盾这两条',
    help:find('/bdk bs test', 1, true) ~= nil and help:find('/bdk bs sound', 1, true) ~= nil, help)
check('没加载的模块不往帮助里塞命令（血沸条目此刻不该出现）',
    help:find('/bdk bp', 1, true) == nil, help)
check('帮助第一行就是 /bdk 自己', help:find('/bdk ', 1, true) ~= nil)

-- 说明列对齐：命令行一律按"显示宽度"补空格（汉字算两列），所以 ASCII 各行落在
-- 同一个字节位置。汉字那一条的检验在血沸那套里（那边有 `/bdk bp width 数字`）。
local function descCol(text, label)
    for line in text:gmatch('[^\n]+') do
        if line:find(label, 1, true) then return line:find('|cff9d9d9d', 1, true) end
    end
end
local colSelf = descCol(help, '/bdk ')
local colBs   = descCol(help, '/bdk bs test')
local colSnd  = descCol(help, '/bdk bs sound')
check('ASCII 各行的说明列对齐', colSelf ~= nil and colSelf == colBs and colSelf == colSnd,
    tostring(colSelf) .. '/' .. tostring(colBs) .. '/' .. tostring(colSnd))

io.write('\n== T13 删掉的旧命令不再存在 ==\n')
for _, old in ipairs({ 'test', 'dump', 'sound on', 'sound off', 'text on', 'text off',
                       'flash on', 'flash off', 'lang cn', 'lang auto', 'enable off', 'enable on' }) do
    local out = cmd(old)
    check('认不出旧命令 ' .. old, out:find('没有这条命令', 1, true) ~= nil, out)
end
check('认不出的命令顺手打帮助', cmd('nonsense'):find('/bdk bs test', 1, true) ~= nil)
check('斜杠命令只有 /bdk（旧别名 /bsr 已移除）',
    env.SLASH_BLOODDEATHKNIGHT1 == '/bdk' and env.SLASH_BLOODDEATHKNIGHT2 == nil,
    tostring(env.SLASH_BLOODDEATHKNIGHT1) .. '/' .. tostring(env.SLASH_BLOODDEATHKNIGHT2))

io.write('\n== T14 骨盾的两条命令：bs test / bs sound ==\n')
env.__spec = 1
resetSounds()
local t = cmd('bs test')
check('bs test 认领并打出自检行', t:find('test: shown=', 1, true) ~= nil, t)
check('bs test 会出声', sounds() == 1, sounds())
check('bs test 不带参数 = 第 1 条「骨盾没了」(voice-cn-1.mp3)',
    t:find('voice 1/3', 1, true) ~= nil and t:find('voice-cn-1.mp3', 1, true) ~= nil
        and soundUsed('voice-cn-1.mp3'), t)
check('bs test 的红字是「骨盾没了」',
    env.__alertText:GetText() == '骨盾没了', env.__alertText:GetText())
check('bs test 顺手列出三条的编号', t:find('bs test 1|2|3', 1, true) ~= nil, t)

resetSounds()
local t2v = cmd('bs test 2')
check('bs test 2 = 第 2 条「骨盾层数不够」(voice-cn-2.mp3)',
    t2v:find('voice 2/3', 1, true) ~= nil and t2v:find('voice-cn-2.mp3', 1, true) ~= nil
        and soundUsed('voice-cn-2.mp3') and not soundUsed('voice-cn-1.mp3'),
    t2v .. ' | ' .. table.concat(env.__sounds, ' '))
check('bs test 2 的红字是「骨盾层数不够」',
    env.__alertText:GetText() == '骨盾层数不够', env.__alertText:GetText())

resetSounds()
local t3v = cmd('bs test 3')
check('bs test 3 = 第 3 条「骨盾快没了」(voice-cn-3.mp3)',
    t3v:find('voice 3/3', 1, true) ~= nil and t3v:find('voice-cn-3.mp3', 1, true) ~= nil
        and soundUsed('voice-cn-3.mp3') and not soundUsed('voice-cn-2.mp3'),
    t3v .. ' | ' .. table.concat(env.__sounds, ' '))
check('bs test 3 的红字是「骨盾快没了」',
    env.__alertText:GetText() == '骨盾快没了', env.__alertText:GetText())

resetSounds()
cmd('bs sound off')
check('bs sound 关掉语音', env.BloodDeathKnightDB.sound == false,
    tostring(env.BloodDeathKnightDB.sound))
local t2 = cmd('bs test')
check('语音关了自检照旧、但不出声',
    t2:find('test: shown=', 1, true) ~= nil and sounds() == 0, sounds())

resetSounds()
cmd('bs sound')
check('bs sound 不带参数 = 切回开', env.BloodDeathKnightDB.sound == true,
    tostring(env.BloodDeathKnightDB.sound))
cmd('bs test')
check('切回开后又能出声', sounds() == 1, sounds())
check('bs sound 的非法参数只给用法', cmd('bs sound x'):find('用法', 1, true) ~= nil)

-- 非鲜血专精：待机，别给一个假的"预览"
env.__spec = 2
local idle = cmd('bs test')
check('非鲜血专精 bs test 只说待机',
    idle:find('非鲜血死亡骑士', 1, true) ~= nil and idle:find('test: shown=', 1, true) == nil, idle)
env.__spec = 1

io.write(('\n结果：%d 通过 / %d 失败\n'):format(passes, fails))
os.exit(fails == 0 and 0 or 1)
