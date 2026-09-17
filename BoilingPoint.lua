--==============================================================================
-- BoilingPoint.lua —— 血沸（Blood Boil 50842）回声倒计时
--
-- 移植自 KiraUI-Plugin_BoilingPoint.lua（同一作者的实现），按本仓库约定独立成模块：
--   * 去掉 KiraUI 的 ns 框架依赖，改成插件自己的最小实现（像素跑马灯辉光一起搬过来）；
--   * 去掉全部选项：所有功能常开，颜色用默认值 —— 多重颜色指回声条 / 触发条 /
--     触发辉光 / 边框各一色；
--   * 全局标识符一律 BloodDeathKnight 前缀，帧名 BloodDeathKnightBoilingPoint。
--
-- 监控的到底是什么（不是"buff 在不在"，是"回声什么时候落地"）
-- -----------------------------------------------------------------------------
-- Boiling Point 触发下，下一发血沸增伤 50%，并在 3 秒后再"回声"打一次。值得倒计时
-- 的从来不是身上那个 proc —— 是"强化血沸出手"到"回声落地"之间的这 3 秒，而这段
-- 窗口游戏里根本没有任何光环可读。
--
-- 为什么既不靠 12.1 光环引擎、也不读 buff ID
-- -----------------------------------------------------------------------------
-- v1 用 AuraContainer 白名单盯着那个 buff：它只能回答"我有没有触发"，回答不了
--   "回声什么时候落地"；容器只能画一个"存在"的光环，这段窗口表达不出来。
-- v2 自己拿时钟，但仍按 ID 读光环判断这一发是不是强化版 —— 战斗中光环是 secret，
--   于是要靠"读不到就放行"的信任启发式兜底，等于随时可能退化成每发都报。
--   （本仓库的铁律：战斗监控不读光环数据。）
-- v3 改问游戏已经画在屏幕上的那个问题 —— 血沸图标此刻在发光吗？
--     glow on  -> 这一发是强化版 -> 起倒计时
--     glow off -> 普通填充         -> 不管
--   技能触发高亮是明文数据（副本、钥匙里都是），不需要任何 buff ID，暴雪以后改
--   触发条件这边也不用跟着改。
--
-- 触发器是"施法成功"
-- -----------------------------------------------------------------------------
-- 自己的 UNIT_SPELLCAST_SUCCEEDED 同样明文可读；倒计时从施法成功那一刻纯算术推出，
-- 不会漂。
--
-- 发光门会自己校准（原版踩过的坑，照抄）
-- -----------------------------------------------------------------------------
-- 高亮事件报来的 ID 不保证是基础 ID —— 触发态会报 override。所以两侧都过
-- C_Spell.GetBaseSpell，和暴雪自己的冷却管理器同一套规则。在亲眼看到游戏把血沸
-- 点亮过之前，本模块什么都不触发；第一次真的亮过之后，门就算"已认证"。
-- 原版这里曾有个 fail-open：只比基础 ID ⇒ override 永远匹配不上 ⇒ 门永远不认证
-- ⇒ 每一发填充都报 3 秒倒计时。现在 override 两个方向都能解析，"门未认证"就等于
-- "发光真的读不到"，而每发都报比不报更糟。`/bdk debug` 打印游戏点亮过的每一个 ID。
--
-- 位置 / 条宽 / 条上的数字
-- -----------------------------------------------------------------------------
-- 位置：自由屏幕位置，预览模式下右键拖动。三样都写 SavedVariables（BloodDeathKnightDB.
-- boilingPoint）—— 它们是"显示成什么样"，不是选项，不给它落盘就只能每次上线重设一遍。
--   /bdk bp test            预览 + 右键拖动定位（再执行一次退出）
--   /bdk bp width 20-400    条宽，范围外夹回来而不是拒绝
--   /bdk bp text on|off     条中央的倒计时数字，不带参数 = 切换
-- 诊断：/bdk debug（隐藏命令，不进帮助）。
--==============================================================================

local ADDON_NAME = ...

local _G = _G
local CreateFrame = CreateFrame
local UIParent = UIParent
local GetTime = GetTime
local issecretvalue = _G.issecretvalue
local pcall = pcall
local mceil, mfloor = math.ceil, math.floor
local mmax, mmin = math.max, math.min
local format = string.format

---------------------------------------------------------------- 常量
local BP_SPELL = 50842   -- 血沸 Blood Boil：既是要看的那个发光，也是要计时的那一发
local BP_ICON  = 237513  -- 固定文件 ID：法术贴图加载期还没缓存，首次问会返回 nil
                         -- （那就是"图标永远空白"的来路）

local DURATION   = 3     -- 回声延迟。常量而非设置：实战里不会变，猜错了比不画更糟
local GLOW_GRACE = 1.0   -- 发光在 proc 被消耗时就灭了，可能早于施法成功事件到达 ——
                         -- 所以"发光刚灭这么点儿时间内的施法"照样算作强化版
local CROP       = 0.08  -- 常规图标边框裁剪
local MAX_QUEUE  = 3     -- 链式叠加的深度上限
local PROC_SECONDS = 15  -- proc 自身窗口的长度，触发条按它缩放

-- 条宽的可调范围（与上游滑杆的 20–400 一致）。下限是"再短就看不出排空方向"，
-- 上限是"再宽就横穿半个屏幕"，都不是随便定的 —— 范围外的输入会被夹进来而不是拒绝，
-- 因为玩家敲 /bdk bp width 500 显然是想"宽一点"，回一句用法错误什么都不做更差。
local BAR_MIN, BAR_MAX = 20, 400

---------------------------------------------------------------- 设置（写死，无选项）
-- 原版这些是设置项；这里全部常开、颜色取默认值。字段名保持原样，方便和上游对照。
local CFG = {
    enable = true,            -- 装了就开（职业 / 专精门仍然生效）
    x = 0, y = -160,          -- 相对屏幕中心的偏移，预览拖动后存盘
    strata = 'MEDIUM',
    durSize = 0,              -- 倒计时字号，0 = 按短边自动

    border    = { 0.77, 0.12, 0.23, 1 },  -- DK 红：图标边框 / 回声条边框
    textColor = { 1, 1, 1, 1 },

    barLength    = 160,       -- 条长（沿排空方向）；/bdk bp width 可调，改完存盘
    barThickness = 16,        -- 条厚（不可调：字号规则跟它走，动了会连带改数字大小）
    barColor     = { 0.77, 0.12, 0.23, 1 },  -- 回声倒计时：红
    barBg        = { 0, 0, 0, 0.55 },
    barText      = true,      -- 条中央的倒计时数字；/bdk bp text 可开关，改完存盘

    procBar   = true,                      -- 触发窗口条：回声条不占位时显示
    procColor = { 0.20, 0.60, 1, 1 },      -- 触发窗口：蓝

    procGlow          = true,              -- 触发期在条上跑马灯
    procGlowColor     = { 1, 0.82, 0, 1 }, -- 触发辉光：金
    procGlowThickness = 2,

    showSwipe = true,
}

