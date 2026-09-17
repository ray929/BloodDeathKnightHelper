------------------------------------------------------------------
-- BoilingPoint.lua 离线冒烟测试
--   用法：lua bp_smoke.lua <BoilingPoint.lua 的绝对路径>
--
-- 覆盖的是"这门到底会不会该响的时候响、不该响的时候不响"：
--   门未认证 → 不响；override 形式的发光 → 认得；发光中的施法 → 起倒计时；
--   回声期间又攒一个 proc → 链式续窗；proc 条与回声条谁占位；触发辉光；
--   换地图重置；非鲜血专精待机；填充施法不报；诊断/拖动命令。
------------------------------------------------------------------
local ADDON = assert(arg[1], 'need path to BoilingPoint.lua')
local HERE  = (arg[0]:gsub('[^/\\]*$', ''))

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

------------------------------------------------------------------ 搭一个环境并加载模块
local function loadInto(cls, spec, lang)
    local env = ENV.install(lang or 'zhCN')
    ENV.installBP(env)
    env._G = env
    setmetatable(env, { __index = _G })
    env.__spec = spec or 1
    if cls then
        env.UnitClass = function() return 'X', cls, 1 end
    end

    -- 按 toc 的顺序加载：命令表（Commands.lua）在前，模块往它里面登记子命令
    local ROOT = ADDON:gsub('[^/\\]*$', '')
    local cmds = assert(loadfile(ROOT .. 'Commands.lua', 't', env))
    cmds('BloodDeathKnightHelper')

    local chunk = assert(loadfile(ADDON, 't', env))
    chunk('BloodDeathKnightHelper')

    local evt
    for i = 1, #ENV.frames do
        local f = ENV.frames[i]
        if f.__scripts and f.__scripts.OnEvent then evt = f end
    end
    assert(evt, 'event frame not found')
    env.__evt = evt
    function env.fire(...) return evt.__scripts.OnEvent(evt, ...) end
    function env.glowShow(id) env.fire('SPELL_ACTIVATION_OVERLAY_GLOW_SHOW', id) end
    function env.glowHide(id) env.fire('SPELL_ACTIVATION_OVERLAY_GLOW_HIDE', id) end
    function env.cast(id) env.fire('UNIT_SPELLCAST_SUCCEEDED', 'player', nil, id) end
    function env.bar() return env.findByType('StatusBar') end
    function env.panel() return env.findFrame('BloodDeathKnightBoilingPoint') end
    function env.text()
        local s = env.findByType('StatusBar')
        return s and s.Text and s.Text:GetText() or nil
    end
    -- 走的是命令表里那条真实分发路径（含帮助排版），不是测试自己搭的仿制品
    function env.cmdmsg(m) return env.BloodDeathKnightDispatch(m) end
    return env
end

local function drain(env)
    local t, out = env.__lines, {}
    for i = 1, #t do out[i] = t[i] end
    for i = #t, 1, -1 do t[i] = nil end
    return table.concat(out, '\n')
end

local RED  = { 0.77, 0.12, 0.23, 1 }   -- 回声条
local BLUE = { 0.20, 0.60, 1, 1 }      -- 触发窗口条
local function sameColor(c, want)
    if not c or not want then return false end
    for i = 1, 4 do if math.abs(c[i] - want[i]) > 0.001 then return false end end
    return true
end

------------------------------------------------------------------
io.write('\n== T0 非死亡骑士：除了 ADDON_LOADED 之外一个事件都不注册 ==\n')
local w = loadInto('WARRIOR', 1)
w.fire('ADDON_LOADED', 'BloodDeathKnightHelper')
local wev = w.__evt.__events or {}
check('非 DK 只挂了 ADDON_LOADED', wev.ADDON_LOADED == true
    and wev.SPELL_ACTIVATION_OVERLAY_GLOW_SHOW == nil
    and wev.UNIT_SPELLCAST_SUCCEEDED == nil)
w.glowShow(50842)
check('非 DK 时发光不建界面', w.panel() == nil)

