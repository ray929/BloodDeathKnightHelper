-- BloodDeathKnight 鲜血死亡骑士辅助
-- 鲜血死亡骑士（Blood DK）辅助插件（正式服 12.1）
--
-- 当前功能：骨盾 / 埋骨之所 监控提醒
--   触发逻辑（事件驱动，纯 CDM 实现，不使用 C_UnitAuras）：
--   1. 骨盾出现时启动倒计时（骨盾固定持续 30 秒），约剩 5 秒时语音+文字 3 秒提醒一次，
--      同时给 CDM 里的骨盾图标盖上脉冲红蒙版（视觉提醒，直到补盾或窗口重置）；
--   2. 埋骨之所（Ossuary，骨盾 >= 5 层增益）消失时语音+文字 3 秒提醒一次；
--   3. 骨盾彻底消失时停止一切提醒。
--   4. 施放任意会产生/刷新骨盾的技能时，立即隐藏文字、撤掉蒙版并重置倒计时；
--   5. 三条判据各有自己的红字文案与语音（见 L.kinds，/bdk bs test 1|2|3 可逐条试听）：
--        bsGone  骨盾没了      ← voice-cn-1.mp3
--        ossGone 骨盾层数不够  ← voice-cn-2.mp3
--        warn    骨盾快没了    ← voice-cn-3.mp3（倒计时到点，提前预警）
--      英文三条共用 voice-en.mp3。它们可能在同一拍或半秒内接连成立，所以 2 秒内只发
--      一次声（ALERT_GAP）——重复发声纯属噪音，但**文字不吞**，会换成最新那条判据的话。
--
-- 前提条件：玩家需把「骨盾」和「埋骨之所」拖入暴雪冷却管理器（CDM）。
-- 若持续检测不到对应 CDM 条目，屏幕 1/3 处常驻提示文字，指导玩家配置。
--
-- 12.x 环境限制应对：
--   * 光环数据（层数/时间）在战斗中是 secret，本插件从不读取；
--   * 存在性判断完全依赖 CDM 光环图标的 isActive 字段 / IsShown+alpha
--     （暴雪自己消费 secret 后落地的明文布尔）；
--   * 骨盾固定 30 秒，倒计时提前 6 秒触发（含检测延迟补偿，玩家看到约剩 5 秒），
--     覆盖最危险的窗口。
--
-- 读数三态：读不到 != 没有了
--   帧状态只有三种：在场 / 不在场 / 读不到。第三态一律"不下结论" —— 既不触发提醒，
--   也不清除既有状态。把"读不到"当成"buff 没了"，会在 CDM 重建帧池、或换皮插件
--   重排图标时凭空造出一次"补骨盾"误报。
--   同理，"不在场"需连续成立 1 秒（DOWN_GRACE）才被承认。

local ADDON_NAME = ...

---------------------------------------------------------------- 常量
local BONE_SHIELD  = 195181   -- 骨盾
local OSSUARY      = 219786   -- 埋骨之所（常规 ID）
local OSSUARY_ALT  = 219788   -- 埋骨之所（12.1 部分环境下实际出现的 ID）
local BONE_SHIELD_TIME = 30   -- 骨盾固定持续时间（秒）
-- 提前多久提醒。名义上提前 6 秒，扣掉检测延迟（驱动 0.5 秒一拍：发现骨盾亮起最多晚
-- 0.5 秒、到点又最多晚 0.5 秒触发，平均合计约 0.5 秒），玩家实际看到的是"还剩 5 秒"
-- 左右。想让提醒更早/更晚，只改这一个数。
local WARN_LEAD    = 6
local WARN_AFTER   = BONE_SHIELD_TIME - WARN_LEAD   -- = 24，倒计时长度
local TEXT_DURATION = 3       -- 提醒文字显示时长
-- 三条判据（倒计时到点 / 骨盾掉了 / 埋骨之所掉了）各有自己的文案与语音，但它们完全可能
-- 在同一拍或半秒内接连成立：最典型的是倒计时到点的那一拍，恰好"骨盾读到不在场"也刚满
-- 1 秒去抖（掉盾起始点落在到点前 1.0s → 同一拍；落在到点前 0.5s → 半秒后）。
-- 半秒内连播两句话纯属噪音，所以给"真的发声"加一个最小间隔；**但文字不吞** ——
-- 走这条分支时会把红字换成最新那条判据的文案（"快没了" → "没了" 本身就是升级信息）。
-- 注意这个间隔要**大于**上面那个 0.5s 的对齐窗口、又必须**小于**骨盾真到期时的间隔
-- （到点提醒 → 6 秒后真掉盾 → 再报），否则会把"骨盾真的没了"那一声误吞。2 秒两头都安全。
local ALERT_GAP    = 2.0
local DOWN_GRACE   = 1.0      -- "不在场"需连续成立多久才被承认。必须明显大于驱动周期（0.5s），
                              -- 否则去抖就等于"一拍读数直接下结论"，等于没有去抖
local ABSENT_GRACE = 3        -- CDM 条目"持续"扫不到多久才算没配置（池化帧会瞬态消失）

-- 会**获得/刷新骨盾层数**的技能。骨盾只要涨层，30 秒持续时间就被整体刷新，
-- 所以施放这些技能 = 倒计时必须重新起算；漏检就会在骨盾其实还剩十几秒时提前喊话。
--
-- 值 = "持续刷新窗口"秒数：
--   0  → 瞬时型：施放那一刻刷新一次
--   >0 → 持续型：该技能在 N 秒里反复拉怪，骨盾被一次次刷新，倒计时得一路跟着推迟
--
-- 依据（12.1，逐条在 warcraft.wiki.gg 核实过，别凭印象往里加）：
--   195182  Marrowrend          骨髓打击 —— 骨盾的主来源（Bone Shield 页明写）
--   195292  Death's Caress      —— 技能描述 "generating 2 Bone Shield charges"
--   49576   Death Grip          死亡之握 ┐ 拾骨者天赋（Bone Collector, 458572）：
--   108199  Gorefiend's Grasp   血魔之握 ┘ "When you would pull an enemy generate
--   1263569 Abomination Limb    憎恶之肢   1 charge of Bone Shield"，Affects 正是前两个；
--                                        憎恶之肢由 12.0.0 重做而来，2026-03-06 的 hotfix
--                                        专门修过"点拾骨者时它不给骨盾"的问题。
-- ⚠️ 曾经误收两个，已删，别再捡回来：
--   49028 符文武器幻舞 —— 12.x 的描述只有 "mirrors your melee attacks" + 30% 招架，
--                        **不产骨盾**。留在表里会让倒计时被无谓重置 = 漏报，
--                        而这比漏检更糟（该提醒的时候不提醒）。
--   439843 —— 查无此技能（wiki 搜索零命中），当初就是猜的，删。
local REFRESH_IDS = {
    [195182]  = 0,   -- Marrowrend 骨髓打击
    [195292]  = 0,   -- Death's Caress（给 2 层）
    [49576]   = 0,   -- Death Grip 死亡之握
    [108199]  = 0,   -- Gorefiend's Grasp 血魔之握
    [1263569] = 12,  -- Abomination Limb 憎恶之肢：持续 12 秒、每秒拉一次
}

