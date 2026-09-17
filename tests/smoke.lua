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
local function cmd(m)
    env.SlashCmdList.BLOODDEATHKNIGHT(m or '')
    return drain()
end
local function sounds() return #env.__sounds end
local function resetSounds() env.__sounds = {} end

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
-- （游戏里 /bdk dump 打出来是 spell=219786 linked=219788，同一个 cdID）
env.addCooldown(2, { spellID = 219786, linkedSpellID = 219788 })

local viewer = ENV.makeViewer({ 1, 2 })
env.BuffIconCooldownViewer = viewer
env.BuffBarCooldownViewer  = nil            -- 只用一个 viewer

local bsItem  = viewer.__items[1]
local ossItem = viewer.__items[2]
bsItem.IsActive, ossItem.IsActive = false, false

------------------------------------------------------------------ 加载插件
local chunk = assert(loadfile(ADDON, 't', env))
chunk('BloodDeathKnight')

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
evt.__scripts.OnEvent(evt, 'ADDON_LOADED', 'BloodDeathKnight')
env.__inCombat = true
ENV.setNow(10)
evt.__scripts.OnEvent(evt, 'PLAYER_ENTERING_WORLD')
drain()

io.write('\n== T0 配置识别 ==\n')
local s = cmd()
check('骨盾条目已监控', s:find('骨盾(CDM): 已监控 x1', 1, true) ~= nil, s)
check('埋骨之所条目已监控', s:find('埋骨之所(CDM): 已监控 x1', 1, true) ~= nil, s)
check('未出现"缺失"', s:find('缺失', 1, true) == nil, s)
check('未出现配置提示文字', s:find('拖入冷却管理器', 1, true) == nil, s)
check('状态里能看到蒙版开关', s:find('图标蒙版: 开', 1, true) ~= nil, s)

io.write('\n== T1 骨盾亮起 → 25s 倒计时到点 ==\n')
bsItem.IsActive = true
tick(2)
check('骨盾在场，倒计时启动', cmd():find('timer: 2', 1, true) ~= nil)
check('提醒前不挂蒙版', #bsItem.__kids == 0)

resetSounds()
tick(50)                                   -- 约 25 秒
check('到点响了语音', sounds() == 1, sounds())
check('到点显示了提醒文字', env.__alertText:GetText() == '补骨盾', env.__alertText:GetText())

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
check('isActive 机密但图标在画 → 仍读作在场', cmd():find('timer: idle', 1, true) == nil)
check('未误报补盾', sounds() == 0, sounds())
check('蒙版仍在闪', ov and ov.__scripts.OnUpdate ~= nil)
bsItem.IsActive = true
tick(2)

io.write('\n== T3 掉线去抖（单拍不算掉） ==\n')
resetSounds()
bsItem.IsActive = false
tick(1)                                    -- 0.5s < DOWN_GRACE
check('掉一拍未触发提醒', sounds() == 0, sounds())
check('倒计时未被打断', cmd():find('timer: idle', 1, true) == nil)
bsItem.IsActive = true                     -- 立刻回来
tick(2)
check('瞬态回落不触发提醒', sounds() == 0, sounds())

io.write('\n== T9 帧池重建：条目瞬态消失 ==\n')
resetSounds()
local keepID = bsItem.__cooldownID
bsItem.__cooldownID = 999                  -- 池化帧被换绑给别的法术
tick(2)                                    -- 1 秒扫不到骨盾条目
check('条目不在了也不误报补盾', sounds() == 0, sounds())
check('倒计时没被清掉（空列表 = 未知，不是掉了）', cmd():find('timer: idle', 1, true) == nil)
check('换绑帧上的蒙版已撤（不留在别人图标上）', ov and ov.__alpha == 0, ov and ov.__alpha)
bsItem.__cooldownID = keepID               -- 换回来
tick(3)
check('恢复后倒计时仍在', cmd():find('timer: idle', 1, true) == nil)
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
local dump = cmd('dump')
check('诱饵帧被标为 unreadable / proven=no',
    dump:find('isActive=unreadable proven=no', 1, true) ~= nil, dump)
check('诱饵帧不产生提醒', sounds() == 0, sounds())

io.write('\n== T5 施放刷新技能 ==\n')
ossItem.IsActive = false
ossItem:Show()
ossItem:SetAlpha(1)
tick(1)
evt.__scripts.OnEvent(evt, 'UNIT_SPELLCAST_SUCCEEDED', 'player', nil, 195182)
local st = cmd()
check('施放后倒计时重置为 25s', st:find('timer: 24', 1, true) ~= nil or st:find('timer: 25', 1, true) ~= nil, st)
check('施放后蒙版清除（alpha 归零）', ov and ov.__alpha == 0, ov and ov.__alpha)
check('施放后蒙版停止脉动', ov and ov.__scripts.OnUpdate == nil)
check('施放后不再重复播报', env.__sounds and #env.__sounds == 0, #env.__sounds)

io.write('\n== T6 骨盾真正消失（战斗中） ==\n')
resetSounds()
bsItem.IsActive = false
tick(5)                                    -- 2.5s > DOWN_GRACE
check('连续消失后触发一次提醒', sounds() == 1, sounds())
check('倒计时已清空', cmd():find('timer: idle', 1, true) ~= nil)

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
check('非鲜血专精无倒计时且无蒙版', cmd():find('timer: idle', 1, true) ~= nil)
check('非鲜血专精时不打蒙版', ov and ov.__alpha == 0, ov and ov.__alpha)

io.write('\n== T10 一个条目携带两个 ID（埋骨之所的实测形态） ==\n')
-- 回归：/bdk dump 曾经"一个 ID 一行"，于是一条 spell+linked 的条目看起来像两条独立
-- 条目，会被误读成"得在两个 ID 之间挑对的那个"。诊断必须打成一行。
env.__spec = 1
env.__inCombat = false
clearLines()
tick(1)
local dd = cmd('dump')
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

io.write(('\n结果：%d 通过 / %d 失败\n'):format(passes, fails))
os.exit(fails == 0 and 0 or 1)
