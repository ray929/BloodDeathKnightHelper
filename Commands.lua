--==============================================================================
-- Commands.lua —— 斜杠命令表（唯一入口 /bdk）
--
-- 为什么单独一个文件：命令是"玩家怎么跟插件说话"这件事的唯一定义处 —— 帮助文案、
-- 颜色、参数解析、同名命令的执行顺序都在这里。功能模块不再自己解析字符串，只负责
-- 往表里登记"我能做什么"，所以加一个功能不会再把主命令的分发逻辑改出一道口子。
--
-- 登记方式（模块自己文件里，加载顺序无关；toc 里 Commands.lua 排在最前）：
--
--   local CMD = _G.BloodDeathKnightCmd   -- Commands.lua 已经建好
--   CMD[#CMD + 1] = {
--       name   = 'bs sound',             -- 子命令，不含 /bdk
--       arg    = true,                   -- 允许后面跟一个参数
--       argZh  = '数字', argEn = 'number', -- 可选：帮助里显示的占位词（不写就不显示）
--       zh     = '切换是否启用骨盾语音',  -- 帮助里的说明（两种语言各一句）
--       en     = 'toggle the bone shield voice',
--       run    = function(arg) ... end,  -- arg 为 nil = 不带参数
--       order  = 2,                      -- 可选：帮助里同组内的先后（小的在前，缺省 100）
--       hidden = false,                  -- true = 不进帮助（调试命令走这条）
--   }
--
-- 帮助里的分组按子命令第一段（bp / bs / …）自动分，组名按字母排，组内按 order 排 ——
-- 每个模块只管自己那几条的先后，不必和别的模块商量一个全局编号。
--
-- 同一个 name 可以登记多条：/bdk debug 就是两个模块各登记一条，两条都会跑 ——
-- "唯一调试指令"要能一次把两个模块的诊断都摊开。
--==============================================================================

local _G = _G
local print = print
local table_sort = table.sort
local strrep, strsub, strbyte = string.rep, string.sub, string.byte
local format = string.format

-- 语言强制跟随客户端：不再有 /bdk lang。玩家换客户端语种就换语言，这是最不需要
-- 解释的行为 —— 一个开关只会让人怀疑自己的中文客户端为什么是英文。
local ZH = (GetLocale() or ''):sub(1, 2) == 'zh'
local function T(zh, en) if ZH then return zh end return en end

local TAG = ZH and '|cff71d5ff[鲜血死亡骑士]|r' or '|cff71d5ff[BloodDeathKnight]|r'

-- 帮助里只用两种颜色：命令一色、说明一色。段级标题、分组标签都不再引入第三种，
-- 一排排看下来才像一张表，而不是一堵彩色墙。
local C_CMD  = '|cffffd100'   -- 命令：金
local C_DESC = '|cff9d9d9d'   -- 说明：灰
local C_END  = '|r'

---------------------------------------------------------------- 注册表
local CMD = _G.BloodDeathKnightCmd
if not CMD then
    CMD = {}
    _G.BloodDeathKnightCmd = CMD
end

---------------------------------------------------------------- 帮助排版
-- 命令列要按"显示宽度"对齐，不能用 #s 或字节数：WoW 的中文字形是双宽，而
-- `bp width 数字` 这一条两边混着 ASCII 和汉字，按字符数补空格会歪半格到一格。
local function DispWidth(s)
    local w, i, n = 0, 1, #s
    while i <= n do
        local b = strbyte(s, i)
        if b < 0x80 then
            w = w + 1
            i = i + 1
        else
            local cp, len
            if b < 0xE0 then cp, len = b - 0xC0, 2
            elseif b < 0xF0 then cp, len = b - 0xE0, 3
            else cp, len = b - 0xF0, 4 end
            for k = 1, len - 1 do
                local c = strbyte(s, i + k)
                if c then cp = cp * 64 + (c - 0x80) end
            end
            -- 全角区段（中日韩、全角标点）算两列，其余算一列
            local wide = (cp >= 0x1100 and cp <= 0x115F)
                or cp == 0x2329 or cp == 0x232A
                or (cp >= 0x2E80 and cp <= 0xA4CF)
                or (cp >= 0xAC00 and cp <= 0xD7A3)
                or (cp >= 0xF900 and cp <= 0xFAFF)
                or (cp >= 0xFE30 and cp <= 0xFE6F)
                or (cp >= 0xFF00 and cp <= 0xFF60)
                or (cp >= 0xFFE0 and cp <= 0xFFE6)
            w = w + (wide and 2 or 1)
            i = i + len
        end
    end
    return w