local VIEWERS = { 'BuffIconCooldownViewer', 'BuffBarCooldownViewer' }
local OSSUARY_ID_SET = { [OSSUARY] = true, [OSSUARY_ALT] = true }

-- 诊断用：枚举 CDM 全部查看器（含冷却类，参考 ActionbarEnhanced）
local ALL_VIEWERS = {
    'EssentialCooldownViewer', 'UtilityCooldownViewer',
    'BuffIconCooldownViewer', 'BuffBarCooldownViewer',
}

---------------------------------------------------------------- 本地化
local LOCALE = GetLocale()
local L = {}

local function ApplyLang()
    -- 强制跟随客户端语种：语言不再是设置项（没有 /bdk lang 了）。中文客户端就是
    -- 中文，别的就是英文 —— 一个能跟客户端说的不一样的语言开关，只会让人怀疑
    -- 自己的客户端出了什么问题。
    local zh = (LOCALE:sub(1, 2) == 'zh')

    if zh then
        L.setupText = '请将「骨盾」和「埋骨之所」拖入冷却管理器 (CDM)'
        L.tag = '|cff71d5ff[鲜血死亡骑士]|r'
        L.on, L.off = '开', '关'
        L.enabled = '插件'
        L.sound = '语音'
        L.text = '文字'
        L.flash = '图标蒙版'
        L.usage = '用法：/bdk %s on|off（不带参数 = 切换）'
        L.bloodYes, L.bloodNo = '鲜血死亡骑士', '非鲜血死亡骑士（插件待机）'
        L.cdmBs, L.cdmOss = '骨盾(CDM)', '埋骨之所(CDM)'
        L.cdmFound, L.cdmMiss = '已监控', '缺失'
        L.cdmUnproven = '（从未激活过）'
        L.flashIdle = '未在提醒窗口'
        -- 三条判据各有自己的**红字 + 语音**（看字、听声都能分辨是哪条在响）。
        -- 中文三条音文件互相独立；kindOrder 的顺序就是 /bdk bs test 1|2|3 的编号。
        L.kinds = {
            bsGone  = { text = '骨盾没了',     voice = 'voice-cn-1.mp3', reason = '骨盾没了（掉了）' },
            ossGone = { text = '骨盾层数不够', voice = 'voice-cn-2.mp3', reason = '埋骨之所没了（层数不够）' },
            warn    = { text = '骨盾快没了',   voice = 'voice-cn-3.mp3', reason = '倒计时到点（提前预警）' },
        }
        L.kindOrder = { 'bsGone', 'ossGone', 'warn' }
        L.lastAlert = '上次提醒'
        L.testHint = '用法：/bdk bs test 1|2|3（1=骨盾没了 2=骨盾层数不够 3=骨盾快没了）'
    else
        L.setupText = 'Drag "Bone Shield" and "Ossuary" into the Cooldown Manager (CDM)'
        L.tag = '|cff71d5ff[BloodDeathKnight]|r'
        L.on, L.off = 'on', 'off'
        L.enabled = 'addon'
        L.sound = 'voice'
        L.text = 'text'
        L.flash = 'icon mask'
        L.usage = 'usage: /bdk %s on|off (bare = toggle)'
        L.bloodYes, L.bloodNo = 'Blood Death Knight', 'not Blood DK (addon idle)'
        L.cdmBs, L.cdmOss = 'Bone Shield (CDM)', 'Ossuary (CDM)'
        L.cdmFound, L.cdmMiss = 'tracked', 'missing'
        L.cdmUnproven = ' (never lit)'
        L.flashIdle = 'no warning window'
        -- 英文只有一条语音（用户要求），三条判据共用；文案照样三条。
        L.kinds = {
            bsGone  = { text = 'Bone Shield down!',     voice = 'voice-en.mp3', reason = 'bone shield down' },
            ossGone = { text = 'Not enough stacks!',    voice = 'voice-en.mp3', reason = 'ossuary gone (not enough stacks)' },
            warn    = { text = 'Bone Shield expiring!', voice = 'voice-en.mp3', reason = 'early warning (timer)' },
        }
        L.kindOrder = { 'bsGone', 'ossGone', 'warn' }
        L.lastAlert = 'last alert'
        L.testHint = 'usage: /bdk bs test 1|2|3 (1=bone shield down 2=not enough stacks 3=expiring)'
    end
end

-- 判据 → {text, voice, reason}。kind 只有三种（L.kindOrder 里的那些）；
-- 传了不认识的值就退到 warn，绝不让 nil 索引把插件打崩。
local function KindOf(kind)
    local set = L.kinds
    if not set then return { text = '', voice = 'voice-en.mp3', reason = '?' } end
    return set[kind] or set.warn
end

---------------------------------------------------------------- 设置
local DB
local DEFAULTS = {
    -- 全是"功能内部状态"，不再是玩家可开关的选项：命令只剩 /bdk bs sound / bs test。
    -- text / flash 一直开着（红字提醒 + 图标蒙版闪烁），enable 是总闸（为调试保留字段，
    -- 没有命令改它）。
    enabled = true,
    sound   = true,
    text    = true,
    flash   = true,
}

---------------------------------------------------------------- 工具
local function IsSecret(v)
    local ok, res = pcall(function() return issecretvalue and issecretvalue(v) end)
    return ok and res or false
end

---------------------------------------------------------------- 职业门
local isDK
local function IsBlood()
    if isDK == nil then
        local ok, _, cls = pcall(UnitClass, 'player')
        if ok and not IsSecret(cls) then
            isDK = (cls == 'DEATHKNIGHT')
        end
    end
    if isDK == false then return false end
    local spec
    if C_SpecializationInfo and C_SpecializationInfo.GetSpecialization then
        local ok, v = pcall(C_SpecializationInfo.GetSpecialization)
        if ok then spec = v end
    elseif GetSpecialization then
        local ok, v = pcall(GetSpecialization)
        if ok then spec = v end
    end
    if spec == nil or IsSecret(spec) then return true end
    return spec == 1
end

---------------------------------------------------------------- CDM 帧匹配
local function CooldownMatches(cooldownID, ids)
    if not cooldownID or IsSecret(cooldownID) then return false end
    local get = C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo
    if not get then return false end
    local ok, info = pcall(get, cooldownID)
    if not ok or not info then return false end
    local function eq(v) return not IsSecret(v) and ids[v] end
    if eq(info.spellID) or eq(info.linkedSpellID)
        or eq(info.overrideSpellID) or eq(info.overrideTooltipSpellID) then
        return true
    end
    local linked = info.linkedSpellIDs
    if type(linked) == 'table' then
        for i = 1, #linked do
            if eq(linked[i]) then return true end
        end
    end
    return false
end

local BS_ID_SET = { [BONE_SHIELD] = true }

