-- BloodDeathKnight 鲜血死亡骑士辅助
-- 鲜血死亡骑士（Blood DK）辅助插件（正式服 12.1）
--
-- 当前功能：骨盾 / 埋骨之所 监控提醒
--   触发逻辑（事件驱动，纯 CDM 实现，不使用 C_UnitAuras）：
--   1. 骨盾存在时启动 25 秒倒计时（骨盾固定持续 30 秒），到点时语音+文字 3 秒提醒一次；
--   2. 埋骨之所（Ossuary，骨盾 >= 5 层增益）消失时语音+文字 3 秒提醒一次；
--   3. 施放任意会产生/刷新骨盾的技能时，立即隐藏文字并重置倒计时；
--   4. 骨盾彻底消失时停止一切提醒。
--
-- 前提条件：玩家需把「骨盾」和「埋骨之所」拖入暴雪冷却管理器（CDM）。
-- 若未检测到对应 CDM 条目，屏幕 1/3 处常驻提示文字，指导玩家配置。
--
-- 12.x 环境限制应对：
--   * 光环数据（层数/时间）在战斗中是 secret，本插件从不读取；
--   * 存在性判断完全依赖 CDM 光环图标的 IsActive() / IsShown+alpha
--     （暴雪自己消费 secret 后落地的明文布尔）；
--   * 骨盾固定 30 秒，用 25 秒倒计时覆盖最危险的最后 5 秒窗口。

local ADDON_NAME = ...

---------------------------------------------------------------- 常量
local BONE_SHIELD  = 195181   -- 骨盾
local OSSUARY      = 219786   -- 埋骨之所（常规 ID）
local OSSUARY_ALT  = 219788   -- 埋骨之所（12.1 部分环境下实际出现的 ID）
local WARN_AFTER   = 25       -- 骨盾存在 25 秒时提醒（覆盖最后 5 秒）
local TEXT_DURATION = 3       -- 提醒文字显示时长