-- 只有像素跑马灯一种辉光样式（原版还有个 shape 洗色）。这里不搬 shape：
-- 需要哪个再搬哪个，多一种样式就多一条没人走的代码路径。
local GLOW_TYPE = 'pixel'

---------------------------------------------------------------- 工具
local function secret(v) return issecretvalue and issecretvalue(v) end
local function Round(v) return mfloor(v + 0.5) end

-- 文案语言强制跟随客户端语种：没有语言开关了（与 BoneShield 的 ApplyLang 同一条规矩）。
-- 每次现取，不做缓存 —— 缓存了在换客户端语种之后就会不同步。
local function IsZh()
    return (GetLocale() or ''):sub(1, 2) == 'zh'
end
local function T(zh, en) if IsZh() then return zh end return en end
local function Tag()
    if IsZh() then return '|cff71d5ff[鲜血死亡骑士]|r' end
    return '|cff71d5ff[BloodDeathKnight]|r'
end

local IsSpellOverlayed = _G.C_SpellActivationOverlay
    and _G.C_SpellActivationOverlay.IsSpellOverlayed
    or _G.IsSpellOverlayed -- 更老客户端的名字

-- 文字用哪个字体：STANDARD_TEXT_FONT 在中文客户端上就是带中文字形的那个字体，
-- FRIZQT__.TTF 不是。这里只画数字，但规矩照旧，免得以后加中文文案踩坑。
local FONT = _G.STANDARD_TEXT_FONT
local BAR_TEXTURE = 'Interface\\Buttons\\WHITE8X8'

---------------------------------------------------------------- 职业 / 专精门
-- 血沸是鲜血天赋的工具，所以这里不只是职业门，还看专精。职业不会变，首次明文读到
-- 就缓存；专精会变，每次现问，并在 PLAYER_SPECIALIZATION_CHANGED 上重跑门。
-- 读到 secret = 放行：这里 fail closed 会把图标从最需要它的人眼前藏起来，是更糟的错。
local isDK
local function IsDeathKnight()
    if isDK == nil then
        local ok, _, cls = pcall(_G.UnitClass, 'player')
        if not ok then return true end
        if secret(cls) then return true end
        if cls then isDK = (cls == 'DEATHKNIGHT') end
    end
    return isDK ~= false
end

local function IsBlood()
    if not IsDeathKnight() then return false end
    local spec
    local CSI = _G.C_SpecializationInfo
    if CSI and CSI.GetSpecialization then
        local ok, v = pcall(CSI.GetSpecialization)
        if ok then spec = v end
    elseif _G.GetSpecialization then
        local ok, v = pcall(_G.GetSpecialization)
        if ok then spec = v end
    end
    if secret(spec) then return true end
    return spec == 1 -- 鲜血
end

---------------------------------------------------------------- 法术身份：基础 ID + override
-- 原版修掉的那个 bug：拿收到的 ID 去比裸的 50842，而触发态会报 override ID —— 于是
-- 发光永远匹配不上、门永远"未认证"、而未认证就等于每发都触发。暴雪的冷却管理器同样
-- 处理这一点（用条目"当前"法术去比高亮事件）；C_Spell.GetBaseSpell 把任何 override
-- 映射回基础 ID、没有 override 时原样返回，一次调用覆盖两个方向，且标注
-- SecretArguments = AllowedWhenTainted，插件可调。C_SpellBook.FindBaseSpellByID 是
-- 更老客户端的退路。
local function BaseOf(id)
    if type(id) ~= 'number' then return nil end
    local CS = _G.C_Spell
    if CS and CS.GetBaseSpell then
        local ok, v = pcall(CS.GetBaseSpell, id)
        if ok and type(v) == 'number' and not secret(v) then return v end
    end
    local SB = _G.C_SpellBook
    local find = (SB and SB.FindBaseSpellByID) or _G.FindBaseSpellByID
    if find then
        local ok, v = pcall(find, id)
        if ok and type(v) == 'number' and not secret(v) then return v end
    end
    return nil
end

-- 血沸"当前"的 ID：有 override 时是 override，否则是基础 ID。现问不缓存 ——
-- override 只在 proc 期间存在，而那正是我们关心的那一刻。
local function LiveID()
    local CS = _G.C_Spell
    if CS and CS.GetOverrideSpell then
        local ok, v = pcall(CS.GetOverrideSpell, BP_SPELL)
        if ok and type(v) == 'number' and not secret(v) then return v end
    end
    local SB = _G.C_SpellBook
    local find = (SB and SB.FindSpellOverrideByID) or _G.FindSpellOverrideByID
    if find then
        local ok, v = pcall(find, BP_SPELL)
        if ok and type(v) == 'number' and not secret(v) then return v end
    end
    return BP_SPELL
end

local function IsBloodBoil(id)
    if id == BP_SPELL then return true end
    if type(id) ~= 'number' then return false end
    if BaseOf(id) == BP_SPELL then return true end
    return LiveID() == id
end

---------------------------------------------------------------- 发光门
local glowOn   = false
-- 初值必须是"从来没有发光过"，不能是 0：0 在客户端刚起的头几秒里会被下面那条
-- GLOW_GRACE 判成"刚刚还亮着"，于是入门的第一发填充就白报一个倒计时。上游那份
-- 写的是 0，本仓库改成不可能成立的负值 —— "从没见过"就应该是"从没见过"。
local glowSeen = -1e9  -- 最近一次确知发光还亮着的时刻
local glowEver = false -- 游戏到底有没有为我们点亮过血沸？

-- 只作诊断：本会话游戏点亮过的每一个法术，是不是我们的都记。这门要是抽风，
-- 唯一值得回答的问题就是"游戏点亮的到底是哪个 ID"，而在游戏外面没有别的办法回答。
local glowLog, glowLogN = {}, 0
local castLog, castLogN = {}, 0
local function Log(t, n, entry)
    n = n + 1
    t[(n - 1) % 12 + 1] = entry
    return n
end

-- 有实时查询时以它为准：它挺得过丢事件，重载之后也立刻正确（那时我们自己的标志位
-- 什么都不知道）。两个名字都问，因为注册进高亮表里的可能是其中任意一个。
local function GlowLive()
    if not IsSpellOverlayed then return nil end
    local seenNil = true
    local live = LiveID()
    for _, id in ipairs(live ~= BP_SPELL and { BP_SPELL, live } or { BP_SPELL }) do
        local ok, v = pcall(IsSpellOverlayed, id)
        if ok and not secret(v) then
            seenNil = false
            if v then return true end
        end
    end
    if seenNil then return nil end
    return false
end