-- 取条目 cooldownInfo 里的全部候选 ID，带角色标签返回 { {role, id}, ... }。两个用途：
--   * 诊断输出（spell= / override= / tooltip= / linked=）—— 把"一个条目携带多个 ID"
--     这件事直接摊开。埋骨之所就是这种条目：只打裸 ID 会让人误读成"两个条目"，
--     进而以为要在两个 ID 之间做选择（实际是同一个条目的两个 ID，拖哪个都一样）。
--   * want 传入关心的 id 集合时，只挑出命中的那几个。
-- 匹配判定本身另见 CooldownMatches（那边只关心"有没有命中"，不关心角色）。
local function CooldownCandidates(cooldownID, want)
    local get = C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo
    if not get or not cooldownID or IsSecret(cooldownID) then return {} end
    local ok, info = pcall(get, cooldownID)
    if not ok or type(info) ~= 'table' then return {} end
    local out = {}
    local function put(role, id)
        if type(id) ~= 'number' or id <= 0 or IsSecret(id) then return end
        if want and not want[id] then return end
        out[#out + 1] = { role, id }
    end
    put('spell',   info.spellID)
    put('override', info.overrideSpellID)
    put('tooltip', info.overrideTooltipSpellID)
    put('linked',  info.linkedSpellID)
    if type(info.linkedSpellIDs) == 'table' then
        for i = 1, #info.linkedSpellIDs do put('linked', info.linkedSpellIDs[i]) end
    end
    return out
end

local function JoinCandidates(list)
    local parts = {}
    for i = 1, #list do parts[i] = list[i][1] .. '=' .. list[i][2] end
    return table.concat(parts, ' ')
end

local function FrameCdID(f)
    if not f or not f.GetCooldownID then return nil end
    local ok, id = pcall(f.GetCooldownID, f)
    if ok and id and not IsSecret(id) then return id end
    return nil
end

local function FrameIsSpell(f, ids)
    local id = FrameCdID(f)
    if not id then return false end
    return CooldownMatches(id, ids)
end

-- isActive 是暴雪自己 ShouldBeShown 所看的标志，且是帧上的普通成员 —— 所以它既在
-- "图标被设成不活跃也保持可见"时仍答得出来，也在受限战斗里仍然读到明文布尔
-- （实测：两层骨盾时读到正确的 false）。因此它优先，且一旦读到真布尔就直接相信。
--
-- 形态不唯一（方法 IsActive() / 字段 IsActive / 字段 isActive，暴雪源码里是小写），
-- 三个都问一遍，谁先给出真布尔就用谁；全都给不出才算"读不到"。
local function AsBool(v)
    if v == nil then return nil end
    if IsSecret(v) then return nil end
    if type(v) ~= 'boolean' then return nil end
    return v
end

local function FrameFlag(f)
    local v = f.IsActive
    if type(v) == 'function' then
        local ok, a = pcall(v, f)
        if ok then
            local b = AsBool(a)
            if b ~= nil then return b end
        end
    else
        local b = AsBool(v)
        if b ~= nil then return b end
    end
    return AsBool(f.isActive)
end

-- 退路：图标有没有被画出来。额外排除被别家插件停在幕后当占位用的帧
-- （EllesmereUI 那种"不隐藏、只把 alpha 归零并挪到屏幕外"的做法）。
local function FrameDrawn(f)
    if not f then return false end
    if f._isPlaceholderFrame then return false end
    local ok, shown = pcall(f.IsShown, f)
    if not ok or not shown then return false end
    local okA, alpha = pcall(f.GetAlpha, f)
    if okA and type(alpha) == 'number' and alpha < 0.05 then return false end
    return true
end

---------------------------------------------------------------- CDM 帧池
-- CDM 的 buff 配置条目帧是常驻的（不随 buff 消失而释放，isActive 才反映 buff 状态），
-- 所以"帧列表为空"只说明没扫到 —— 是不是"没配置"，还要看这个空是不是持续的
-- （见 ABSENT_GRACE / ConfigMissing）。
local bsFrames, ossFrames = {}, {}

-- 帧认证表：帧被"亲眼看到亮过"才记一笔。用途是挡诱饵 ——
-- 别家换皮插件会把不用的 viewer 帧停在幕后常暗不亮，这种帧若被当成"骨盾不在场"，
-- 就会变成一次凭空来的补盾提醒；亮过一次的帧才允许给出"不在场"。
-- 注意：只加在"看图标画没画"这条退路上。isActive 路径读到真值就直接相信，不要求认证
-- —— 在那边要求认证，正是"屏幕上看什么都对、插件却一直沉默"的来源。
local bsProven  = setmetatable({}, { __mode = 'k' })
local ossProven = setmetatable({}, { __mode = 'k' })

local lastScan = 0          -- 上次扫描时间（用于节流补扫）
local bsSeenAt  = GetTime() -- 最近一次真的扫到骨盾条目的时间
local ossSeenAt = GetTime() -- 最近一次真的扫到埋骨之所条目的时间

-- 蒙版函数前置声明（实现在界面区）
local StopFlashOn, StopAllFlash

local function AddFrame(list, f)
    for i = 1, #list do if list[i] == f then return end end
    list[#list + 1] = f
end

-- 多源收集 viewer 的 item 帧（参考 ActionbarEnhanced/Manual.lua）：
-- 1) itemFramePool:EnumerateActive —— 池化活动帧（含被隐藏的，最可靠）；
-- 2) GetChildren() 递归 —— 子帧无论显示与否都会被返回，唯一能在"buff 已消失"时
--    仍然拿到帧的来源。这一条是踩坑换来的：CooldownViewerMixin:GetItemFrames()
--    就是 GetLayoutChildren()，而 BaseLayoutMixin:AddLayoutChildren 只收 IsShown()
--    的子帧；CDM 的 ShouldBeShown() 又恰好在光环不活跃时把图标 HIDE 掉 —— 两者相遇，
--    那个帧就在你最需要它的一刻从列表里消失了。GetChildren 不看显示状态。
--    （递归而不是只看直接子帧，是因为 item frame 可能挂在 itemContainerFrame 之下，
--      层级随版本变；给个深度上限和节点预算就够稳。）
-- 3) GetItemFrames —— 布局子帧（仅可见，兜底）。
local MAX_SCAN_NODES = 400

