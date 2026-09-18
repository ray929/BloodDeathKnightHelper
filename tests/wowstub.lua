------------------------------------------------------------------
-- 最小 WoW API 桩 + 受控时钟：用来离线运行 BoneShield.lua
-- 只实现插件真正用到的方法；缺哪个就会直接报 "attempt to call a nil value"，
-- 这正是我们要的 —— 缺桩立刻暴露，不会静默走偏。
------------------------------------------------------------------
local ENV = {}

ENV.frames = {}
ENV.fonts  = {}
ENV.verbose = false

---------------------------------------------------------------- 受控时钟
local NOW = 0
ENV.now    = function() return NOW end
ENV.setNow = function(t) NOW = t end

---------------------------------------------------------------- 对象工厂
local FRAME_META, TEX_META, FONT_META = {}, {}, {}
-- 方法直接挂在元表上，所以必须把 __index 指回自己，否则 t:Method() 全部取到 nil
FRAME_META.__index, TEX_META.__index, FONT_META.__index = FRAME_META, TEX_META, FONT_META

local function newFrame(parent)
    local f = setmetatable({}, FRAME_META)
    f.__shown   = true
    f.__alpha   = 1
    f.__level   = 1
    f.__parent  = parent
    f.__kids    = {}
    f.__scripts = {}
    f.__w, f.__h = 36, 36
    if parent then parent.__kids[#parent.__kids + 1] = f end
    ENV.frames[#ENV.frames + 1] = f
    return f
end
ENV.newFrame = newFrame

function FRAME_META:CreateTexture() return setmetatable({}, TEX_META) end
function FRAME_META:CreateFontString()
    local fs = setmetatable({}, FONT_META)
    ENV.fonts[#ENV.fonts + 1] = fs
    return fs
end
FRAME_META.SetFrameStrata  = function() end
FRAME_META.EnableMouse     = function(self, on) self.__mouse = on and true or false end
FRAME_META.SetSize         = function(self, w, h) self.__w, self.__h = w, h end
FRAME_META.SetWidth        = function(self, w) self.__w = w end
FRAME_META.GetWidth        = function(self) return self.__w end
FRAME_META.GetHeight       = function(self) return self.__h end
FRAME_META.GetSize         = function(self) return self.__w, self.__h end
FRAME_META.Show            = function(self) self.__shown = true end
FRAME_META.Hide            = function(self) self.__shown = false end
FRAME_META.IsShown         = function(self) return self.__shown end
FRAME_META.SetAlpha        = function(self, a) self.__alpha = a end
FRAME_META.GetAlpha        = function(self) return self.__alpha end
FRAME_META.SetFrameLevel   = function(self, l) self.__level = l end
FRAME_META.GetFrameLevel   = function(self) return self.__level end
FRAME_META.GetParent       = function(self) return self.__parent end
FRAME_META.SetParent       = function(self, p) self.__parent = p end
FRAME_META.SetAllPoints    = function() end
FRAME_META.ClearAllPoints  = function() end
FRAME_META.SetPoint        = function() end
FRAME_META.SetScript       = function(self, k, fn) self.__scripts[k] = fn end
FRAME_META.GetScript       = function(self, k) return self.__scripts[k] end
-- 事件登记也记一笔：用来断言"非本职业时一个事件都不注册"
FRAME_META.RegisterEvent     = function(self, e)
    self.__events = self.__events or {}
    self.__events[e] = true
end
FRAME_META.RegisterUnitEvent = function(self, e)
    self.__events = self.__events or {}
    self.__events[e] = true
end

-- GetChildren 在 WoW 里返回多个值，不是表 —— 桩必须照实返回
function FRAME_META:GetChildren()
    local n = #self.__kids
    if n == 0 then return end
    return table.unpack(self.__kids, 1, n)
end
function FRAME_META:GetCooldownID() return self.__cooldownID end

TEX_META.SetAllPoints   = function() end
TEX_META.SetPoint       = function() end
TEX_META.SetColorTexture = function(self, r, g, b, a) self.r, self.g, self.b, self.a = r, g, b, a end
TEX_META.SetTexture     = function(self, t) self.tex = t end
TEX_META.GetTexture     = function(self) return self.tex end

FONT_META.SetPoint       = function() end
FONT_META.SetText        = function(self, t) self.__text = t end
FONT_META.GetText        = function(self) return self.__text end
FONT_META.SetTextColor   = function() end
FONT_META.SetAlpha       = function(self, a) self.__alpha = a end
FONT_META.GetAlpha       = function(self) return self.__alpha or 1 end
FONT_META.GetFont        = function() return 'Fonts\\FRIZQT__.TTF' end
FONT_META.SetFont        = function() end
FONT_META.GetStringWidth = function() return 42 end

---------------------------------------------------------------- 全局 API
local SECRET = setmetatable({}, { __tostring = function() return '<secret>' end })
ENV.SECRET = SECRET

function ENV.install(lang)
    local out = {}
    ENV.env = out
    ENV.lines = {}

    out.UIParent     = newFrame(nil)
    -- CreateFrame(frameType, name, parent, template) —— 第 3 个参数是 parent，必须真的
    -- 传下去，否则子帧挂不上、测出来的东西全是假的。frameType/name 记下来供测试观察。
    -- 同时登记进 out.__frames（按 env 分组）：ENV.frames 是全局的，跨 env 找帧会拿到
    -- 上一个 env 的同名帧 —— "重登之后设置有没有读回来"这类用例会因此测了个寂寞。
    out.__frames     = {}
    out.CreateFrame  = function(ftype, name, parent)
        local f = newFrame(parent)
        f.__ftype, f.__name = ftype, name
        f.__env = out
        out.__frames[#out.__frames + 1] = f
        return f
    end
    out.GetLocale    = function() return lang or 'zhCN' end
    out.GetTime      = function() return NOW end
    out.GetBuildInfo = function() return 1, 'x', 'y', 120100 end
    out.__lines      = ENV.lines
    out.print        = function(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
        local line = table.concat(parts, ' ')
        out.__lines[#out.__lines + 1] = line
        if ENV.verbose then io.write('[print] ', line, '\n') end
    end

    out.__sounds      = {}
    out.PlaySoundFile = function(p) out.__sounds[#out.__sounds + 1] = p end

    out.issecretvalue = function(v) return v == SECRET end

    out.__inCombat       = false
    out.InCombatLockdown = function() return out.__inCombat == true end

    -- 天赋闸门用的"玩家学了哪些法术"。__talents[spellID] = true 表示该天赋已点出。
    -- __noSpellKnownApi = true 模拟**所有**检测 API 都不可用/被挡（12.x 战斗中的那种情形），
    -- 用来验证代码走 fail-open 兜底而不是把技能误判成"不刷新"。
    -- __spellKnownCalls 记调用次数：用来断言"战斗中一次都不许读天赋"（只看返回值区分不了
    -- "没读"和"读了但结果一样"）。
    out.__talents        = {}
    out.__spellKnownCalls = 0
    out.__noSpellKnownApi = false
    out.C_SpellBook = {
        IsSpellKnown = function(id)
            out.__spellKnownCalls = out.__spellKnownCalls + 1
            if out.__noSpellKnownApi then error('blocked in combat') end
            return out.__talents[id] == true
        end,
    }

    out.UnitClass = function() return 'Blood Death Knight', 'DEATHKNIGHT', 6 end
    out.C_SpecializationInfo = {
        GetSpecialization = function() return out.__spec or 1 end,
    }
    out.__spec = 1

    out.__timers = {}
    out.C_Timer  = {
        After = function(delay, fn)
            out.__timers[#out.__timers + 1] = { at = NOW + delay, fn = fn }
        end,
    }
    function out.runTimers()
        local pending = out.__timers
        out.__timers = {}
        for i = 1, #pending do
            if NOW >= pending[i].at then pending[i].fn() end
        end
    end

    out.__cooldowns = {}
    out.C_CooldownViewer = {
        GetCooldownViewerCooldownInfo = function(id) return out.__cooldowns[id] end,
    }
    function out.addCooldown(id, info) out.__cooldowns[id] = info end

    -- 显示名也是"问客户端要"的（C_Spell.GetSpellName）。桩默认给一个**一眼假**的名字
    -- （spell<id>）——于是任何"像真名字"的输出都必然来自测试塞进 __spellNames 的映射，
    -- "名字又被硬编码回代码里"这种回归会被 smoke T12 的断言捉住。
    -- 放这里（install，公共基础环境）而不是 installBP：骨盾测试只用 install。
    out.__spellNames = {}
    out.C_Spell = {
        GetSpellInfo    = function(id) return { name = 'spell' .. tostring(id) } end,
        GetSpellTexture = function() return 134000 end,
        GetSpellName    = function(id)
            return out.__spellNames[id] or ('spell' .. tostring(id))
        end,
    }

    out.SlashCmdList = {}      -- 插件会往里写 BLOODDEATHKNIGHT
    out.C_UnitAuras  = nil     -- 不提供：本插件本来就不该碰它

    return out
end

-- 构造一个 CDM 查看器：EnumerateActive 返回迭代器、GetChildren 返回多值、
-- GetItemFrames 返回表 —— 三种真实形态都覆盖
function ENV.makeViewer(cooldownIDs)
    local viewer = newFrame(nil)
    local items = {}
    for i = 1, #cooldownIDs do
        local item = newFrame(viewer)
        item.__cooldownID = cooldownIDs[i]
        item.IsActive = false
        items[i] = item
    end
    viewer.__items = items
    viewer.itemFramePool = {
        EnumerateActive = function()
            local i = 0
            return function()
                i = i + 1
                return items[i]
            end
        end,
    }
    function viewer:GetItemFrames()
        local t = {}
        for i = 1, #items do
            if items[i].__shown then t[#t + 1] = items[i] end
        end
        return t
    end
    return viewer
end

------------------------------------------------------------------
-- 追加：BoilingPoint.lua 用到的通用接口
-- 全部是"加方法"，不动已有语义 —— BoneShield 的用例不受影响。
------------------------------------------------------------------
FRAME_META.SetClampedToScreen   = function() end
-- 拖动面：记下"能不能拖、拖起来没有、拖到哪"。GetCenter 支持每个帧单独摆位置
-- （f.__center = {x,y}），否则拖动的落点算不出来 —— 全是 0,0 就测不出偏移对不对。
FRAME_META.SetMovable           = function(self) self.__movable = true end
FRAME_META.RegisterForDrag      = function(self, btn) self.__dragBtn = btn end
FRAME_META.StartMoving          = function(self) self.__moving = true end
FRAME_META.StopMovingOrSizing   = function(self)
    self.__moving, self.__stoppedMoving = false, true
end
FRAME_META.GetCenter            = function(self)
    local c = self.__center
    if c then return c[1], c[2] end
    return 0, 0
end
FRAME_META.SetShown             = function(self, on) self.__shown = on and true or false end
FRAME_META.SetStatusBarTexture  = function() end
FRAME_META.SetStatusBarColor    = function(self, r, g, b, a) self.__barColor = { r, g, b, a } end
FRAME_META.SetValue             = function(self, v) self.__value = v end
FRAME_META.GetValue             = function(self) return self.__value or 0 end
FRAME_META.SetMinMaxValues      = function(self, a, b) self.__min, self.__max = a, b end
FRAME_META.SetOrientation       = function() end
FRAME_META.SetDrawEdge          = function() end
FRAME_META.SetDrawBling         = function() end
FRAME_META.SetReverse           = function() end
FRAME_META.SetHideCountdownNumbers = function() end
FRAME_META.SetCooldown          = function(self, s, d) self.__cd = { s, d } end
FRAME_META.Clear                = function(self) self.__cd = nil end
FRAME_META.CreateMaskTexture    = function() return setmetatable({}, TEX_META) end

TEX_META.SetTexCoord    = function() end
TEX_META.SetVertexColor = function(self, r, g, b, a) self.vr, self.vg, self.vb, self.va = r, g, b, a end
TEX_META.SetSize        = function(self, w, h) self.__w, self.__h = w, h end
TEX_META.ClearAllPoints = function() end
TEX_META.Show           = function(self) self.__shown = true end
TEX_META.Hide           = function(self) self.__shown = false end
TEX_META.IsShown        = function(self) return self.__shown end
TEX_META.AddMaskTexture = function(self, m) self.__mask = m end

-- 动画链：像素跑马灯辉光靠 C 侧 Translation 动画移动虚线，桩里只需要"会不会播"
local AG_META, ANIM_META = {}, {}
AG_META.__index, ANIM_META.__index = AG_META, ANIM_META
function AG_META:SetLooping() end
function AG_META:Stop() self.__playing = false end
function AG_META:Play() self.__playing = true end
function AG_META:IsPlaying() return self.__playing == true end
function AG_META:CreateAnimation(kind)
    local a = setmetatable({ __kind = kind }, ANIM_META)
    self.__anims[#self.__anims + 1] = a
    return a
end
ANIM_META.SetSmoothing  = function() end
ANIM_META.SetOffset     = function() end
ANIM_META.SetDuration   = function() end
ANIM_META.SetFromAlpha  = function() end
ANIM_META.SetToAlpha    = function() end

TEX_META.CreateAnimationGroup = function(self)
    local ag = setmetatable({ __playing = false, __anims = {}, __owner = self }, AG_META)
    self.__ag = ag
    return ag
end

FONT_META.SetShown = function(self, on) self.__shown = on and true or false end

------------------------------------------------------------------
-- BoilingPoint.lua 需要的额外全局面
------------------------------------------------------------------
function ENV.installBP(env)
    env.STANDARD_TEXT_FONT = 'Fonts\\FRIZQT__.TTF'
    env.Enum = { StatusBarInterpolation = { ExponentialEaseOut = 1, Immediate = 2 } }
    env.GetCVar     = function() return '1' end
    env.GetSpellInfo = function(id) return 'spell' .. tostring(id) end

    -- 技能触发高亮：测试直接控制"游戏此刻点亮了哪个 ID"
    env.__overlay = {}
    env.C_SpellActivationOverlay = {
        IsSpellOverlayed = function(id) return env.__overlay[id] == true end,
    }
    function env.overlay(id, on) env.__overlay[id] = on and true or nil end

    -- base/override 映射：override 只覆盖有登记的那些
    -- 名字桩（GetSpellName / __spellNames）定义在 install 里 —— 骨盾测试只调 install，
    -- 放这儿会漏掉它。别在这里重复定义，两份真理迟早不同步。
    env.__base, env.__override = { [50842] = 50842 }, {}
    env.C_Spell = env.C_Spell or {}
    env.C_Spell.GetBaseSpell     = function(id) return env.__base[id] end
    env.C_Spell.GetOverrideSpell = function(id) return env.__override[id] or id end

    -- 定时器：NewTicker + Cancel。runTickers 按固定 0.1 秒步进推进受控时钟，
    -- 时钟必须无条件前进 —— 一个 ticker 都没有的时候（模块停表了）时间照样在走，
    -- 否则"停表之后又过了几秒"这种用例根本测不出来。
    env.__tickers = {}
    env.C_Timer = env.C_Timer or {}
    env.C_Timer.NewTicker = function(interval, fn)
        local t = { interval = interval, fn = fn }
        env.__tickers[#env.__tickers + 1] = t
        t.Cancel = function() t.__cancelled = true end
        return t
    end
    function env.runTickers(n)
        for _ = 1, (n or 1) do
            ENV.setNow(ENV.now() + 0.1)
            local list = env.__tickers
            for i = 1, #list do
                local t = list[i]
                if t and not t.__cancelled then
                    t.__next = t.__next or (ENV.now() + t.interval)
                    if ENV.now() + 1e-9 >= t.__next then
                        t.__next = t.__next + t.interval
                        t.fn()
                    end
                end
            end
        end
    end

    -- 以名字/类型找帧，测试里用来观察模块自己的界面。
    -- **只认本 env 建的帧** —— ENV.frames 是全局的，跨 env 查会拿到上一个 env 的同名帧，
    -- "重登之后设置读回来了吗"、"非 DK 有没有偷偷建帧"这类断言就全成了假通过。
    env.__frames = env.__frames or {}
    local function find(key, want)
        for i = 1, #env.__frames do
            if env.__frames[i][key] == want then return env.__frames[i] end
        end
    end
    function env.findFrame(name) return find('__name', name) end
    function env.findByType(ftype) return find('__ftype', ftype) end
    return env
end

return ENV