end

local function PrintHelp()
    -- 第一行永远是 /bdk 本身。其余的分组显示：组名（子命令的第一段，bp / bs / …）
    -- 按字母排，**组内顺序由模块自己用 order 定** —— 这样每个模块只管自己那几条
    -- 的先来后到，不需要和别的模块商量一个全局编号。
    local rows = { { label = '/bdk', desc = T('显示帮助信息', 'show this help') } }
    local shown = {}
    for i = 1, #CMD do
        local e = CMD[i]
        if e.name and e.name ~= '' and not e.hidden then
            shown[#shown + 1] = e
            e.__group = e.name:match('^(%S+)') or e.name
        end
    end
    table_sort(shown, function(a, b)
        if a.__group ~= b.__group then return a.__group < b.__group end
        local ao, bo = a.order or 100, b.order or 100
        if ao ~= bo then return ao < bo end
        return a.name < b.name
    end)
    local group
    for i = 1, #shown do
        local e = shown[i]
        if group and e.__group ~= group then
            rows[#rows + 1] = { blank = true }   -- 换组空一行，扫一眼就知道有几摊事
        end
        group = e.__group
        local label = '/bdk ' .. e.name
        if e.arg then
            -- 占位词只在模块明确给了 argZh/argEn 时才显示：命令本来就能带参数、但帮助
            -- 里不必每条都挂一个参数说明（"切换"类命令裸着打就够用）。
            local hint = ZH and e.argZh or e.argEn
            if hint then label = label .. ' ' .. hint end
        end
        rows[#rows + 1] = { label = label, desc = T(e.zh or '', e.en or '') }
    end

    local maxw = 0
    for i = 1, #rows do
        if rows[i].label then
            rows[i].w = DispWidth(rows[i].label)
            if rows[i].w > maxw then maxw = rows[i].w end
        end
    end

    print(TAG .. ' ' .. T('命令：', 'commands:'))
    for i = 1, #rows do
        if rows[i].blank then
            print('')
        else
            print('  ' .. C_CMD .. rows[i].label .. C_END
                .. strrep(' ', maxw - rows[i].w + 2)
                .. C_DESC .. rows[i].desc .. C_END)
        end
    end
end

---------------------------------------------------------------- 分发
-- 单独导出（不藏在 SlashCmdList 里）是为了能离线测：测试直接调它，走的是和游戏里
-- 一模一样的那条路 —— 包括帮助排版。
-- 返回 true = 有命令认领；false = 没这条命令（会打一行提示 + 帮助）。
function _G.BloodDeathKnightDispatch(msg)
    msg = (msg or ''):lower():gsub('%s+', ' '):gsub('^%s+', ''):gsub('%s+$', '')

    if msg == '' or msg == 'help' then
        PrintHelp()
        return true
    end

    local matched = false
    for i = 1, #CMD do
        local e = CMD[i]
        local name = e.name
        if name and name ~= '' and e.run then
            local hit, arg = false, nil
            if msg == name then
                hit = true
            elseif e.arg then
                local pfx = name .. ' '
                if strsub(msg, 1, #pfx) == pfx then
                    hit = true
                    arg = strsub(msg, #pfx + 1)
                    if arg == '' then arg = nil end
                end
            end
            if hit then
                matched = true
                e.run(arg)
            end
        end
    end

    if matched then return true end

    print(TAG .. ' ' .. format(T('没有这条命令：%s', 'no such command: %s'), msg))
    PrintHelp()
    return false
end

---------------------------------------------------------------- 斜杠命令
-- 只注册一个入口 /bdk —— 命令表、帮助、分发三者同名，玩家只需要记一个；再挂一个旧别名
-- 只会让人以为"那个才是正式的"。旧别名 /bsr 已于 2026-09-17 移除，测试里有断言挡着。
SLASH_BLOODDEATHKNIGHT1 = '/bdk'
function SlashCmdList.BLOODDEATHKNIGHT(msg)
    -- 存档还没到（ADDON_LOADED 之前）什么都不做：模块的设置都在里面
    if not _G.BloodDeathKnightDB then return end
    _G.BloodDeathKnightDispatch(msg)
end