-- 把"可能返回表、也可能返回迭代器"的收集结果统一塞进 found
local function AddAll(res, found, seen)
    if not res then return end
    local t = type(res)
    if t == 'function' then                 -- 迭代器（EnumerateActive 那种）
        for f in res do
            if f and not seen[f] then seen[f] = true; found[#found + 1] = f end
        end
    elseif t == 'table' then
        for i = 1, #res do
            local f = res[i]
            if f and not seen[f] then seen[f] = true; found[#found + 1] = f end
        end
    end
end

-- Frame:GetChildren() 返回的是多个值，不是表 —— 必须先打包，
-- 否则 pcall 的第二个返回值只是第一个子帧，整个递归采集都是错的。
local function PackChildren(f)
    if not f or not f.GetChildren then return nil end
    local vals = { pcall(f.GetChildren, f) }
    if not vals[1] then return nil end
    table.remove(vals, 1)
    return vals
end

local function CollectFromChildren(f, found, seen, depth, budget)
    if not f or depth > 3 then return end
    local kids = PackChildren(f)
    if not kids then return end
    for i = 1, #kids do
        local c = kids[i]
        if c and not seen[c] then
            seen[c] = true
            budget.n = budget.n + 1
            if budget.n > MAX_SCAN_NODES then return end
            found[#found + 1] = c
            CollectFromChildren(c, found, seen, depth + 1, budget)
        end
    end
end

local function CollectFrames(viewer, found, seen)
    if not viewer then return end
    -- 1) 池化活动帧（EnumerateActive 返回迭代器）
    local pool = viewer.itemFramePool
    if pool and pool.EnumerateActive then
        local ok, iter = pcall(pool.EnumerateActive, pool)
        if ok and type(iter) == 'function' then
            for f in iter do
                if f and not seen[f] then seen[f] = true; found[#found + 1] = f end
            end
        end
    end
    -- 2) GetChildren 递归
    CollectFromChildren(viewer, found, seen, 1, { n = 0 })
    -- 3) GetItemFrames（返回表或迭代器，两种都收）
    if viewer.GetItemFrames then
        local ok, res = pcall(viewer.GetItemFrames, viewer)
        if ok then AddAll(res, found, seen) end
    end
end

-- 全量扫描 CDM 帧（周期调用 + 事件触发调用）。
-- 只在"帧已不再属于这个法术"时移除，绝不清空重建 —— 重建会在 buff 消失的那一刻把帧
-- 删掉，而那正是它唯一有话要说的时刻（列表一空，答案就变成"不知道"）。等价于
-- "找到即保留"，只是每读一次都重新核对身份，因为池化帧会被回收给别的法术。
local function ScanCdmFrames()
    for i = #bsFrames, 1, -1 do
        local f = bsFrames[i]
        if not FrameIsSpell(f, BS_ID_SET) then
            table.remove(bsFrames, i)
            bsProven[f] = nil
            StopFlashOn(f)          -- 帧已换绑，别把蒙版留在它身上
        end
    end
    for i = #ossFrames, 1, -1 do
        local f = ossFrames[i]
        if not FrameIsSpell(f, OSSUARY_ID_SET) then
            table.remove(ossFrames, i)
            ossProven[f] = nil
        end
    end

    local all, seen = {}, {}
    for v = 1, #VIEWERS do
        CollectFrames(_G[VIEWERS[v]], all, seen)
    end
    for i = 1, #all do
        local f = all[i]
        if f.GetCooldownID then
            if FrameIsSpell(f, BS_ID_SET) then
                AddFrame(bsFrames, f)
            end
            if FrameIsSpell(f, OSSUARY_ID_SET) then
                AddFrame(ossFrames, f)
            end
        end
    end

    lastScan = GetTime()
    if #bsFrames  > 0 then bsSeenAt  = lastScan end
    if #ossFrames > 0 then ossSeenAt = lastScan end
end

-- 三态读数：known = 有没有拿到可信答案，up = 在不在场。
-- known == false 时 up 没有意义，调用方必须"不下结论"。
local function CdmState(list, ids, proven)
    local known, up = false, false
    for i = #list, 1, -1 do
        local f = list[i]
        if not f or not FrameIsSpell(f, ids) then
            table.remove(list, i)          -- 池化帧换绑了别的法术：忘掉它，别读
            if f then proven[f] = nil; StopFlashOn(f) end
        else
            local flag = FrameFlag(f)
            if flag ~= nil then            -- 读得到就相信，不要求认证
                known = true
                if flag then up = true; proven[f] = true end
            elseif FrameDrawn(f) then      -- 读不到才退回"图标画没画"
                proven[f] = true
                known, up = true, true
            elseif proven[f] then
                known = true               -- 认证过的帧现在不亮 = 确实不在场
            end
            -- 既读不到又没认证过：什么都不知道（可能是常暗诱饵帧）
        end
    end
    return known, up
end

-- 配置提示判据：条目"持续"扫不到才算没配置。
-- 用"持续"而不是"这一拍扫不到"，是因为池化帧在 CDM 重建帧池时会瞬态消失 ——
-- 把瞬态空列表当成"没配置"，提示就会一闪一闪。
local function ConfigMissing()
    local now = GetTime()
    return (now - bsSeenAt) > ABSENT_GRACE or (now - ossSeenAt) > ABSENT_GRACE
end

---------------------------------------------------------------- 状态（提前声明供界面函数引用）
local state = {
    bsUp = false,      -- 骨盾当前是否存在
    ossUp = false,     -- 埋骨之所当前是否存在
    timerEnd = 0,      -- 倒计时结束时间（= 骨盾被观察到在场的时刻 + WARN_AFTER）
    alerted = false,   -- 当前窗口是否已经触发过提醒
    showingSetup = false,  -- 当前显示的是配置提示还是提醒
    hideAt = nil,      -- 提醒文字自动隐藏时间（由驱动循环检查）
    suppressAlertsUntil = nil, -- 施放刷新技能后的宽限期，避免 CDM 更新延迟导致误报
    refreshUntil = nil, -- 持续型刷新技能（憎恶之肢）的窗口截止时刻：窗口内骨盾被反复刷新，
                        -- 倒计时跟着一路推迟，而不是只在施放那一拍重置一次
    lastAlertAt = nil, -- 上次"真的发声"的时刻。跨窗口有效 —— 不能被 ResetWindow /
                       -- ClearWindow 清掉，否则去重就是摆设（去重要挡的正是"窗口刚被
                       -- 清掉、下一条判据立刻又成立"这个情形）。
    bsDownSince = nil, -- 骨盾"读到不在场"的起始时刻（DOWN_GRACE 去抖用）
    ossDownSince = nil,-- 埋骨之所同上
}

---------------------------------------------------------------- 提醒界面
local alertFrame = CreateFrame('Frame', 'BloodDeathKnightAlert', UIParent)
alertFrame:SetFrameStrata('DIALOG')
alertFrame:EnableMouse(false)
alertFrame:Hide()

-- 继承内置 GameFontNormalHuge 字体对象：中文客户端自动用中文字形
-- （STANDARD_TEXT_FONT/FRIZQT__.TTF 无中文字形，中文会渲染为空）
local alertText = alertFrame:CreateFontString(nil, 'OVERLAY', 'GameFontNormalHuge')
alertText:SetPoint('CENTER')
do
    -- 在继承字体基础上设置字号（GetFont 返回明文路径，无 secret 问题）
    local ok, file = pcall(alertText.GetFont, alertText)
    if ok and file then
        alertText:SetFont(file, 32, 'THICKOUTLINE')
    end
end
alertText:SetTextColor(1, 0.15, 0.15)

-- 帧给足尺寸：零尺寸帧上 CENTER 锚定的字体串在部分渲染路径下不绘制
alertFrame:SetSize(600, 90)

local lastParentHeight = 0
local function PositionAlert()
    local h = UIParent:GetHeight() or 768
    if h == lastParentHeight then return end
    lastParentHeight = h
    alertFrame:ClearAllPoints()
    alertFrame:SetPoint('CENTER', UIParent, 'TOP', 0, -h / 3)
end

-- 语音按判据分条，听声音就能分出是哪一类在响（排查误报时最省事的一招）：
--   'bsGone'  骨盾没了     /  'ossGone' 骨盾层数不够  /  'warn' 骨盾快没了（倒计时到点）。
-- 文件名走 L.kinds[kind].voice —— 中文三条互不相同，英文三条共用 voice-en.mp3。
local function PlayVoice(kind)
    if not DB or not DB.sound then return end
    local path = ('Interface\\AddOns\\%s\\Sounds\\%s'):format(ADDON_NAME, KindOf(kind).voice)
    pcall(PlaySoundFile, path, 'Master')
end

local function HideText()
    state.showingSetup = false
    state.hideAt = nil
    alertFrame:Hide()
    alertFrame:SetScript('OnUpdate', nil)
end

-- 红字文案按判据取（kind 决定写哪一句，见 L.kinds）
local function ShowText(kind)
    if not DB.text then return end
    state.showingSetup = false
    state.hideAt = GetTime() + TEXT_DURATION
    PositionAlert()
    alertText:SetText(KindOf(kind).text)
    alertText:SetTextColor(1, 0.15, 0.15)
    alertText:SetAlpha(0.75)
    alertFrame:Show()
end

-- 配置缺失提示（常驻，黄色，不闪烁；由驱动循环在非战斗时维持）
local function ShowSetupText()
    if not DB.text then return end
    if state.showingSetup then return end   -- 已在显示，避免重复设置
    if alertFrame:IsShown() then return end -- 提醒红字显示期间不抢占（其 showingSetup 必为 false）
    state.showingSetup = true
    state.hideAt = nil
    PositionAlert()
    alertText:SetText(L.setupText)
    alertText:SetTextColor(1, 0.82, 0)
    alertText:SetAlpha(0.75)
    alertFrame:Show()
end

---------------------------------------------------------------- CDM 图标蒙版闪烁
-- 提醒窗口打开时，在 CDM 里的骨盾图标上盖一层脉冲红蒙版。
--
-- 三条硬约束（对方踩过坑的实测结论，照抄）：
--   1) 蒙版帧"永远 Show、只用 alpha 开关"。Hide() 一个 CDM 条目帧的子帧会让 CDM
--      重排帧池 —— 结果就是蒙版自己把脚下的图标掀掉。
--   2) 帧层级取图标自己那一层。暴雪把图标美术放在 ARTWORK 层、把层数挂在子帧
--      Applications 上（子帧无显式层级 ⇒ 自动高一层），所以"盖住图标、不盖住数字"
--      恰好就是图标自己的层级；再加偏移就会盖住层数。
--   3) 池化帧会被回收给别的技能，回收时要停掉它身上的蒙版（见 ScanCdmFrames / CdmState）。
local overlays = setmetatable({}, { __mode = 'k' })   -- 图标帧 -> 我们的蒙版帧