------------------------------------------------------------------
io.write('\n== T1 加载 / 门未认证 ==\n')
local e = loadInto('DEATHKNIGHT', 1)
e.fire('ADDON_LOADED', 'BloodDeathKnightHelper')
local ev = e.__evt.__events or {}
check('注册了高亮事件', ev.SPELL_ACTIVATION_OVERLAY_GLOW_SHOW == true)
check('注册了施法成功事件', ev.UNIT_SPELLCAST_SUCCEEDED == true)
check('注册了换地图事件', ev.PLAYER_ENTERING_WORLD == true)
check('命令表里登记了血沸的命令（三条可见 + 一条隐藏的 debug）', (function()
    local list = e.BloodDeathKnightCmd
    if not list then return false end
    local visible, hidden = 0, 0
    for i = 1, #list do
        if list[i].hidden then hidden = hidden + 1 else visible = visible + 1 end
    end
    return visible == 3 and hidden == 1
end)(), e.BloodDeathKnightCmd and #e.BloodDeathKnightCmd)

e.cast(50842)
check('门未认证时施法什么都不触发（不是每发都报）', e.panel() == nil)

drain(e)
e.cmdmsg('debug')
local out = drain(e)
check('诊断输出含基础 ID 行', out:find('血沸基础 ID', 1, true) ~= nil, out)
check('诊断点名"门未认证"', out:find('NO —— 在游戏点亮一次血沸之前', 1, true) ~= nil, out)
check('诊断显示这一发被拦下', out:find('拦下', 1, true) ~= nil, out)
check('诊断为"一条高亮都没有"', out:find('一条都没有', 1, true) ~= nil, out)

------------------------------------------------------------------
io.write('\n== T2 override 形式的发光：认得出来 ==\n')
e.__override[50842] = 61111                      -- 触发态用 override ID 报高亮
e.__base[61111] = 50842
e.overlay(61111, true)
e.glowShow(61111)
local panel = e.panel()
check('发光后建了界面', panel ~= nil)
check('条已显示', panel and panel.__shown == true)
check('无回声时占位的是触发窗口条（蓝色）', sameColor(e.bar().__barColor, BLUE), e.bar().__barColor)
check('触发窗口按 15 秒起算', e.text() == '15', e.text())

------------------------------------------------------------------
io.write('\n== T3 发光中的施法 → 3 秒回声倒计时 ==\n')
e.cast(50842)
check('回声窗口占位（红色）', sameColor(e.bar().__barColor, RED), e.bar().__barColor)
check('倒计时从 3 秒起', e.text() == '3', e.text())
check('界面可见', e.panel().__shown == true)

e.runTickers(5)                                  -- +0.5s
check('0.5 秒后读作 3', e.text() == '3', e.text())
e.runTickers(10)                                 -- 共 1.5s
check('1.5 秒后读作 2', e.text() == '2', e.text())

------------------------------------------------------------------
io.write('\n== T4 触发辉光：回声窗口里血沸还亮着 ==\n')
local ants
for i = 1, #ENV.frames do
    if ENV.frames[i].__bdkAnts then ants = ENV.frames[i] end
end
check('辉光宿主上挂了跑马灯', ants ~= nil)
if ants then
    check('跑马灯容器已显示', ants.__bdkAnts.frame.__shown == true)
    local seg = ants.__bdkAnts.edges[1] and ants.__bdkAnts.edges[1].segs[1]
    check('虚线动画在播', seg and seg.ag:IsPlaying() == true)
    check('虚线是金色', seg and sameColor({ seg.vr, seg.vg, seg.vb, seg.va }, { 1, 0.82, 0, 1 }))
    check('辉光宿主压在内容之上', (ants.__level or 0) > (e.panel().__level or 0),
        (ants.__level or 0) .. ' vs ' .. (e.panel().__level or 0))
end

------------------------------------------------------------------
io.write('\n== T5 回声落地 → 让位给触发窗口条 ==\n')
e.runTickers(30)                                 -- 共 4.5 秒，回声已落地
check('回声结束后条仍可见', e.panel().__shown == true)
check('接棒的是触发窗口条（蓝色）', sameColor(e.bar().__barColor, BLUE), e.bar().__barColor)
check('读数是 proc 剩余时间', e.text() == '11', e.text())

------------------------------------------------------------------
io.write('\n== T6 链式叠加：回声期间又落一个 proc ==\n')
e.cast(50842)                                    -- 第二发强化血沸
check('第二次回声从 3 秒起', e.text() == '3', e.text())
e.glowHide(61111)                                -- proc 被花掉，发光熄灭
e.glowShow(61111)                                -- 回声还在空中，又亮起来 = 有新 proc 攒着
-- 31 拍 = 3.1 秒。故意多走一拍：只走 30 拍的话受控时钟会正好卡在到期时刻
-- （累计误差 1e-14，条读成"1"），测的是浮点而不是链式叠加。
e.runTickers(31)
check('到期没有熄屏，直接续进下一个窗口', e.panel().__shown == true)
check('续窗后仍是回声条（红色）', sameColor(e.bar().__barColor, RED), e.bar().__barColor)
check('续窗后读数回到 3', e.text() == '3', e.text())

------------------------------------------------------------------
io.write('\n== T7 换地图：清回声，proc 重开一个完整窗口 ==\n')
ENV.setNow(ENV.now() + 10)                       -- 中途过一会儿
e.fire('PLAYER_ENTERING_WORLD')
check('换地图后假回声不残留（红色没了）', not sameColor(e.bar().__barColor, RED), e.bar().__barColor)
check('发光仍亮 → 触发窗口重开 15 秒', e.text() == '15', e.text())

e.overlay(61111, false)
e.glowHide(61111)                                -- proc 真的结束了
check('proc 结束后熄屏', e.panel().__shown == false)

------------------------------------------------------------------
io.write('\n== T8 填充施法不报（门是认证过的） ==\n')
e.runTickers(20)                                 -- 越过发光宽限期
e.cast(50842)
check('没有发光时的血沸不报', e.panel() == nil or e.panel().__shown == false)

------------------------------------------------------------------
io.write('\n== T9 非鲜血专精待机 ==\n')
e.__spec = 2
e.fire('PLAYER_SPECIALIZATION_CHANGED', 'player')
e.overlay(50842, true)
e.glowShow(50842)
e.cast(50842)
check('非鲜血专精：发光与施法都不起窗口', e.panel() == nil or e.panel().__shown == false)

------------------------------------------------------------------
io.write('\n== T10 命令：诊断 / 拖动预览 ==\n')
e.__spec = 1
e.overlay(50842, false)
e.glowHide(50842)
drain(e)
check('debug 命令认领', e.cmdmsg('debug') == true)
local d = drain(e)
check('诊断列出高亮记录', d:find('本会话见过的高亮', 1, true) ~= nil, d)
check('诊断列出施法记录', d:find('血沸施法', 1, true) ~= nil, d)
check('记录里能看到一次"通过"', d:find('通过', 1, true) ~= nil, d)
check('诊断里门已认证', d:find('门已认证', 1, true) ~= nil, d)
check('不认识的命令不认领', e.cmdmsg('nonsense') == false)

drain(e)
check('bp test 命令认领', e.cmdmsg('bp test') == true)
check('预览态打印了提示', drain(e):find('预览/拖动', 1, true) ~= nil)
check('预览态强制画一个假回声', e.panel().__shown == true and e.text() == '2', e.text())
e.cmdmsg('bp test')
check('再执行一次退出预览并熄屏', e.panel().__shown == false)

------------------------------------------------------------------
io.write('\n== T10b 拖动定位：只有预览能拖，落点存盘 ==\n')
local fr = e.panel()
check('承载帧可移动 / 注册的是右键', fr.__movable == true and fr.__dragBtn == 'RightButton',
    tostring(fr.__dragBtn))

-- 平时（战斗里漂着的那条）必须拖不动：无选项之后，"预览"就是唯一的解锁开关
fr.__moving = nil
fr.__scripts.OnDragStart(fr)
check('不在预览时拖不起来', fr.__moving ~= true)
check('不在预览时不接收鼠标（不吃点击）', fr.__mouse ~= true, tostring(fr.__mouse))

e.cmdmsg('bp test')
check('预览态开始接收鼠标', fr.__mouse == true, tostring(fr.__mouse))
fr.__scripts.OnDragStart(fr)
check('预览态右键能拖起来', fr.__moving == true)

-- 落点：帧中心 (120,-240) 相对 UIParent 中心 (0,0) → 偏移就是它自己
fr.__center = { 120, -240 }
fr.__scripts.OnDragStop(fr)
local pos = e.BloodDeathKnightDB and e.BloodDeathKnightDB.boilingPoint
check('落点写进 SavedVariables',
    pos and pos.x == 120 and pos.y == -240,
    pos and (tostring(pos.x) .. ',' .. tostring(pos.y)))
check('松手能停住移动', fr.__stoppedMoving == true)

e.cmdmsg('bp test')
check('退出预览后重新锁住鼠标', fr.__mouse ~= true, tostring(fr.__mouse))

-- 重登：位置要读回来（否则每次上线都得重拖）
local e2 = loadInto('DEATHKNIGHT', 1)
e2.BloodDeathKnightDB = e2.BloodDeathKnightDB or {}
e2.BloodDeathKnightDB.boilingPoint = { x = -75, y = 210 }
e2.fire('ADDON_LOADED', 'BloodDeathKnightHelper')
e2.cmdmsg('bp test')
local fr2 = e2.panel()
fr2.__center = { -75, 210 }
fr2.__scripts.OnDragStop(fr2)
check('重登时旧位置被读回（拖走再松手仍是原值）',
    e2.BloodDeathKnightDB.boilingPoint.x == -75
        and e2.BloodDeathKnightDB.boilingPoint.y == 210,
    tostring(e2.BloodDeathKnightDB.boilingPoint.x))

------------------------------------------------------------------
io.write('\n== T10c 条宽 / 条上数字 命令 ==\n')
drain(e)
check('条宽命令认领', e.cmdmsg('bp width 240') == true)
check('条宽立刻生效', math.abs(e.bar().__w - 240) < 0.01, e.bar().__w)
check('打印了新宽度', drain(e):find('240', 1, true) ~= nil)
check('中文别名认领并生效',
    e.cmdmsg('bp width 200') == true and math.abs(e.bar().__w - 200) < 0.01, e.bar().__w)
drain(e)
e.cmdmsg('bp width 5')
check('低于下限夹到 20（不是拒绝）', math.abs(e.bar().__w - 20) < 0.01, e.bar().__w)
check('夹紧时说清了原因', drain(e):find('夹到范围', 1, true) ~= nil)
e.cmdmsg('bp width 9999')
check('高于上限夹到 400', math.abs(e.bar().__w - 400) < 0.01, e.bar().__w)
drain(e)
e.cmdmsg('bp width abc')
check('非数字只给用法、不动宽度',
    drain(e):find('用法', 1, true) ~= nil and math.abs(e.bar().__w - 400) < 0.01, e.bar().__w)
drain(e)
e.cmdmsg('bp width')
check('缺参数只给用法', drain(e):find('用法', 1, true) ~= nil)
check('条宽写进 SavedVariables',
    e.BloodDeathKnightDB.boilingPoint and e.BloodDeathKnightDB.boilingPoint.width == 400,
    e.BloodDeathKnightDB.boilingPoint and tostring(e.BloodDeathKnightDB.boilingPoint.width))

check('数字开关认领', e.cmdmsg('bp text off') == true)
check('关掉后条上的数字不画', e.bar().Text.__shown == false, tostring(e.bar().Text.__shown))
check('不带参数 = 直接切换回来',
    e.cmdmsg('bp text') == true and e.bar().Text.__shown == true, tostring(e.bar().Text.__shown))
check('中文 off 也能关', e.cmdmsg('bp text 关') == true and e.bar().Text.__shown == false)
check('中文 on 也能开', e.cmdmsg('bp text 开') == true and e.bar().Text.__shown == true)
check('手滑的 bp textoff 不认（不许读成 bp text off）', e.cmdmsg('bp textoff') == false)
e.cmdmsg('bp text off')
check('数字开关写进 SavedVariables',
    e.BloodDeathKnightDB.boilingPoint and e.BloodDeathKnightDB.boilingPoint.barText == false,
    e.BloodDeathKnightDB.boilingPoint and tostring(e.BloodDeathKnightDB.boilingPoint.barText))
drain(e)
e.cmdmsg('debug')
check('诊断里能看到条宽与数字状态',
    drain(e):find('400×16', 1, true) ~= nil, '诊断没打印条宽')

-- 重登：三样显示设置都要从存档恢复（宽度还会在读取时夹紧）
local e4 = loadInto('DEATHKNIGHT', 1)
e4.BloodDeathKnightDB = { boilingPoint = { x = 0, y = -160, width = 300, barText = false } }
e4.fire('ADDON_LOADED', 'BloodDeathKnightHelper')
e4.fire('PLAYER_ENTERING_WORLD')
check('重登读回条宽 300',
    e4.bar() and math.abs(e4.bar().__w - 300) < 0.01, e4.bar() and e4.bar().__w)
check('重登读回"不显示数字"', e4.bar() and e4.bar().Text.__shown == false)

local e5 = loadInto('DEATHKNIGHT', 1)
e5.BloodDeathKnightDB = { boilingPoint = { width = 9999, barText = 'yes' } }
e5.fire('ADDON_LOADED', 'BloodDeathKnightHelper')
e5.fire('PLAYER_ENTERING_WORLD')
check('旧档里的越界宽度被夹回 400',
    e5.bar() and math.abs(e5.bar().__w - 400) < 0.01, e5.bar() and e5.bar().__w)
check('旧档里的非布尔值被忽略（数字保持默认开）',
    e5.bar() and e5.bar().Text.__shown == true)

-- 非鲜血 DK：设置照存，但不在别人客户端里建帧
local w2 = loadInto('WARRIOR', 1)
w2.fire('ADDON_LOADED', 'BloodDeathKnightHelper')
w2.cmdmsg('bp width 300')
check('非鲜血 DK：设置照样存盘',
    w2.BloodDeathKnightDB.boilingPoint and w2.BloodDeathKnightDB.boilingPoint.width == 300,
    w2.BloodDeathKnightDB.boilingPoint and tostring(w2.BloodDeathKnightDB.boilingPoint.width))
check('非鲜血 DK：不为一个改设置的动作建帧', w2.panel() == nil)

------------------------------------------------------------------
io.write('\n== T10d 预览态下改设置，预览条当场跟着变 ==\n')
-- 预览条不是一张静态截图：它和正常那条共用同一个 frame/bar，所以改宽度、关数字
-- 都会立刻画在屏幕上那条身上（"一边拖一遍调"就是这么用的）。
local pv = loadInto('DEATHKNIGHT', 1)
pv.fire('ADDON_LOADED', 'BloodDeathKnightHelper')
pv.fire('PLAYER_ENTERING_WORLD')
pv.cmdmsg('bp test')
check('预览条出现（假剩 2 秒）', pv.panel().__shown == true and pv.text() == '2', pv.text())
pv.cmdmsg('bp width 300')
check('预览中改宽度：屏幕上的条当场变宽', math.abs(pv.bar().__w - 300) < 0.01, pv.bar().__w)
check('预览中改宽度：没被踢出预览、读数还在',
    pv.panel().__shown == true and pv.text() == '2', pv.text())
pv.cmdmsg('bp text 关')
check('预览中关数字：条上的数字当场消失', pv.bar().Text.__shown == false)
check('预览中关数字：条本身还在', pv.panel().__shown == true)
pv.cmdmsg('bp text 开')
check('预览中再打开：数字回来，仍是 2', pv.bar().Text.__shown == true and pv.text() == '2')
pv.cmdmsg('bp test')
check('退出预览熄屏，不留一个假回声', pv.panel().__shown == false)

------------------------------------------------------------------
io.write('\n== T10e 命令表：/bdk 帮助里的血沸条目 ==\n')
drain(e)
local help = (e.cmdmsg('') and drain(e)) or ''
check('帮助里列出血沸三条',
    help:find('/bdk bp test', 1, true) ~= nil
        and help:find('/bdk bp width', 1, true) ~= nil
        and help:find('/bdk bp text', 1, true) ~= nil, help)
check('帮助里命令与说明是两种颜色',
    help:find('|cffffd100/bdk', 1, true) ~= nil and help:find('|cff9d9d9d', 1, true) ~= nil, help)
check('帮助里没有 debug（隐藏命令）', help:find('debug', 1, true) == nil, help)
check('宽度那条带了占位词"数字"', help:find('/bdk bp width 数字', 1, true) ~= nil, help)

-- 说明列按"显示宽度"对齐 —— 只有含汉字的那一行能验证这件事：两个汉字 6 字节却只占
-- 4 列，所以它补的空格比 ASCII 行少 2 个，说明列的字节位置正好比 ASCII 行靠后 2。
local function descCol(text, label)
    for line in text:gmatch('[^\n]+') do
        if line:find(label, 1, true) then return line:find('|cff9d9d9d', 1, true) end
    end
end
local colAscii = descCol(help, '/bdk bp test')
local colCjk   = descCol(help, '/bdk bp width')
check('含汉字的命令行按显示宽度补空格（不是按字节数）',
    colAscii ~= nil and colCjk == colAscii + 2,
    tostring(colAscii) .. ' / ' .. tostring(colCjk))

------------------------------------------------------------------
io.write('\n== T11 英文字面 ==\n')
local en = loadInto('DEATHKNIGHT', 1, 'enUS')
en.fire('ADDON_LOADED', 'BloodDeathKnightHelper')
en.cmdmsg('debug')
local eout = drain(en)
check('英文诊断用英文', eout:find('Blood Boil base id', 1, true) ~= nil, eout)

io.write(('\n结果：%d 通过 / %d 失败\n'):format(passes, fails))
os.exit(fails == 0 and 0 or 1)
