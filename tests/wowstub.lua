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
FRAME_META.EnableMouse     = function() end
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
FRAME_META.RegisterEvent   = function() end
FRAME_META.RegisterUnitEvent = function() end

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
    -- CreateFrame(frameType, name, parent, template) —— parent 必须传下去，
    -- 否则蒙版帧挂不到图标上，测出来的东西根本不对
    out.CreateFrame  = function(_, _, parent) return newFrame(parent) end
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

    out.C_Spell = {
        GetSpellInfo    = function(id) return { name = 'spell' .. tostring(id) } end,
        GetSpellTexture = function() return 134000 end,
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

return ENV