-- true = 这一发当强化版处理
local function GlowGate()
    local live = GlowLive()
    if live then
        glowEver, glowOn, glowSeen = true, true, GetTime()
        return true
    end
    if glowOn then return true end
    if (GetTime() - glowSeen) <= GLOW_GRACE then return true end
    -- 从没见过游戏点亮这个法术：什么都不触发。
    -- （原来是 fail OPEN，理由是"ID 写错顶多静默失效，多画一个图标至少看得见"。
    --   那个理由代价更大：override 报的 ID 永远匹配不上基础 ID，门永远不认证，
    --   于是每一发填充都报。现在 override 双向可解析，门未认证就意味着发光真的
    --   读不到 —— 而每发都报比不报更糟。`/bdk debug` 会打印每个被点亮的 ID。）
    return false
end

---------------------------------------------------------------- 状态（全是明文数字，全是自己的）
local expiresAt = 0
local procUntil = 0     -- proc 自身窗口：你还有多久能把它花掉
local queued = 0        -- 回声进行中又落下的 proc，买到的额外 3 秒窗口
local preview
local frame, btn, bar, glowHost
local ticker

local function Active() return expiresAt > 0 and expiresAt > GetTime() end

-- 触发条只在回声条不占位时出现。两者之间回声是更硬的死线（它已经在空中了），
-- 所以永远优先占位。
local function ProcActive()
    if not CFG.procBar then return false end
    return procUntil > 0 and procUntil > GetTime()
end

---------------------------------------------------------------- 界面
local ApplySettings -- 前置声明
local SaveCfg       -- 前置声明（拖动落点 / 条宽 / 数字开关都要落盘，实现放在文件后半段）

local function EnsureFrame()
    if frame then return end
    frame = CreateFrame('Frame', 'BloodDeathKnightBoilingPoint', UIParent)
    frame:SetFrameStrata('MEDIUM')
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(false)
    frame:RegisterForDrag('RightButton')
    frame:SetScript('OnDragStart', function(self)
        if not preview then return end   -- 只有预览模式才允许拖（无选项，锁定检查并进这里）
        self:StartMoving()
    end)
    frame:SetScript('OnDragStop', function(self)
        self:StopMovingOrSizing()
        local cx, cy = self:GetCenter()
        local ux, uy = UIParent:GetCenter()
        if cx and ux then
            CFG.x = Round(cx - ux)
            CFG.y = Round(cy - uy)
            SaveCfg()
        end
        ApplySettings()
    end)

    btn = CreateFrame('Frame', nil, frame)
    btn.border = btn:CreateTexture(nil, 'BACKGROUND')
    btn.border:SetAllPoints()

    btn.Icon = btn:CreateTexture(nil, 'ARTWORK')
    btn.Icon:SetPoint('TOPLEFT', 1, -1)
    btn.Icon:SetPoint('BOTTOMRIGHT', -1, 1)
    btn.Icon:SetTexture(BP_ICON)

    -- 只作装饰：数字由我们自己的时钟驱动，所以扫描被藏起来或不被支持都不会
    -- 把倒计时弄丢。反着走 —— 回声还在路上时图标是干净的，落地时才盖满，
    -- 和 Buff Watch / Ready Check 的扫法一致。
    --
    -- 注意：条形态下 btn 本身是 Hide 的，所以这条扫描在屏幕上其实看不见（原版
    -- 就是这么写的，此处照搬不动）。留着是因为切换到图标形态的成本是零，
    -- 删掉反而丢一个可用的退路。
    btn.Cooldown = CreateFrame('Cooldown', nil, btn, 'CooldownFrameTemplate')
    btn.Cooldown:SetAllPoints()
    btn.Cooldown:SetDrawEdge(false)
    btn.Cooldown:SetDrawBling(false)
    btn.Cooldown:SetReverse(true)
    if btn.Cooldown.SetHideCountdownNumbers then btn.Cooldown:SetHideCountdownNumbers(true) end
    btn.Cooldown.noCooldownCount = true -- 别让 OmniCC 之类往上写数字

    btn.Text = btn.Cooldown:CreateFontString(nil, 'OVERLAY')
    btn.Text:SetPoint('CENTER')

    -- 条形态。和图标一起建而不是二选一：两个都很便宜，而承载位置和拖动的帧
    -- 两种情况都是同一个对象。
    bar = CreateFrame('StatusBar', nil, frame)
    bar:SetStatusBarTexture(BAR_TEXTURE)
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(1)
    bar.bg = bar:CreateTexture(nil, 'BACKGROUND')
    bar.bg:SetAllPoints()
    bar.border = bar:CreateTexture(nil, 'BACKGROUND', nil, -1)
    bar.border:SetPoint('TOPLEFT', -1, 1)
    bar.border:SetPoint('BOTTOMRIGHT', 1, -1)
    bar.Text = bar:CreateFontString(nil, 'OVERLAY')
    bar.Text:SetPoint('CENTER')
    bar:Hide()

    -- 辉光需要自己的宿主帧，而且必须压在内容之上。
    -- 共享的像素辉光会把虚线钉在它拿到的那一帧的层级上（PinToOwnerLevel）：交给
    -- 容器帧，虚线就落在容器的层级 —— 在 btn 和 bar 之下，而这两个又一个不落地
    -- 铺满不透明边框/底色。辉光跑得好好的，就是看不见。
    -- 所以给它一个刻意坐在两者之上的宿主，且层级每次 apply 都重新压一遍。
    glowHost = CreateFrame('Frame', nil, frame)
    glowHost:SetPoint('CENTER', frame, 'CENTER', 0, 0)
    glowHost:EnableMouse(false)

    frame:Hide()
end

-- 往条里推值。unless 明确要瞬间对齐，否则走缓动：窗口打开必须 SNAP 到满 —— 缓动
-- 会看到条从上一窗结束的位置滑上来，读起来像"又加了时间"而不是"新的回声来了"。
local snapNext = false
local INTERP = _G.Enum and _G.Enum.StatusBarInterpolation
local SMOOTH = INTERP and INTERP.ExponentialEaseOut
local SNAP   = INTERP and INTERP.Immediate

local function BarSet(v, snap)
    if not bar then return end
    -- 缓动除非窗口正在打开。倒计时每秒只动十次，在 3 秒的条上肉眼可见地一顿一顿，
    -- 所以中间那段运动交给引擎，而时间本身仍然是我们的。
    local mode = snap and SNAP or SMOOTH
    if mode and pcall(bar.SetValue, bar, v, mode) then return end
    bar:SetValue(v)
end

-- 法术美术是方的，非方形的图标会被拉伸。裁长轴 —— 图标铺满整个框，不变形。
local function IconCoords(w, h)
    local l, r, t, b = CROP, 1 - CROP, CROP, 1 - CROP
    if w > h then
        local inset = (1 - h / w) * (b - t) / 2
        t, b = t + inset, b - inset
    elseif h > w then
        local inset = (1 - w / h) * (r - l) / 2
        l, r = l + inset, r - inset
    end
    return l, r, t, b