local FLASH_PERIOD = 0.7                       -- 一次明暗周期（秒）
local FLASH_MIN, FLASH_MAX = 0.10, 0.45        -- 蒙版不透明度下限 / 上限

local function EnsureOverlay(f)
    local ov = overlays[f]
    if not ov or ov:GetParent() ~= f then
        ov = CreateFrame('Frame', nil, f)
        ov:EnableMouse(false)
        ov.fill = ov:CreateTexture(nil, 'OVERLAY')
        ov.fill:SetAllPoints()
        ov.fill:SetColorTexture(1, 0.06, 0.06, 1)
        overlays[f] = ov
    end
    ov:SetAllPoints(f)
    local okL, lvl = pcall(f.GetFrameLevel, f)
    if okL and type(lvl) == 'number' then ov:SetFrameLevel(lvl) end
    ov:Show()
    return ov
end

local function FlashPulse(self, elapsed)
    self.__t = (self.__t or 0) + elapsed
    local phase = (self.__t % FLASH_PERIOD) / FLASH_PERIOD
    -- 余弦脉冲：0 -> 1 -> 0，比方波柔和，也不会在切换瞬间闪断
    local k = 0.5 - 0.5 * math.cos(phase * 2 * math.pi)
    self:SetAlpha(FLASH_MIN + (FLASH_MAX - FLASH_MIN) * k)
end

local function StartFlashOn(ov)
    if not ov then return end
    -- alpha 只在"没在闪"、或"被别的插件清成 0"时才拉回下限。
    -- 不能每拍无条件重设：这一拍的 alpha 就是脉冲本身，重设会把波形打回最低点，
    -- 闪起来是一顿一顿的。（FlashPulse 每帧都会重写 alpha，所以被清成 0 也能自愈。）
    local okA, a = pcall(ov.GetAlpha, ov)
    if not ov.__flashing or not okA or type(a) ~= 'number' or a < 0.01 then
        ov:SetAlpha(FLASH_MIN)
    end
    -- 层级和可见性则是每拍都重设：别家换皮插件会把图标的孩子重排、或把我们藏起来
    local okP, par = pcall(ov.GetParent, ov)
    if okP and par then
        local okL, lvl = pcall(par.GetFrameLevel, par)
        if okL and type(lvl) == 'number' then pcall(ov.SetFrameLevel, ov, lvl) end
    end
    ov:Show()
    if ov.__flashing then return end
    ov.__flashing = true
    ov.__t = 0
    ov:SetScript('OnUpdate', FlashPulse)
end

StopFlashOn = function(f)
    if not f then return end
    local ov = overlays[f]
    if not ov then return end
    ov.__flashing = nil
    ov:SetScript('OnUpdate', nil)
    ov:SetAlpha(0)
end

-- 不带短路：只要有蒙版还开着就挨个关。对方在这上面栽过 ——
-- "有没有在闪"的标志位会在某个池化帧消失的一拍变成 false，而某个蒙版仍在闪，
-- 短路之后它就永远关不掉了。一共就一两个蒙版帧，全走一遍的开销可以忽略。
StopAllFlash = function()
    for f in pairs(overlays) do StopFlashOn(f) end
end

local flashWanted = false

-- 与 0.5 秒的 CDM 扫描同拍协调：只在"真的被画出来的骨盾图标"上挂蒙版。
local function UpdateFlash()
    if not flashWanted or not DB or not DB.flash then
        StopAllFlash()
        return
    end
    if #bsFrames == 0 and (GetTime() - lastScan) > 1 then
        ScanCdmFrames()      -- 提醒窗口里骨盾条目还没扫到，节流补扫一次
    end
    for i = 1, #bsFrames do
        local f = bsFrames[i]
        if FrameDrawn(f) then
            StartFlashOn(EnsureOverlay(f))
        else
            StopFlashOn(f)
        end
    end
end

local function SetFlash(on)
    flashWanted = on and true or false
    UpdateFlash()
end