-- 会产生/刷新骨盾的技能
local REFRESH_IDS = {
    [195182] = true,  -- 骨髓打击 Marrowrend
    [195292] = true,  -- 死亡之攫 Death's Caress
    [108199] = true,  -- 腐烂之握 Gorefiend's Grasp
    [49028]  = true,  -- 符文武器幻舞 Dancing Rune Weapon
    [439843] = true,  -- 12.x 可能加骨盾层数的变体
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
    local lang = DB and DB.lang or 'auto'
    local zh
    if lang == 'cn' then zh = true
    elseif lang == 'en' then zh = false
    else zh = (LOCALE:sub(1, 2) == 'zh') end

    if zh then
        L.soundLang = 'cn'
        L.alertText = '补骨盾'
        L.setupText = '请将「骨盾」和「埋骨之所」拖入冷却管理器 (CDM)'
        L.tag = '|cff71d5ff[鲜血死亡骑士]|r'
        L.on, L.off = '开', '关'
        L.enabled = '插件'
        L.sound = '语音'
        L.text = '文字'
        L.langName = '语言'
        L.langAuto, L.langCn, L.langEn = '跟随客户端', '中文', '英语'
        L.help = '/bdk test 预览；/bdk dump 枚举CDM光环；/bdk sound on|off 语音；/bdk text on|off 文字；'
            .. '/bdk lang auto|cn|en 语言；/bdk enable on|off 总开关'
        L.bloodYes, L.bloodNo = '鲜血死亡骑士', '非鲜血死亡骑士（插件待机）'
        L.cdmBs, L.cdmOss = '骨盾(CDM)', '埋骨之所(CDM)'
        L.cdmFound, L.cdmMiss = '已监控', '缺失'
    else
        L.soundLang = 'en'
        L.alertText = 'Bone Shield!'
        L.setupText = 'Drag "Bone Shield" and "Ossuary" into the Cooldown Manager (CDM)'
        L.tag = '|cff71d5ff[BloodDeathKnight]|r'
        L.on, L.off = 'on', 'off'
        L.enabled = 'addon'
        L.sound = 'voice'
        L.text = 'text'
        L.langName = 'language'
        L.langAuto, L.langCn, L.langEn = 'auto (client)', 'Chinese', 'English'
        L.help = '/bdk test preview; /bdk dump list CDM auras; /bdk sound on|off voice; /bdk text on|off text; '
            .. '/bdk lang auto|cn|en language; /bdk enable on|off master toggle'
        L.bloodYes, L.bloodNo = 'Blood Death Knight', 'not Blood DK (addon idle)'
        L.cdmBs, L.cdmOss = 'Bone Shield (CDM)', 'Ossuary (CDM)'
        L.cdmFound, L.cdmMiss = 'tracked', 'missing'
    end
end

---------------------------------------------------------------- 设置
local DB
local DEFAULTS = {
    enabled = true,
    sound   = true,
    text    = true,
    lang    = 'auto',
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

local function FrameIsSpell(f, ids)
    if not f or not f.GetCooldownID then return false end
    local ok, id = pcall(f.GetCooldownID, f)
    if ok and id then return CooldownMatches(id, ids) end
    return false
end

local function FrameActive(f)
    if f.IsActive then
        local ok, a = pcall(f.IsActive, f)
        if ok and a ~= nil and not IsSecret(a) and type(a) == 'boolean' then
            return a
        end
    end
    local ok, shown = pcall(f.IsShown, f)
    if not ok or not shown then return false end
    local okA, alpha = pcall(f.GetAlpha, f)
    if okA and type(alpha) == 'number' and alpha < 0.05 then return false end
    return true
end

---------------------------------------------------------------- CDM 帧池
-- CDM 的 buff 配置条目帧是常驻的（不随 buff 消失而释放，IsActive 才反映 buff 状态），
-- 所以帧列表为空 = 用户没把条目拖进 CDM。
local bsFrames, ossFrames = {}, {}

local function AddFrame(list, f)
    for i = 1, #list do if list[i] == f then return end end
    list[#list + 1] = f
end

-- 多源收集 viewer 的 item 帧（参考 ActionbarEnhanced/Manual.lua）：
-- 1) itemFramePool:EnumerateActive —— 池化活动帧（含被隐藏的，最可靠）；
-- 2) GetItemFrames —— 布局子帧（仅可见帧）。
-- 注：item frame 实际挂在 itemContainerFrame 下，GetChildren 只能拿到 viewer 直接子帧，兜底无效，已移除。
local function CollectFrames(viewer, found, seen)
    if not viewer then return end
    if viewer.itemFramePool and viewer.itemFramePool.EnumerateActive then
        local ok, iter = pcall(viewer.itemFramePool.EnumerateActive, viewer.itemFramePool)
        if ok and iter then
            for f in iter do
                if f and not seen[f] then seen[f] = true; found[#found + 1] = f end
            end
        end
    end
    if viewer.GetItemFrames then
        local ok, frames = pcall(viewer.GetItemFrames, viewer)
        if ok and type(frames) == 'table' then
            for i = 1, #frames do
                local f = frames[i]
                if f and not seen[f] then seen[f] = true; found[#found + 1] = f end
            end
        end
    end
end

-- 全量扫描 CDM 帧（周期调用 + 事件触发调用）
local function ScanCdmFrames()
    -- 先清理池化帧（池化复用的帧可能已换绑其他技能）
    for i = #bsFrames, 1, -1 do
        if not FrameIsSpell(bsFrames[i], BS_ID_SET) then table.remove(bsFrames, i) end
    end
    for i = #ossFrames, 1, -1 do
        if not FrameIsSpell(ossFrames[i], OSSUARY_ID_SET) then table.remove(ossFrames, i) end
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
end

local function CdmUp(list)
    if #list == 0 then return false end
    for i = 1, #list do
        if FrameActive(list[i]) then return true end
    end
    return false
end

---------------------------------------------------------------- 状态（提前声明供界面函数引用）
local state = {
    bsUp = false,      -- 骨盾当前是否存在
    ossUp = false,     -- 埋骨之所当前是否存在
    timerEnd = 0,      -- 25 秒倒计时结束时间
    alerted = false,   -- 当前窗口是否已经触发过提醒
    showingSetup = false,  -- 当前显示的是配置提示还是提醒
    hideAt = nil,      -- 提醒文字自动隐藏时间（由驱动循环检查）
    suppressAlertsUntil = nil, -- 施放刷新技能后的宽限期，避免 CDM 更新延迟导致误报
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

local function PlayVoice()
    if not DB or not DB.sound then return end
    local path = ('Interface\\AddOns\\%s\\Sounds\\voice-%s.mp3')
        :format(ADDON_NAME, L.soundLang)
    pcall(PlaySoundFile, path, 'Master')
end

local function HideText()
    state.showingSetup = false
    state.hideAt = nil
    alertFrame:Hide()
    alertFrame:SetScript('OnUpdate', nil)
end

local function ShowText()
    if not DB.text then return end
    state.showingSetup = false
    state.hideAt = GetTime() + TEXT_DURATION
    PositionAlert()
    alertText:SetText(L.alertText)
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

---------------------------------------------------------------- 状态机
local function TriggerAlert()
    if state.alerted then return end
    if state.suppressAlertsUntil and GetTime() < state.suppressAlertsUntil then return end
    state.alerted = true
    ShowText()
    PlayVoice()
end

local function ResetWindow()
    state.timerEnd = GetTime() + WARN_AFTER
    state.alerted = false
end

local function ClearWindow()
    state.bsUp = false
    state.ossUp = false
    state.timerEnd = 0
    state.alerted = false
    HideText()
end

-- 由 CDM 帧状态变化驱动
local function UpdateCdmState()
    if not IsBlood() then HideText() return end

    -- CDM 缺少骨盾/埋骨之所任一条目（帧为空=未配置）：
    -- 重置状态，但不打断正在显示的提醒文字（否则 0.5 秒一拍反复掐掉红字 = 疯狂闪烁）
    if #bsFrames == 0 or #ossFrames == 0 then
        state.bsUp, state.ossUp = false, false
        state.timerEnd, state.alerted = 0, false
        if not (alertFrame:IsShown() and not state.showingSetup) then
            HideText()
        end
        return
    end

    -- CDM 条目存在：若配置提示在显示则撤下（不打断正常提醒文字）
    if state.showingSetup then HideText() end

    local bsUp = CdmUp(bsFrames)
    local ossUp = CdmUp(ossFrames)

    if bsUp and not state.bsUp then
        state.bsUp = true
        ResetWindow()
    elseif not bsUp and state.bsUp then
        -- 骨盾消失：战斗中（被消耗/被驱散/手动点掉）立即提醒补盾；
        -- 非战斗中静默（脱战前后掉盾属常态，不打扰）
        local inCombat = InCombatLockdown()
        ClearWindow()   -- 先清理（alerted 复位），保证此次提醒能触发
        if inCombat then TriggerAlert() end
        return
    end

    if ossUp and not state.ossUp then
        state.ossUp = true
    elseif not ossUp and state.ossUp then
        state.ossUp = false
        -- 埋骨之所消失且骨盾仍在：触发提醒
        if state.bsUp then TriggerAlert() end
    end
end

---------------------------------------------------------------- 驱动循环（OnUpdate，血 DK 时启用）
-- 不依赖 C_Timer：血 DK 注册 OnUpdate（0.5 秒节流），非血 DK 注销。
-- 每次节流周期：检查倒计时 / 提醒文字超时 / 扫描 CDM / 更新状态 / 非战斗时补配置提示。
local driver = CreateFrame('Frame')
driver:Hide()
local lastPulse = 0

driver:SetScript('OnUpdate', function()
    if not DB or not DB.enabled then return end
    local now = GetTime()
    if now - lastPulse < 0.5 then return end
    lastPulse = now

    if not IsBlood() then return end

    -- 1. 25 秒倒计时到点：触发提醒
    if state.bsUp and state.timerEnd > 0 and now >= state.timerEnd then
        TriggerAlert()
    end

    -- 2. 提醒文字超时自动隐藏（3 秒）
    if alertFrame:IsShown() and not state.showingSetup
        and state.hideAt and now >= state.hideAt then
        HideText()
    end

    -- 3. 扫描 CDM 帧 + 更新骨盾/埋骨之所状态
    ScanCdmFrames()
    UpdateCdmState()

    -- 4. 非战斗中：CDM 未配置则常驻提示；战斗中静默
    if InCombatLockdown() then
        if state.showingSetup then HideText() end
    elseif #bsFrames == 0 or #ossFrames == 0 then
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
        if REFRESH_IDS[spellID] and IsBlood() then
            HideText()                -- 立即隐藏文字
            state.bsUp = true         -- 施放刷新技能即视为骨盾存在
            ResetWindow()             -- 启用/重置 25 秒倒计时
            -- CDM 帧更新通常晚于施法成功事件；宽限 0.8 秒，防止下一拍扫描把瞬态空窗误判为骨盾消失
            state.suppressAlertsUntil = GetTime() + 0.8
        end
        return
    end
end)

---------------------------------------------------------------- 命令
local function LangName()
    local lang = DB.lang or 'auto'
    if lang == 'cn' then return L.langCn end
    if lang == 'en' then return L.langEn end
    return L.langAuto
end

---------------------------------------------------------------- 诊断：枚举 CDM 全部光环（名字 - ID）
-- 参考 ActionbarEnhanced/Manual.lua：itemFramePool:EnumerateActive() 优先，
-- 无则兜底 GetItemFrames()；cooldownID 直读 frame 字段再兜底 GetCooldownID()。
local function DumpCdmAuras()
    print(L.tag, 'CDM auras:')
    local seen, count = {}, 0
    for v = 1, #ALL_VIEWERS do
        local viewer = _G[ALL_VIEWERS[v]]
        if viewer then
            -- 收集活动帧
            local frames
            if viewer.itemFramePool and viewer.itemFramePool.EnumerateActive then
                local ok, iter = pcall(viewer.itemFramePool.EnumerateActive, viewer.itemFramePool)
                if ok and iter then
                    frames = {}
                    for f in iter do frames[#frames + 1] = f end
                end
            end
            if not frames and viewer.GetItemFrames then
                local ok, fr = pcall(viewer.GetItemFrames, viewer)
                if ok and type(fr) == 'table' then frames = fr end
            end

            if frames then
                for i = 1, #frames do
                    local f = frames[i]
                    local cdID = f.cooldownID or (f.cooldownInfo and f.cooldownInfo.cooldownID)
                    if not cdID and f.GetCooldownID then
                        local ok, id = pcall(f.GetCooldownID, f)
                        if ok then cdID = id end
                    end
                    if cdID and not IsSecret(cdID)
                        and C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo then
                        local ok, info = pcall(C_CooldownViewer.GetCooldownViewerCooldownInfo, cdID)
                        if ok and info then
                            -- 收集全部候选 ID（spellID/override/tooltip/linked）
                            local ids = {}
                            local function add(id)
                                if id and id > 0 and not IsSecret(id) and not seen[id] then
                                    seen[id] = true
                                    ids[#ids + 1] = id
                                end
                            end
                            add(info.spellID)
                            add(info.overrideSpellID)
                            add(info.overrideTooltipSpellID)
                            add(info.linkedSpellID)
                            if type(info.linkedSpellIDs) == 'table' then
                                for _, id in ipairs(info.linkedSpellIDs) do add(id) end
                            end

                            for j = 1, #ids do
                                local id = ids[j]
                                if not seen['__dumped' .. id] then
                                    seen['__dumped' .. id] = true
                                    count = count + 1
                                    local name = '?'
                                    if C_Spell and C_Spell.GetSpellInfo then
                                        local okN, si = pcall(C_Spell.GetSpellInfo, id)
                                        if okN and si and si.name then name = si.name end
                                    end
                                    -- 标注插件关心的两个光环
                                    local mark = ''
                                    if id == BONE_SHIELD then mark = '  <- BONE_SHIELD' end
                                    if OSSUARY_ID_SET[id] then mark = '  <- OSSUARY' end
                                    print(('  [%s] %s - %d%s'):format(
                                        ALL_VIEWERS[v]:gsub('CooldownViewer', ''), name, id, mark))
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    if count == 0 then
        print('  (no CDM entries found - is anything tracked in the Cooldown Manager?)')
    end
end

local function PrintStatus()
    print(L.tag, ('%s | Interface %d'):format(ADDON_NAME, select(4, GetBuildInfo()) or 0))
    print(('  %s: %s | %s: %s | %s: %s | %s: %s'):format(
        L.enabled, DB.enabled and L.on or L.off,
        L.sound, DB.sound and L.on or L.off,
        L.text, DB.text and L.on or L.off,
        L.langName, LangName()))
    print('  ' .. (IsBlood() and L.bloodYes or L.bloodNo))
    print(('  %s: %s | %s: %s'):format(
        L.cdmBs, #bsFrames > 0 and (L.cdmFound .. ' x' .. #bsFrames) or L.cdmMiss,
        L.cdmOss, #ossFrames > 0 and (L.cdmFound .. ' x' .. #ossFrames) or L.cdmMiss))
    if state.bsUp and state.timerEnd > 0 then
        print(('  timer: %.1fs left'):format(math.max(state.timerEnd - GetTime(), 0)))
    else
        print('  timer: idle')
    end
    print('  ' .. L.help)
end

local function Test()
    ShowText()
    PlayVoice()
    -- 自检：帧显示状态 + FontString 实际渲染宽度（=0 说明字形没画出来）+ 字体路径
    local okF, file = pcall(alertText.GetFont, alertText)
    print(L.tag, ('test: shown=%s text=%q strW=%.0f frameW=%.0f alpha=%.2f'):format(
        tostring(alertFrame:IsShown()),
        tostring(alertText:GetText() or ''),
        alertText:GetStringWidth() or -1,
        alertFrame:GetWidth() or -1,
        alertText:GetAlpha() or -1))
    print(L.tag, ('  font=%s flags-not-checked'):format(tostring(okF and file or 'nil')))
end

-- 主命令 /bdk；/bsr 保留为旧名兼容别名
SLASH_BLOODDEATHKNIGHT1 = '/bdk'
SLASH_BLOODDEATHKNIGHT2 = '/bsr'
function SlashCmdList.BLOODDEATHKNIGHT(msg)
    if not DB then return end
    msg = (msg or ''):lower():gsub('%s+', ' '):gsub('^%s+', ''):gsub('%s+$', '')

    if msg == '' or msg == 'help' or msg == '状态' then
        PrintStatus()
    elseif msg == 'dump' or msg == '枚举' then
        DumpCdmAuras()
    elseif msg == 'test' or msg == '测试' then
        Test()
    elseif msg == 'sound on' or msg == '语音开' then
        DB.sound = true; print(L.tag, L.sound .. ': ' .. L.on)
    elseif msg == 'sound off' or msg == '语音关' then
        DB.sound = false; print(L.tag, L.sound .. ': ' .. L.off)
    elseif msg == 'text on' or msg == '文字开' then
        DB.text = true; print(L.tag, L.text .. ': ' .. L.on)
    elseif msg == 'text off' or msg == '文字关' then
        DB.text = false; HideText(); print(L.tag, L.text .. ': ' .. L.off)
    elseif msg == 'lang auto' or msg == 'lang cn' or msg == 'lang en' then
        DB.lang = msg:match('(%a+)%s*$')
        ApplyLang()
        print(L.tag, L.langName .. ': ' .. LangName())
    elseif msg == 'enable on' or msg == '启用' then
        DB.enabled = true; StartDriver(); print(L.tag, L.enabled .. ': ' .. L.on)
    elseif msg == 'enable off' or msg == '禁用' then
        DB.enabled = false; driver:Hide(); ClearWindow(); HideText(); print(L.tag, L.enabled .. ': ' .. L.off)
    else
        print(L.tag, L.help)
    end
end