end

---------------------------------------------------------------- 像素跑马灯辉光（本地实现）
-- 从 KiraUI-Plugin_Glow.lua 的 AntsStart/AntsStop 搬来，改成模块内的本地函数。
--
-- 逐帧移动改用 C 侧 Translation 动画：没有 OnUpdate，所以将来若要挂到 12.1 那种
-- 脚本被封印的引擎控件上也能活。（本模块挂在自家的 glowHost 上，用不着这条，
-- 但既然是照搬，结构就不动。）
--
-- 让这件事成立的那条规则：蒙版必须挂在"不会动"的东西上，动画必须挂在虚线上。
-- 给动的帧做动画会平移它整棵子树 —— 蒙版跟着虚线跑，就裁不住任何东西，虚线会
-- 冲出边界堆在角上。
local ANTS_SOLID = 'Interface\\Buttons\\WHITE8X8'
local ANTS_LINES = 8
local ANTS_FREQ  = 0.25     -- 负值 = 反向
local ANTS_LENGTH = 0       -- 0 = 自动（间距的一半）

local function PinToOwnerLevel(f, owner)
    local ok, lvl = pcall(owner.GetFrameLevel, owner)
    if ok and type(lvl) == 'number' then pcall(f.SetFrameLevel, f, lvl) end
end

-- 边缘顺序：从左上顺时针；dir 是沿这条边的行进方向
local function AntsEdgeDefs(w, h, reverse)
    local e = {
        { vert = false, len = w, base = 0,         anchor = 'TOPLEFT',     sx =  1, sy =  0 },
        { vert = true,  len = h, base = w,         anchor = 'TOPRIGHT',    sx =  0, sy = -1 },
        { vert = false, len = w, base = w + h,     anchor = 'BOTTOMRIGHT', sx = -1, sy =  0 },
        { vert = true,  len = h, base = w + h + w, anchor = 'BOTTOMLEFT',  sx =  0, sy =  1 },
    }
    if reverse then
        for _, d in ipairs(e) do d.sx, d.sy = -d.sx, -d.sy end
    end
    return e
end

local function AntsStart(owner, w, h, opts)
    opts = opts or {}
    if not (w and h) or w <= 0 or h <= 0 then return end
    local st = owner.__bdkAnts
    if not st then
        st = { edges = {} }
        owner.__bdkAnts = st
        st.frame = CreateFrame('Frame', nil, owner)
    end
    PinToOwnerLevel(st.frame, owner)
    st.frame:ClearAllPoints()
    st.frame:SetPoint('CENTER', owner, 'CENTER', 0, 0)
    st.frame:SetSize(w, h)
    st.frame:Show()

    local color = opts.color or { 1, 1, 1, 1 }
    local lines = math.max(1, mfloor(opts.lines or ANTS_LINES))
    local freq = opts.freq or ANTS_FREQ
    if freq == 0 then freq = ANTS_FREQ end
    local reverse = freq < 0
    local period = 1 / math.abs(freq)              -- 跑完一圈的秒数
    local th = math.max(1, opts.thickness or 2)
    local perim = 2 * (w + h)
    local P = perim / lines                        -- 虚线起点之间的像素距离
    local dashLen = (opts.length and opts.length > 0) and opts.length or (P * 0.5)
    dashLen = math.max(1, mmin(dashLen, P))        -- 永不长过一个周期
    local step = math.max(0.001, period / lines)   -- 走完一个周期所需秒数

    -- 只有几何真的变了才重排；颜色是活的
    local sig = w .. ':' .. h .. ':' .. lines .. ':' .. period .. ':' .. th
        .. ':' .. dashLen .. ':' .. (reverse and 1 or 0)
    local rebuild = st.sig ~= sig
    st.sig = sig

    local defs = AntsEdgeDefs(w, h, reverse)
    for i = 1, 4 do
        local d = defs[i]
        local E = st.edges[i]
        if not E then
            E = { segs = {} }
            st.edges[i] = E
            -- 蒙版挂在静态帧上，绝不挂在会动的东西上。
            E.mask = st.frame:CreateMaskTexture()
            E.mask:SetTexture(ANTS_SOLID, 'CLAMPTOBLACKADDITIVE', 'CLAMPTOBLACKADDITIVE')
        end

        if rebuild then
            E.mask:ClearAllPoints()
            E.mask:SetPoint(d.anchor, st.frame, d.anchor, 0, 0)
            E.mask:SetSize(d.vert and th or d.len, d.vert and d.len or th)

            -- 这条边的图案从周长相位的当前位置起步，虚线间距跨过角落不断档
            local phase = d.base % P
            local first = -phase - P
            local count = mfloor((d.len + 2 * P) / P) + 1

            for j = 1, count do
                local s = E.segs[j]
                if not s then
                    -- 贴图和它的动画都挂在静态帧上，于是虚线在"不动的蒙版"下面移动
                    s = st.frame:CreateTexture(nil, 'OVERLAY', nil, 7)
                    s:SetTexture(ANTS_SOLID)
                    s:AddMaskTexture(E.mask)
                    s.ag = s:CreateAnimationGroup()
                    s.ag:SetLooping('REPEAT')
                    s.tr = s.ag:CreateAnimation('Translation')
                    s.tr:SetSmoothing('NONE')
                    E.segs[j] = s
                end
                s.ag:Stop()
                local o = first + (j - 1) * P
                s:SetSize(d.vert and th or dashLen, d.vert and dashLen or th)
                s:ClearAllPoints()
                if d.vert then
                    s:SetPoint(d.anchor, st.frame, d.anchor, 0, d.sy >= 0 and o or -o)
                else
                    s:SetPoint(d.anchor, st.frame, d.anchor, d.sx >= 0 and o or -o, 0)
                end
                -- 每步走一个周期然后循环：图案每 P 像素重复一次，所以回弹看不见
                s.tr:SetOffset(d.sx * P, d.sy * P)
                s.tr:SetDuration(step)
                s:Show()
            end
            for j = count + 1, #E.segs do
                E.segs[j].ag:Stop()
                E.segs[j]:Hide()
            end
            E.count = count
        end

        for j = 1, (E.count or 0) do
            local s = E.segs[j]
            if s then
                s:SetVertexColor(color[1] or 1, color[2] or 1, color[3] or 1, color[4] or 1)
                s:Show()
                if not s.ag:IsPlaying() then s.ag:Play() end
            end
        end
    end
end

local function AntsStop(owner)
    local st = owner.__bdkAnts
    if not st then return end
    for i = 1, 4 do
        local E = st.edges and st.edges[i]
        if E then
            for _, s in ipairs(E.segs) do
                s.ag:Stop()
                s:Hide()
            end
        end
    end
    st.frame:Hide()
end

local function GlowStart(owner, w, h, color, thickness)
    AntsStart(owner, w, h, {
        color = color,
        thickness = thickness,
        lines = ANTS_LINES,
        freq = ANTS_FREQ,
        length = ANTS_LENGTH,
    })