---------------------------------------------------------------- 状态机
-- kind: 'bsGone' = 骨盾没了 / 'ossGone' = 骨盾层数不够 / 'warn' = 骨盾快没了（倒计时到点）。
-- 三个 kind 各自带红字文案与语音（L.kinds），调用点见本文件三处 TriggerAlert。
local function TriggerAlert(kind)
    if state.alerted then return end
    if state.suppressAlertsUntil and GetTime() < state.suppressAlertsUntil then return end
    local now = GetTime()
    -- 刚响过：这次是同一个窗口里另一条判据紧接着成立。半秒内连播两句话纯属噪音，
    -- 所以只吞声音；**文字要换成新判据那一句**（"快没了" → "没了" 是升级信息），
    -- 蒙版也一样 —— 走到这里之前，掉盾那条路已经 ClearWindow() 把红字和蒙版撤掉了；
    -- 不补的话，玩家刚听到一声"骨盾没了"，字和蒙版却同时消失了。
    -- 另外要把窗口标记成"已提醒"：否则下一拍这条判据又会来一次，变成 2 秒后补一枪。
    if state.lastAlertAt and now - state.lastAlertAt < ALERT_GAP then
        state.alerted = true
        ShowText(kind)
        SetFlash(true)
        return
    end
    state.alerted = true
    state.lastAlertAt = now
    state.lastAlertKind = kind        -- 诊断用：哪一类判据真的发了声
    ShowText(kind)
    PlayVoice(kind)
    -- 蒙版跟着窗口走，而不是跟着那 3 秒文字走：文字收了图标还在闪，直到补盾为止
    SetFlash(true)
end

local function ResetWindow()
    state.timerEnd = GetTime() + WARN_AFTER
    state.alerted = false
    state.bsDownSince = nil
    SetFlash(false)
end

local function ClearWindow()
    state.bsUp = false
    state.ossUp = false
    state.timerEnd = 0
    state.alerted = false
    state.refreshUntil = nil   -- 骨盾已经没了，持续刷新窗口随之作废
    state.bsDownSince, state.ossDownSince = nil, nil
    SetFlash(false)
    HideText()
end

-- 由 CDM 帧状态变化驱动
local function UpdateCdmState()
    if not IsBlood() then HideText() SetFlash(false) return end

    -- 条目持续扫不到 = 真的没配置：重置状态，但不打断正在显示的提醒文字
    -- （否则 0.5 秒一拍反复掐掉红字 = 疯狂闪烁）
    if ConfigMissing() then
        state.bsUp, state.ossUp = false, false
        state.timerEnd, state.alerted = 0, false
        state.bsDownSince, state.ossDownSince = nil, nil
        SetFlash(false)
        if not (alertFrame:IsShown() and not state.showingSetup) then
            HideText()
        end
        return
    end

    -- 条目在：若配置提示在显示则撤下（不打断正常提醒文字）
    if state.showingSetup then HideText() end

    local now = GetTime()
    local bsKnown,  bsUp  = CdmState(bsFrames,  BS_ID_SET,      bsProven)
    local ossKnown, ossUp = CdmState(ossFrames, OSSUARY_ID_SET, ossProven)

    -- ---- 骨盾 ----
    if not bsKnown then
        -- 读不到：不下结论。不产生"掉了"事件，也不清掉既有状态；倒计时照走
        -- —— 它本来就是我们唯一能依赖的东西。
    elseif bsUp then
        state.bsDownSince = nil
        if not state.bsUp then
            state.bsUp = true
            ResetWindow()
        end
    elseif state.bsUp then
        -- 读到不在场，但要连续成立 DOWN_GRACE 才认：CDM 重建帧池时，池化帧会短暂读到
        -- 不活跃，拿那一拍当"骨盾没了"，就会在战斗中凭空喊一次补盾。
        -- 刚施放过刷新技能时同理 —— CDM 帧的更新通常晚于施法成功事件，那一拍的
        -- "不在场"同样不算数（否则会把刚点开的倒计时整段掐掉）。
        if state.suppressAlertsUntil and now < state.suppressAlertsUntil then
            state.bsDownSince = nil
        else
            state.bsDownSince = state.bsDownSince or now
            if now - state.bsDownSince >= DOWN_GRACE then
                -- 骨盾消失：战斗中（被消耗/被驱散/手动点掉）立即提醒补盾；
                -- 非战斗中静默（脱战前后掉盾属常态，不打扰）
                local inCombat = InCombatLockdown()
                ClearWindow()   -- 先清理（alerted 复位），保证此次提醒能触发
                if inCombat then TriggerAlert('bsGone') end
                return
            end
        end
    end

    -- ---- 埋骨之所 ----
    if not ossKnown then
        -- 同样不下结论。一个读不到的答案不是一次"掉层"：既不响，也不忘掉自己
        -- 上一拍站在哪一边 —— 这样一次瞬时盲区既造不出假事件，也吞不掉真事件。
    elseif ossUp then
        state.ossDownSince = nil
        state.ossUp = true
    elseif state.ossUp then
        state.ossDownSince = state.ossDownSince or now
        if now - state.ossDownSince >= DOWN_GRACE then
            state.ossUp = false
            -- 埋骨之所消失且骨盾仍在：触发提醒（骨盾在 = 只是层数掉到 5 层以下）
            if state.bsUp then TriggerAlert('ossGone') end
        end
    end
end

---------------------------------------------------------------- 驱动循环（OnUpdate，血 DK 时启用）
-- 不依赖 C_Timer：血 DK 注册 OnUpdate（0.5 秒节流），非血 DK 注销。
-- 每次节流周期：检查倒计时 / 提醒文字超时 / 扫描 CDM / 更新状态 / 协调图标蒙版 /
-- 非战斗时补配置提示。
local driver = CreateFrame('Frame')
driver:Hide()
local lastPulse = 0

driver:SetScript('OnUpdate', function()
    if not DB or not DB.enabled then return end
    local now = GetTime()
    if now - lastPulse < 0.5 then return end
    lastPulse = now

    if not IsBlood() then SetFlash(false) return end

    -- 0. 持续型刷新窗口（目前只有憎恶之肢）：窗口内每秒都在拉怪 → 骨盾被一次次刷新，
    --    倒计时得跟着一路推迟，而不是只在施放那一拍重置一次。窗口长度由
    --    REFRESH_IDS 里那个技能自己的持续时间决定，这里只负责"窗口没走完就不许到点"。
    if state.refreshUntil then
        if now < state.refreshUntil then
            if state.bsUp then state.timerEnd = now + WARN_AFTER end
        else
            state.refreshUntil = nil
        end
    end

    -- 1. 倒计时到点（玩家视角约剩 5 秒）：触发提醒
    if state.bsUp and state.timerEnd > 0 and now >= state.timerEnd then
        TriggerAlert('warn')
    end

    -- 2. 提醒文字超时自动隐藏（3 秒）
    if alertFrame:IsShown() and not state.showingSetup
        and state.hideAt and now >= state.hideAt then
        HideText()
    end

    -- 3. 扫描 CDM 帧 + 更新骨盾/埋骨之所状态
    ScanCdmFrames()
    UpdateCdmState()

    -- 4. 蒙版与扫描同拍协调（图标可能在这一拍才被画出来 / 才消失）
    UpdateFlash()

    -- 5. 非战斗中：CDM 持续未配置则常驻提示；战斗中静默
    if InCombatLockdown() then
        if state.showingSetup then HideText() end
    elseif ConfigMissing() then
        ShowSetupText()
    end
end)