end

local function GlowStop(owner)
    if not owner then return end
    AntsStop(owner)
end

---------------------------------------------------------------- 触发辉光
-- 血沸在动作条上发光时点亮条本身。窗口进行中这只有一个含义：还有一个强化版已经
-- 攒在手里、现在就能花掉、花掉就把倒计时重新开始 —— 和链式叠加是同一件事的两种读法。
-- 它只能装饰屏幕上的东西，而这个显示只在窗口期间存在。脱战时没有 proc 指示器，
-- 那是动作条本来就在做的事。
local glowingNow = false
local glowW, glowH

local function StopProcGlow()
    if not glowingNow then return end
    glowingNow = false
    if glowHost then GlowStop(glowHost) end
end

local function SetProcGlow(on, w, h)
    if not glowHost then return end
    if not on then StopProcGlow() return end
    -- 已在跑：除非它围着的东西尺寸变了，否则别动它。每拍重开 —— 或者每个链式
    -- 窗口都重开 —— 会变成频闪。
    if glowingNow then
        if w == glowW and h == glowH then return end
        StopProcGlow()
    end
    if not CFG.procGlow then StopProcGlow() return end
    GlowStart(glowHost, w, h, CFG.procGlowColor, CFG.procGlowThickness)
    glowingNow, glowW, glowH = true, w, h
end

-- 血沸现在在发光吗？实时查询答得出来就用它，答不出来（nil）才用我们自己的事件标志
-- —— 和施法门信任的是同两个来源。
local function ProcUp()
    local live = GlowLive()
    if live ~= nil then return live end
    return glowOn
end

---------------------------------------------------------------- 应用设置
ApplySettings = function()
    EnsureFrame()
    local w = CFG.barLength or 160
    local h = CFG.barThickness or 16

    frame:ClearAllPoints()
    frame:SetPoint('CENTER', UIParent, 'CENTER', CFG.x or 0, CFG.y or -160)
    frame:SetSize(w, h)
    frame:SetFrameStrata(CFG.strata or 'MEDIUM')

    btn:SetSize(w, h)
    btn:ClearAllPoints()
    btn:SetPoint('CENTER', frame, 'CENTER', 0, 0)
    btn.Icon:SetTexture(BP_ICON)
    btn.Icon:SetTexCoord(IconCoords(w, h))

    local c = CFG.border
    btn.border:SetColorTexture(c[1], c[2], c[3], c[4])

    -- 自动字号跟"短边"走：又宽又矮的图标得让数字落在高度里，不是宽度里。
    -- 条形态同理，短边就是厚度。
    local tc = CFG.textColor
    local ds = CFG.durSize or 0
    if ds <= 0 then ds = mmax(10, Round(mmin(w, h) * 0.36)) end
    btn.Text:SetFont(FONT, ds, 'OUTLINE')
    btn.Text:SetTextColor(tc[1], tc[2], tc[3], tc[4])

    bar:SetSize(w, h)
    bar:ClearAllPoints()
    bar:SetPoint('CENTER', frame, 'CENTER', 0, 0)
    bar:SetOrientation('HORIZONTAL')
    bar:SetStatusBarTexture(BAR_TEXTURE)
    local bc = CFG.barColor
    bar:SetStatusBarColor(bc[1], bc[2], bc[3], bc[4])
    local bg = CFG.barBg
    bar.bg:SetColorTexture(bg[1], bg[2], bg[3], bg[4])
    bar.border:SetColorTexture(0, 0, 0, 1)
    bar.Text:SetFont(FONT, ds, 'OUTLINE')
    bar.Text:SetTextColor(tc[1], tc[2], tc[3], tc[4])
    bar.Text:SetShown(CFG.barText ~= false)

    btn:Hide()
    bar:Show()

    glowHost:SetSize(w, h)
    local ok, lvl = pcall(frame.GetFrameLevel, frame)
    if ok and lvl then pcall(glowHost.SetFrameLevel, glowHost, lvl + 5) end
end

local function Render()
    if not frame then return end

    -- 哪个时钟在说话：回声在跑就它说话（更硬的死线，已经出手了）。触发条只在
    -- 回声腾不出位置的时候才拿到这块地方。
    local left, total, isProc
    if preview then
        left, total, isProc = 2, DURATION, false
    elseif not CFG.enable then
        left = nil
    elseif Active() then
        left, total, isProc = expiresAt - GetTime(), DURATION, false
    elseif ProcActive() then
        left, total, isProc = procUntil - GetTime(), PROC_SECONDS, true
    end

    if not left or left <= 0 then
        StopProcGlow()
        frame:Hide()
        return
    end

    -- 两个时钟共用一个条，所以颜色每次重画都重申一遍：谁在说话谁就拥有这个外观。
    local c = isProc and CFG.procColor or CFG.barColor
    bar:SetStatusBarColor(c[1], c[2], c[3], c[4])
    local bc = isProc and CFG.procColor or CFG.border
    btn.border:SetColorTexture(bc[1], bc[2], bc[3], bc[4])

    local txt = format('%d', mceil(left))
    btn.Text:SetText(txt)
    bar.Text:SetText(txt)
    -- 两个条都排空：窗口开时是满的，走完时空的 —— 和旁边那个数字同一个读法，
    -- 两者永远不可能互相矛盾。
    BarSet(left / total, snapNext)
    snapNext = false

    -- 只有回声窗口才有辉光。触发条上那圈辉光是纯同义反复：那条之所以在屏幕上正是
    -- 因为血沸在发光，点亮它不增加任何信息，只会让循环里安静的那半边变吵。
    -- 回声期间它才说了显示本身说不出来的话 —— 第一个还在空中，第二个已经攒好了。
    -- 预览时无视这条：你没法拿一个"得等出来"的 proc 去评价颜色。
    SetProcGlow(CFG.procGlow and not isProc and (preview or ProcUp()),
        frame:GetWidth(), frame:GetHeight())

    frame:Show()
    bar:Show()
end

---------------------------------------------------------------- 计时器控制
local function StopTicker()
    if ticker then ticker:Cancel() ticker = nil end
end

local function Clear()
    expiresAt = 0
    procUntil = 0
    queued = 0
    StopTicker()
    StopProcGlow()
    if btn and btn.Cooldown then
        if btn.Cooldown.Clear then btn.Cooldown:Clear() else btn.Cooldown:SetCooldown(0, 0) end
    end
    if frame and not preview then frame:Hide() end
end

-- 给当前正在跑的窗口画扫描
local function PaintSwipe(startAt)
    if not btn or not btn.Cooldown then return end
    if CFG.showSwipe then
        btn.Cooldown:SetCooldown(startAt, DURATION)
        btn.Cooldown:Show()
    else
        btn.Cooldown:Hide()
    end
end

-- 链式叠加。
-- 拉动中 proc 落在回声还在空中时，是常见情况，而它原来完全看不见：图标跑完自己
-- 的 3 秒就走，尽管动作条上一直还攒着一个强化版血沸。所以窗口进行期间到来的
-- 发光，会再排一个窗口，当前窗口一结束倒计时就顺势滚进下一个。只要有 proc 落下，
-- 链就继续。
--
-- 一次发光只买一个窗口，而且只有上升沿算数。高亮表会因为很多不是新 proc 的事
-- 重发 GLOW_SHOW（条刷新、重载、暴雪重申一次提示），每个事件都计数会把链吹成
-- 胡说八道。队列只在"发光本来就是灭的、现在亮了"时增长 —— 那才是新 proc 的样子。
--
-- 施法会消耗队列：在窗口里把 proc 花掉，重启本身就是它的窗口，不会事后再多放一发。
local Tick -- 前置声明：一副身体，谁在驱动就用谁

local function EnsureTicker()
    if ticker then return end
    -- 0.1s：够细，整秒读数不会在自己的节拍上多赖一帧。只在实际有窗口在跑时才存在。
    ticker = _G.C_Timer.NewTicker(0.1, function() Tick() end)
end

Tick = function()
    if preview then return end
    if Active() then Render() return end

    -- 回声结束了。排队的 proc 顺势滚进下一个窗口。
    if queued > 0 then
        queued = queued - 1
        -- 从"旧的到期时刻"续，而不是从现在 —— 这样窗口严格首尾相接，不会每接一次
        -- 晚一拍。除非已经过了太久（读条画面吃掉了窗口），那就干净地重新开始，
        -- 而不是把过期的秒数重放一遍。
        local from = expiresAt
        if (GetTime() - expiresAt) > DURATION then from = GetTime() end
        expiresAt = from + DURATION
        PaintSwipe(from)
        snapNext = true
        Render()
        return
    end

    -- 没有排队的。proc 还活着的话就把位置让给触发条 —— 回声落地了，但你手里
    -- 仍然攥着一个强化版。
    if expiresAt ~= 0 then
        expiresAt = 0
        if btn and btn.Cooldown then
            if btn.Cooldown.Clear then btn.Cooldown:Clear() else btn.Cooldown:SetCooldown(0, 0) end
        end
        snapNext = true   -- 交接就是一个新窗口，条要瞬间满上
    end
    if ProcActive() then Render() return end
    Clear()
end

local function Begin()
    EnsureFrame()
    ApplySettings()
    local now = GetTime()
    expiresAt = now + DURATION
    PaintSwipe(now)
    snapNext = true
    EnsureTicker()
    Render()
end

-- proc 自己的窗口。由"发光到来"打开，由"发光熄灭"关闭（你花掉了，或者它过期了）
-- —— 所以它永远不会比它描述的那个东西活得更久，不管那 15 秒允许多少。
local function BeginProc()
    if not CFG.procBar then return end
    EnsureFrame()
    ApplySettings()
    procUntil = GetTime() + PROC_SECONDS
    if not Active() then snapNext = true end
    EnsureTicker()
    Render()
end

local function EndProc()
    procUntil = 0
    if not Active() and not preview then
        if ticker then Tick() end
    end
end

-- 第二发强化血沸永远重启更新那一发的倒计时：图标只画得出一个数字，而你要等的
-- 就是你刚放出去的那个。那一发同时也花掉了 proc，所以它排过的队一并作废。
local function Start()
    queued = 0
    Begin()
end

---------------------------------------------------------------- 应用 / 预览
local function Apply()
    -- 停在这里而不是 ApplySettings 里：这是设置路径，所以改颜色/样式会重亮辉光，
    -- 而"窗口打开"（同样会 apply 设置）不会碰正在跑的那一个。
    StopProcGlow()
    if not CFG.enable or not IsBlood() then
        if not preview then Clear() end
        if frame and not preview then frame:Hide() end
        return
    end
    EnsureFrame()
    ApplySettings()
    Render()
end

local function SetPreview(state)
    if not IsBlood() then return end
    preview = state and true or false
    EnsureFrame()
    ApplySettings()
    frame:EnableMouse(preview)
    if preview then
        if btn.Cooldown then
            if CFG.showSwipe then
                btn.Cooldown:SetCooldown(GetTime() - 1, DURATION)
                btn.Cooldown:Show()
            else
                btn.Cooldown:Hide()
            end
            snapNext = true
        end
        Render()
    else
        -- 预览不许留下一个假回声：把真实状态清零再重画。
        Clear()
        Render()
    end
end

---------------------------------------------------------------- 显示设置存盘
-- 位置、条宽、要不要数字，都是"显示成什么样"，不是功能开关。跟位置同理：不落盘就
-- 只能每次上线重设一遍，那不是选项该有的样子。所以三样都放进 boilingPoint 这张表。
SaveCfg = function()
    local db = _G.BloodDeathKnightDB
    if not db then return end
    db.boilingPoint = db.boilingPoint or {}
    local p = db.boilingPoint
    p.x, p.y = CFG.x, CFG.y
    p.width = CFG.barLength
    p.barText = CFG.barText
end

local function LoadCfg()
    local db = _G.BloodDeathKnightDB
    local p = db and db.boilingPoint
    if type(p) ~= 'table' then return end
    if type(p.x) == 'number' then CFG.x = p.x end
    if type(p.y) == 'number' then CFG.y = p.y end
    -- 存档是玩家手改得到的地方（也是老版本写进去的地方）：范围外夹回来，
    -- 类型不对就干脆当没写过 —— 一个字符串把 SetShown 喂成 nil 是会报错的。
    if type(p.width) == 'number' then
        CFG.barLength = mmin(BAR_MAX, mmax(BAR_MIN, Round(p.width)))
    end
    if type(p.barText) == 'boolean' then CFG.barText = p.barText end
end

---------------------------------------------------------------- 事件
local evt = CreateFrame('Frame')

local function RegisterEvents()
    evt:RegisterEvent('PLAYER_ENTERING_WORLD')
    evt:RegisterEvent('SPELL_ACTIVATION_OVERLAY_GLOW_SHOW')
    evt:RegisterEvent('SPELL_ACTIVATION_OVERLAY_GLOW_HIDE')
    evt:RegisterUnitEvent('UNIT_SPELLCAST_SUCCEEDED', 'player')
    evt:RegisterUnitEvent('PLAYER_SPECIALIZATION_CHANGED', 'player')
end