-- 血 DK 时启动驱动，非血 DK / 禁用时停止
local function StartDriver()
    if DB and DB.enabled and IsBlood() then
        driver:Show()
    else
        driver:Hide()
    end
end

---------------------------------------------------------------- 事件
local evt = CreateFrame('Frame')

local function RegisterEvents()
    evt:RegisterEvent('PLAYER_ENTERING_WORLD')
    evt:RegisterEvent('PLAYER_SPECIALIZATION_CHANGED')
    evt:RegisterUnitEvent('UNIT_SPELLCAST_SUCCEEDED', 'player')
end

evt:RegisterEvent('ADDON_LOADED')
evt:SetScript('OnEvent', function(_, event, arg1, _, spellID)
    if event == 'ADDON_LOADED' then
        if arg1 ~= ADDON_NAME then return end
        BloodDeathKnightDB = BloodDeathKnightDB or {}
        for k, v in pairs(DEFAULTS) do
            if BloodDeathKnightDB[k] == nil then BloodDeathKnightDB[k] = v end
        end
        DB = BloodDeathKnightDB
        ApplyLang()

        -- 非死亡骑士职业：插件完全不启用，不注册任何事件
        local ok, _, cls = pcall(UnitClass, 'player')
        if ok and cls ~= 'DEATHKNIGHT' then return end

        RegisterEvents()
        return
    end

    if not DB then return end

    if event == 'PLAYER_ENTERING_WORLD' then
        -- 重新计时：换地图/进本时 CDM 可能要重建帧池，别让上一条目的"最近扫到时间"
        -- 直接过期，否则刚进本就弹一次"未配置"的提示
        bsSeenAt, ossSeenAt = GetTime(), GetTime()
        StartDriver()
        ScanCdmFrames()
        UpdateCdmState()
        return
    end

    if event == 'PLAYER_SPECIALIZATION_CHANGED' then
        if arg1 and arg1 ~= 'player' then return end
        if not IsBlood() then ClearWindow() HideText() end
        StartDriver()
        ScanCdmFrames()
        UpdateCdmState()
        return
    end

    if event == 'UNIT_SPELLCAST_SUCCEEDED' then
        if IsSecret(spellID) then return end
        local win = REFRESH_IDS[spellID]
        if win and IsBlood() then
            HideText()                -- 立即隐藏文字
            state.bsUp = true         -- 施放刷新技能即视为骨盾存在
            ResetWindow()             -- 启用/重置倒计时
            -- CDM 帧更新通常晚于施法成功事件；宽限 0.8 秒，防止下一拍扫描把瞬态空窗误判为骨盾消失
            state.suppressAlertsUntil = GetTime() + 0.8
            -- 持续型（win > 0，目前只有憎恶之肢）：记下窗口，之后由驱动每拍推迟倒计时（见驱动第 0 步）
            state.refreshUntil = (win > 0) and (GetTime() + win) or nil
        end
        return
    end
end)

---------------------------------------------------------------- 诊断：枚举 CDM 全部光环（名字 - ID）
-- 参考 ActionbarEnhanced/Manual.lua：itemFramePool:EnumerateActive() 优先，
-- 无则兜底 GetItemFrames()；cooldownID 直读 frame 字段再兜底 GetCooldownID()。
--
-- 输出粒度是**一个条目一行**，条目携带的全部候选 ID 打在同一行里（cdID 相同的帧只打
-- 一次）。之前的写法是"一个 ID 一行"，于是一条携带 spell+linked 的条目看起来像两条
-- 独立条目 —— 埋骨之所就被误读成"219786 / 219788 两条，得挑对的那条"。
local function DumpCdmAuras()
    print(L.tag, 'CDM auras:')
    local dumped, count = {}, 0
    for v = 1, #ALL_VIEWERS do
        local viewer = _G[ALL_VIEWERS[v]]
        if viewer then
            local frames = {}
            CollectFrames(viewer, frames, {})
            local tag = ALL_VIEWERS[v]:gsub('CooldownViewer', '')
            for i = 1, #frames do
                local f = frames[i]
                local cdID = FrameCdID(f)
                if not cdID then
                    cdID = f.cooldownID or (f.cooldownInfo and f.cooldownInfo.cooldownID)
                    if IsSecret(cdID) then cdID = nil end
                end
                if cdID and not dumped[cdID] then
                    dumped[cdID] = true
                    local cands = CooldownCandidates(cdID)
                    if #cands > 0 then
                        count = count + 1
                        local name = '?'
                        if C_Spell and C_Spell.GetSpellInfo then
                            local okN, si = pcall(C_Spell.GetSpellInfo, cands[1][2])
                            if okN and si and si.name then name = si.name end
                        end
                        -- 标注插件关心的两个光环
                        local mark = ''
                        for k = 1, #cands do
                            local id = cands[k][2]
                            if id == BONE_SHIELD then mark = '  <- BONE_SHIELD'
                            elseif OSSUARY_ID_SET[id] then mark = '  <- OSSUARY' end
                        end
                        print(('  [%s] cdID=%d %s  (%s)%s'):format(
                            tag, cdID, name, JoinCandidates(cands), mark))
                    end
                end
            end
        end
    end
    if count == 0 then
        print('  (no CDM entries found - is anything tracked in the Cooldown Manager?)')
    end
end

---------------------------------------------------------------- 诊断：本插件关心的两个条目的读数
-- 把三态读数的每一层都摊开，用来回答"到底是配置错了、还是读不到"：
--   frames  —— 扫到几个帧
--   cdID    —— 帧对应的 CDM 冷却 ID，可与上面那张表交叉对照
--   ids     —— 该帧命中了关心的哪些 ID，带角色标签。埋骨之所那条会同时列出 spell= 和
--              linked=，一眼看出它是"一个条目的两个 ID"，不是要在两个 ID 之间二选一
--   isActive—— isActive 字段能否读到明文布尔（unreadable = 读不到）
--   proven  —— 有没有被亲眼看到亮过
--   drawn   —— 图标此刻是否被画出来。proven=no 且 drawn=no = 拖进 CDM 了但从未亮过，
--              这条条目不会给插件任何信号（提醒静默失效），该去检查拖的是不是想要的增益
local function FrameMatchedIDs(f, idSet)
    local s = JoinCandidates(CooldownCandidates(FrameCdID(f), idSet))
    return s ~= '' and s or '?'
end