evt:RegisterEvent('ADDON_LOADED')
evt:SetScript('OnEvent', function(_, event, arg1, _, arg3)

    if event == 'ADDON_LOADED' then
        if arg1 ~= ADDON_NAME then return end
        _G.BloodDeathKnightDB = _G.BloodDeathKnightDB or {}
        -- 非死亡骑士职业：本模块完全不启用
        local ok, _, cls = pcall(_G.UnitClass, 'player')
        if ok and cls ~= 'DEATHKNIGHT' then return end
        LoadCfg()
        RegisterEvents()
        return
    end

    if event == 'SPELL_ACTIVATION_OVERLAY_GLOW_SHOW'
        or event == 'SPELL_ACTIVATION_OVERLAY_GLOW_HIDE' then
        local spellID = arg1
        if spellID == nil or secret(spellID) then return end
        -- 先记账再匹配，是不是我们的都记：这个诊断的全部职责就是摊开游戏到底
        -- 点亮了什么，而我们拒绝掉的 ID 恰恰是那张表里最有用的一行。
        glowLogN = Log(glowLog, glowLogN, {
            id = spellID,
            show = (event == 'SPELL_ACTIVATION_OVERLAY_GLOW_SHOW'),
            mine = IsBloodBoil(spellID),
            t = GetTime(),
        })
        if not IsBloodBoil(spellID) then return end
        if event == 'SPELL_ACTIVATION_OVERLAY_GLOW_SHOW' then
            -- 只认上升沿：glowOn 本来就是 true，说明高亮在重申一个从未熄灭的提示，
            -- 不是新的 proc。
            local rising = not glowOn
            if rising and not preview
                and expiresAt > 0 and expiresAt > GetTime() then
                if queued < MAX_QUEUE then queued = queued + 1 end
            end
            glowOn, glowEver, glowSeen = true, true, GetTime()
            -- 触发条和链计数同用一个上升沿。重申的提示不许重启它，否则一次条的刷新
            -- 就会白送你一个其实并不存在的 15 秒。
            if rising and not preview and CFG.enable and IsBlood() then BeginProc() end
        else
            glowOn = false
            glowSeen = GetTime() -- 宽限窗口从熄灭这一刻起算
            -- 发光熄灭就是 proc 结束，不管你花掉了还是它跑完了。信它比信那个秒数可靠。
            if not preview then EndProc() end
        end
        return
    end

    if preview then return end

    if event == 'UNIT_SPELLCAST_SUCCEEDED' then
        if not CFG.enable then return end
        local spellID = arg3
        if spellID == nil or secret(spellID) then return end
        if not IsBloodBoil(spellID) then return end
        if not IsBlood() then return end
        local pass = GlowGate()
        castLogN = Log(castLog, castLogN, {
            id = spellID, pass = pass, proven = glowEver, t = GetTime(),
        })
        if not pass then return end
        Start()
        return
    end

    if event == 'PLAYER_SPECIALIZATION_CHANGED' then
        -- 门两个方向都在这里翻，重跑一遍完整的 apply 就能覆盖，不用记账
        Clear()
        Apply()
        return
    end

    -- PLAYER_ENTERING_WORLD：读条一定结束任何待发的回声，而我们的发光标志跨过
    -- 它也失去意义 —— 实时查询会重新把它立起来。
    glowOn = GlowLive() and true or false
    Clear()
    Apply()
    -- proc 能活过读条画面。它还剩多久无从得知（没有任何地方记录它什么时候开始），
    -- 所以给它重开一个完整窗口，而不是猜一个短的。多显示一眼，少显示就是漏掉。
    if glowOn and CFG.enable and IsBlood() then BeginProc() end
end)

---------------------------------------------------------------- 诊断：/bdk debug
-- 在游戏外面唯一推不出来的事，就是客户端真正点亮的是哪个法术 ID。这里把它打出来：
-- 本会话见过的每一次高亮、本模块是否认得出它是血沸、以及最近几发血沸在门上
-- 分别做了什么。门要是抽风，答案就在前两块里。
local function SpellName(id)
    local CS = _G.C_Spell
    if CS and CS.GetSpellName then
        local ok, n = pcall(CS.GetSpellName, id)
        if ok and type(n) == 'string' then return n end
    end
    local ok, n = pcall(_G.GetSpellInfo, id)
    if ok and type(n) == 'string' then return n end
    return '?'
end

local function DumpRing(t, n, fmt, p, emptyMsg)
    if n == 0 then p(emptyMsg) return end
    local count = n < 12 and n or 12
    local first = n < 12 and 1 or (n % 12) + 1
    for i = 0, count - 1 do
        local e = t[(first + i - 1) % 12 + 1]
        if e then p('   ' .. fmt(e)) end
    end
end

local function DumpBP()
    local function p(...) print(Tag(), ...) end
    local live = LiveID()

    p('enable:', tostring(CFG.enable), '| Blood:', tostring(IsBlood()),
        '| gate:', T('只认发光中的施法，严格', 'only glowing casts, strictly'))
    p(T('血沸基础 ID:', 'Blood Boil base id:'), BP_SPELL, '(' .. SpellName(BP_SPELL) .. ')',
        T('| 当前 ID:', '| live id right now:'), live,
        live ~= BP_SPELL and '|cffff6600(OVERRIDDEN)|r' or T('(无 override)', '(no override)'))
    p(T('触发条:', 'proc bar:'),
        CFG.procBar and format(T('开，%d 秒', 'on, %ds'), PROC_SECONDS) or T('关', 'off'),
        T('| 正在跑:', '| running:'),
        ProcActive() and format(T('还剩 %.1fs', '%.1fs left'), procUntil - GetTime()) or T('无', 'no'))
    p(T('触发辉光:', 'proc glow:'), CFG.procGlow and T('开', 'on') or T('关', 'off'),
        T('| 血沸现在在发光:', '| Blood Boil glowing now:'), tostring(ProcUp()),
        T('| 已画:', '| drawn:'), glowingNow and T('是', 'yes') or T('否', 'no'))
    p(T('链式叠加: 开', 'chaining: on'), T('| 当前排队窗口:', '| windows queued right now:'), queued,
        T('| 图标在屏:', '| icon up:'),
        (expiresAt > 0 and expiresAt > GetTime()) and T('是', 'yes') or T('否', 'no'))
    p(T('条:', 'bar:'), format(T('%d×%d 像素', '%dx%d px'), CFG.barLength, CFG.barThickness),
        T('| 数字:', '| numbers:'), CFG.barText and T('开', 'on') or T('关', 'off'),
        T('| 位置:', '| position:'), format('%d, %d', Round(CFG.x or 0), Round(CFG.y or -160)),
        T('(全部存盘)', '(all persisted)'))
    p(T('高亮 API:', 'overlay api:'),
        IsSpellOverlayed and T('有', 'yes') or '|cffff6600MISSING|r',
        T('| 现在发光:', '| glowing now:'), tostring(GlowLive()),
        T('| 门已认证:', '| gate proven:'),
        glowEver and '|cff00ff00YES|r'
            or T('|cffff6600NO —— 在游戏点亮一次血沸之前，什么都不触发|r',
                 '|cffff6600NO - nothing fires until the game glows Blood Boil once|r'))
    local cv = _G.GetCVar and _G.GetCVar('displaySpellActivationOverlays')
    p(T('技能提示 CVar:', 'spell alerts cvar:'), tostring(cv),
        cv == '0' and T('|cffff6600(界面选项里把技能提示关了)|r',
                        '|cffff6600(alerts off in Interface options)|r') or '')

    p(T('本会话见过的高亮（新的在后）:', 'glows seen this session (newest last):'))
    DumpRing(glowLog, glowLogN, function(e)
        return format('%s  %d  %s  %s', e.show and 'SHOW' or 'hide', e.id, SpellName(e.id),
            e.mine and T('|cff00ff00<- 认得是血沸|r', '|cff00ff00<- matched as Blood Boil|r')
                or T('|cff999999(不是我们的)|r', '|cff999999(not ours)|r'))
    end, p, T('   |cffff6600一条都没有 —— 登录以来游戏没点亮过任何法术|r',
              '   |cffff6600none at all - the game has not glowed ANY spell since login|r'))

    p(T('血沸施法（新的在后）:', 'Blood Boil casts (newest last):'))
    DumpRing(castLog, castLogN, function(e)
        return format('id %d  gate %s  %s', e.id,
            e.pass and T('|cff00ff00通过|r', '|cff00ff00PASS|r')
                or T('|cff999999拦下|r', '|cff999999blocked|r'),
            e.proven and '' or T('(当时门还没认证)', '(gate unproven at the time)'))
    end, p, T('   还没有', '   none yet'))

    if not glowEver and glowLogN > 0 then
        p(T('|cffff6600=> 游戏确实在点亮法术，但没点亮任何本模块读作血沸的那一个。|r',
            '|cffff6600=> the game IS glowing spells, but never one this module reads as Blood Boil.|r'))
        p(T('   在修好之前不会触发。正确 ID 就在上面那张表里。',
            '   Nothing will fire until that is fixed. The correct id is in the list above.'))
    elseif glowLogN == 0 then
        p(T('=> 还没有高亮数据。等一次 Boiling Point 触发，再跑一遍 /bdk debug。',
            '=> no glow data yet. Get a Boiling Point proc, then run /bdk debug again.'))
    else
        p(T('=> 门已校准；只有发光中的血沸会起倒计时。',
            '=> gate is calibrated; only glowing Blood Boils start the countdown.'))
    end
end

---------------------------------------------------------------- 命令
-- 命令一共四条：诊断、预览+拖动定位、条宽、条上的数字开关。
local function Reapply()
    -- 设置照存不误（换回鲜血专精就是玩家想要的那样），但界面只在自己人身上动 ——
    -- 一个战士敲 /bdk bp width 是想改设置，不是想让我们在他客户端里建一个隐藏的帧。
    if not IsBlood() then return end
    ApplySettings()
    if frame then Render() end
end

-- 条宽。改完立刻套用：ApplySettings 重排尺寸和字号，Render 让正在跑的那个窗口
-- 也按新宽度重画（跑马灯缓存了尺寸，尺寸一变它自己会重开）。
local function CmdWidth(arg)
    if not arg then
        print(Tag(), format(T('用法：/bdk bp width %d-%d（当前 %d）',
                              'usage: /bdk bp width %d-%d (now %d)'),
            BAR_MIN, BAR_MAX, CFG.barLength))
        return true
    end
    local n = tonumber(arg)
    if not n then
        print(Tag(), format(T('看不懂的宽度：%s。用法：/bdk bp width %d-%d',
                              'not a width: %s. usage: /bdk bp width %d-%d'), arg, BAR_MIN, BAR_MAX))
        return true
    end
    local want = Round(n)
    local clampedTo = mmin(BAR_MAX, mmax(BAR_MIN, want))
    CFG.barLength = clampedTo
    SaveCfg()
    Reapply()
    print(Tag(), format(T('血沸条宽度：%d', 'boiling point bar width: %d'), clampedTo)
        .. (clampedTo ~= want and format(T('（%d 已夹到范围 %d-%d）',
                                           ' (%d clamped to %d-%d)'), want, BAR_MIN, BAR_MAX) or ''))
    return true
end

-- 条上的倒计时数字。不带参数就当切换用 —— 命令名里有"切换"三个字，让玩家再想一下
-- 现在是开还是关，不如不给参数就翻面。
local function CmdBarText(arg)
    local on
    if arg == nil or arg == '' then
        on = not CFG.barText
    elseif arg == 'on' or arg == '开' then
        on = true
    elseif arg == 'off' or arg == '关' then
        on = false
    else
        print(Tag(), T('用法：/bdk bp text on|off（不带参数 = 切换）',
                       'usage: /bdk bp text on|off (bare = toggle)'))
        return true
    end
    CFG.barText = on
    SaveCfg()
    Reapply()
    print(Tag(), T('血沸条数字：', 'boiling point bar numbers: ')
        .. (on and T('开', 'on') or T('关', 'off')))
    return true
end

---------------------------------------------------------------- 命令登记
-- 命令表（帮助文案、颜色、参数解析、分发）在 Commands.lua，本模块只登记自己能做什么。
local CMD = _G.BloodDeathKnightCmd
if not CMD then
    CMD = {}
    _G.BloodDeathKnightCmd = CMD
end

-- /bdk bp test —— 预览 + 右键拖动定位。是个开关：再执行一次退出（拖完不会自己退）。
CMD[#CMD + 1] = {
    name = 'bp test',
    order = 1,
    zh   = '预览/拖动血沸条',
    en   = 'preview / move the boiling point bar',
    run  = function()
        if not IsBlood() then
            print(Tag(), T('非鲜血死亡骑士，血沸提示待机', 'not Blood DK, Boiling Point idle'))
            return
        end
        SetPreview(not preview)
        print(Tag(), T('预览/拖动:', 'preview/drag:'),
            preview and T('开（右键拖动定位，再执行一次结束）', 'on (right-drag to place, run again to stop)')
                or T('关', 'off'))
    end,
}

-- /bdk bp width <20-400> —— 条宽，范围外夹回来而不是拒绝
CMD[#CMD + 1] = {
    name = 'bp width', arg = true,
    argZh = '数字', argEn = 'number',
    order = 2,
    zh   = '血沸条的宽度',
    en   = 'boiling point bar width',
    run  = function(arg) CmdWidth(arg) end,
}

-- /bdk bp text [on|off] —— 条上那个倒计时数字；不带参数就翻面
CMD[#CMD + 1] = {
    name = 'bp text', arg = true,
    order = 3,
    zh   = '切换血沸条是否显示数字',
    en   = 'toggle the countdown numbers on the bar',
    run  = function(arg) CmdBarText(arg) end,
}

-- /bdk debug —— 隐藏命令：把血沸这一侧的诊断摊开（门、亮过哪些 ID、最近几发施法）
CMD[#CMD + 1] = {
    name   = 'debug',
    hidden = true,
    run    = function() DumpBP() end,
}