local function DumpTracked()
    print(L.tag, 'tracked entries:')
    local function line(label, list, idSet, proven)
        local n = 0
        for i = 1, #list do if proven[list[i]] then n = n + 1 end end
        print(('  %s: frames=%d proven=%d'):format(label, #list, n))
        for i = 1, #list do
            local f = list[i]
            local flag = FrameFlag(f)
            local cdID = FrameCdID(f)
            print(('    [%d] cdID=%s ids=%s isActive=%s proven=%s drawn=%s'):format(
                i,
                cdID and tostring(cdID) or '?',
                FrameMatchedIDs(f, idSet),
                flag == nil and 'unreadable' or tostring(flag),
                proven[f] and 'yes' or 'no',
                FrameDrawn(f) and 'yes' or 'no'))
        end
    end
    line(L.cdmBs,  bsFrames,  BS_ID_SET,      bsProven)
    line(L.cdmOss, ossFrames, OSSUARY_ID_SET, ossProven)
    print('  (proven=no & drawn=no = that entry has never lit - it will report nothing; check the CDM entry)')
end

-- 条目描述：扫到几个帧，其中几个被亲眼看到亮过
local function TrackDesc(list, proven)
    if #list == 0 then return L.cdmMiss end
    local n = 0
    for i = 1, #list do if proven[list[i]] then n = n + 1 end end
    local s = L.cdmFound .. ' x' .. #list
    if n == 0 then s = s .. L.cdmUnproven end
    return s
end

local function PrintStatus()
    print(L.tag, ('%s | Interface %d'):format(ADDON_NAME, select(4, GetBuildInfo()) or 0))
    print(('  %s: %s | %s: %s | %s: %s | %s: %s'):format(
        L.enabled, DB.enabled and L.on or L.off,
        L.sound, DB.sound and L.on or L.off,
        L.text, DB.text and L.on or L.off,
        L.flash, DB.flash and L.on or L.off))
    print('  ' .. (IsBlood() and L.bloodYes or L.bloodNo))
    print(('  %s: %s | %s: %s'):format(
        L.cdmBs, TrackDesc(bsFrames, bsProven),
        L.cdmOss, TrackDesc(ossFrames, ossProven)))
    local mask = flashWanted and (DB.flash and L.on or L.off) or L.flashIdle
    -- 持续型刷新窗口（憎恶之肢）还开着的话，倒计时是被每拍往后推的，
    -- 单独标出来，免得看到 "timer: 24s left" 不动而以为是卡住了
    if state.refreshUntil and GetTime() < state.refreshUntil then
        print(('  refresh window: %.1fs left (timer held)'):format(state.refreshUntil - GetTime()))
    end
    if state.bsUp and state.timerEnd > 0 then
        print(('  timer: %.1fs left | %s: %s'):format(
            math.max(state.timerEnd - GetTime(), 0), L.flash, mask))
    else
        print(('  timer: idle | %s: %s'):format(L.flash, mask))
    end
    -- 上次提醒是哪一类：听声音之外，这里也能回头看（排查误报时最想知道的一条）
    if state.lastAlertKind then
        print(('  %s: %s (%.0fs ago)'):format(L.lastAlert,
            KindOf(state.lastAlertKind).reason,
            math.max(GetTime() - (state.lastAlertAt or GetTime()), 0)))
    end
end

-- /bdk bs test [1|2|3]：1 = 骨盾没了（默认）、2 = 骨盾层数不够、3 = 骨盾快没了（提前预警）。
local function Test(arg)
    local kind = (arg == '2' and 'ossGone') or (arg == '3' and 'warn') or 'bsGone'
    local idx = 1
    for i = 1, #L.kindOrder do if L.kindOrder[i] == kind then idx = i end end
    local k = KindOf(kind)
    print(L.tag, ('voice %d/3: %s = %s'):format(idx, k.text, k.voice))
    print(L.tag, '  ' .. L.testHint)
    ShowText(kind)
    PlayVoice(kind)
    -- 顺带预览图标蒙版：挂到 CDM 里的骨盾图标上闪 3 秒。
    -- 已经处在真实提醒窗口里就不动它（否则会把正在闪的蒙版提前收掉）。
    if not flashWanted then
        SetFlash(true)
        C_Timer.After(3, function()
            if not state.alerted then SetFlash(false) end
        end)
    end
    -- 自检：帧显示状态 + FontString 实际渲染宽度（=0 说明字形没画出来）+ 字体路径
    local okF, file = pcall(alertText.GetFont, alertText)
    print(L.tag, ('test: shown=%s text=%q strW=%.0f frameW=%.0f alpha=%.2f'):format(
        tostring(alertFrame:IsShown()),
        tostring(alertText:GetText() or ''),
        alertText:GetStringWidth() or -1,
        alertFrame:GetWidth() or -1,
        alertText:GetAlpha() or -1))
    print(L.tag, ('  font=%s flags-not-checked'):format(tostring(okF and file or 'nil')))
    local drawn = 0
    for i = 1, #bsFrames do
        if FrameDrawn(bsFrames[i]) then drawn = drawn + 1 end
    end
    print(L.tag, ('  mask: %s | BS frames=%d drawn=%d'):format(
        flashWanted and L.on or L.off, #bsFrames, drawn))
end

---------------------------------------------------------------- 命令登记
-- 命令表（帮助文案、颜色、参数解析、分发）全在 Commands.lua；这里只登记本模块
-- 做得了什么。加功能不必再碰主命令的分发逻辑。
local CMD = _G.BloodDeathKnightCmd
if not CMD then
    CMD = {}
    _G.BloodDeathKnightCmd = CMD
end

-- /bdk bs test —— 把提醒的三种表现各来一遍（红字 + 语音 + 图标蒙版 3 秒），
-- 顺带打印帧/字体的自检数字。CDM 没配也能看样式。
CMD[#CMD + 1] = {
    name = 'bs test', arg = true,
    order = 1,
    zh   = '测试骨盾监控',
    en   = 'test the bone shield monitor',
    run  = function(arg)
        if not IsBlood() then
            print(L.tag, L.bloodNo)
            return
        end
        Test(arg)
    end,
}

-- /bdk bs sound —— 语音开关；不带参数就翻面（命令名说的是"切换"）
CMD[#CMD + 1] = {
    name = 'bs sound', arg = true,
    order = 2,
    zh   = '切换是否启用骨盾语音',
    en   = 'toggle the bone shield voice',
    run  = function(arg)
        local on
        if arg == nil then on = not DB.sound
        elseif arg == 'on' or arg == '开' then on = true
        elseif arg == 'off' or arg == '关' then on = false
        else
            print(L.tag, (L.usage):format('bs sound'))
            return
        end
        DB.sound = on
        print(L.tag, L.sound .. ': ' .. (on and L.on or L.off))
    end,
}

-- /bdk debug —— 隐藏命令（帮助里不显示，避免玩家误按）：两个模块各登记一条，
-- 分发器会把两条都跑完，"唯一调试指令"因此能一次摊开全部诊断。
CMD[#CMD + 1] = {
    name   = 'debug',
    hidden = true,
    run    = function()
        PrintStatus()
        DumpCdmAuras()
        DumpTracked()
    end,
}
