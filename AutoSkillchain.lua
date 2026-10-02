_addon.name = 'AutoSkillchain'
_addon.author = 'Gemini Notebook'
_addon.version = '5.1'
_addon.commands = {'sc', 'autoskillchain', 'autosc'}

local config = require('config')
local res = require('resources')
local files = require('files')
pcall(require, 'luau')
pcall(require, 'chat')

local json_ok, json = pcall(require, 'json')

local defaults = {
    enabled = true,
    party_mode = true,
    solo_mode = true,
    delay_seconds = 6.0,
    block_seconds = 1.5,
    active_route = 1,
    fallback_to_auto = true,
    debug = false,
}

local settings = config.load(defaults)

-- UTF-8 -> Shift-JIS 安全変換ヘルパー
local function sjis(s)
    if not s or s == '' then return '' end
    local ok, converted = pcall(windower.to_shift_jis, s)
    if ok and converted and converted ~= '' then
        return converted
    end
    return s
end

local function msg(s, c)
    windower.add_to_chat(c or 207, sjis('[AutoSkillchain] ' .. tostring(s)))
end

-- デフォルト JSON 完全データ (json.encode を使わず固定安全文字列として保持)
local default_json_raw = [[{
  "active_route": 1,
  "routes": [
    {
      "id": 1,
      "name": "鳳蝶 -> 陣風 -> 照破 -> 照破 -> 花車 -> 不動 (6段光連携)",
      "mode": "custom",
      "delay_seconds": 6.0,
      "steps": [
        { "step": 1, "trigger_ws": "十一之太刀・鳳蝶", "action_ws": "五之太刀・陣風",   "sc_result": "炸裂" },
        { "step": 2, "trigger_ws": "五之太刀・陣風",   "action_ws": "十二之太刀・照破", "sc_result": "重力" },
        { "step": 3, "trigger_ws": "十二之太刀・照破", "action_ws": "十二之太刀・照破", "sc_result": "分解" },
        { "step": 4, "trigger_ws": "十二之太刀・照破", "action_ws": "九之太刀・花車",   "sc_result": "核熱" },
        { "step": 5, "trigger_ws": "九之太刀・花車",   "action_ws": "祖之太刀・不動",   "sc_result": "光" }
      ]
    },
    {
      "id": 2,
      "name": "鳳蝶 -> 陣風 -> 照破 -> 不動 (4段闇連携)",
      "mode": "custom",
      "delay_seconds": 6.0,
      "steps": [
        { "step": 1, "trigger_ws": "十一之太刀・鳳蝶", "action_ws": "五之太刀・陣風",   "sc_result": "炸裂" },
        { "step": 2, "trigger_ws": "五之太刀・陣風",   "action_ws": "十二之太刀・照破", "sc_result": "重力" },
        { "step": 3, "trigger_ws": "十二之太刀・照破", "action_ws": "祖之太刀・不動",   "sc_result": "闇" }
      ]
    },
    {
      "id": 3,
      "name": "照破 -> 花車 -> 不動 (3段光連携)",
      "mode": "custom",
      "delay_seconds": 6.0,
      "steps": [
        { "step": 1, "trigger_ws": "十二之太刀・照破", "action_ws": "九之太刀・花車",   "sc_result": "核熱" },
        { "step": 2, "trigger_ws": "九之太刀・花車",   "action_ws": "祖之太刀・不動",   "sc_result": "光" }
      ]
    },
    {
      "id": 4,
      "name": "照破 -> 不動 (2段光連携)",
      "mode": "custom",
      "delay_seconds": 6.0,
      "steps": [
        { "step": 1, "trigger_ws": "十二之太刀・照破", "action_ws": "祖之太刀・不動",   "sc_result": "光" }
      ]
    },
    {
      "id": 5,
      "name": "雪風 -> 月光 -> 乱鴉 (3段重力連携)",
      "mode": "custom",
      "delay_seconds": 6.0,
      "steps": [
        { "step": 1, "trigger_ws": "七之太刀・雪風",   "action_ws": "八之太刀・月光",   "sc_result": "湾曲" },
        { "step": 2, "trigger_ws": "八之太刀・月光",   "action_ws": "十之太刀・乱鴉",   "sc_result": "重力" }
      ]
    },
    {
      "id": 6,
      "name": "全自動AIソルバー (Auto Solver)",
      "mode": "auto",
      "delay_seconds": 6.0,
      "steps": []
    }
  ]
}]]

-- デフォルトメモリテーブル構造
local default_routes_data = {
    active_route = 1,
    routes = {
        {
            id = 1,
            name = '鳳蝶 -> 陣風 -> 照破 -> 照破 -> 花車 -> 不動 (6段光連携)',
            mode = 'custom',
            delay_seconds = 6.0,
            steps = {
                { step = 1, trigger_ws = '十一之太刀・鳳蝶', action_ws = '五之太刀・陣風',   sc_result = '炸裂' },
                { step = 2, trigger_ws = '五之太刀・陣風',   action_ws = '十二之太刀・照破', sc_result = '重力' },
                { step = 3, trigger_ws = '十二之太刀・照破', action_ws = '十二之太刀・照破', sc_result = '分解' },
                { step = 4, trigger_ws = '十二之太刀・照破', action_ws = '九之太刀・花車',   sc_result = '核熱' },
                { step = 5, trigger_ws = '九之太刀・花車',   action_ws = '祖之太刀・不動',   sc_result = '光' }
            }
        },
        {
            id = 2,
            name = '鳳蝶 -> 陣風 -> 照破 -> 不動 (4段闇連携)',
            mode = 'custom',
            delay_seconds = 6.0,
            steps = {
                { step = 1, trigger_ws = '十一之太刀・鳳蝶', action_ws = '五之太刀・陣風',   sc_result = '炸裂' },
                { step = 2, trigger_ws = '五之太刀・陣風',   action_ws = '十二之太刀・照破', sc_result = '重力' },
                { step = 3, trigger_ws = '十二之太刀・照破', action_ws = '祖之太刀・不動',   sc_result = '闇' }
            }
        },
        {
            id = 3,
            name = '照破 -> 花車 -> 不動 (3段光連携)',
            mode = 'custom',
            delay_seconds = 6.0,
            steps = {
                { step = 1, trigger_ws = '十二之太刀・照破', action_ws = '九之太刀・花車',   sc_result = '核熱' },
                { step = 2, trigger_ws = '九之太刀・花車',   action_ws = '祖之太刀・不動',   sc_result = '光' }
            }
        },
        {
            id = 4,
            name = '照破 -> 不動 (2段光連携)',
            mode = 'custom',
            delay_seconds = 6.0,
            steps = {
                { step = 1, trigger_ws = '十二之太刀・照破', action_ws = '祖之太刀・不動',   sc_result = '光' }
            }
        },
        {
            id = 5,
            name = '雪風 -> 月光 -> 乱鴉 (3段重力連携)',
            mode = 'custom',
            delay_seconds = 6.0,
            steps = {
                { step = 1, trigger_ws = '七之太刀・雪風',   action_ws = '八之太刀・月光',   sc_result = '湾曲' },
                { step = 2, trigger_ws = '八之太刀・月光',   action_ws = '十之太刀・乱鴉',   sc_result = '重力' }
            }
        },
        {
            id = 6,
            name = '全自動AIソルバー (Auto Solver)',
            mode = 'auto',
            delay_seconds = 6.0,
            steps = {}
        }
    }
}

local routes_data = default_routes_data
local current_step = 1
local execution_token = 0

-- JSON 文字列の強固な自動サニタイズ（末尾カンマ・コメント・全角引用符の完全除去）
local function sanitize_json_string(str)
    if not str or str == '' then return '' end

    -- 1. UTF-8 BOM (ï»¿) 除去
    if str:sub(1, 3) == string.char(0xEF, 0xBB, 0xBF) then
        str = str:sub(4)
    end

    -- 2. // 形式の一行コメントを除去
    str = str:gsub('//[^
]*', '')

    -- 3. 全角/スマート引用符の半角化
    str = str:gsub('”', '):gsub(“, '):gsub('’', '):gsub(‘, ')

    -- 4. 末尾の余分なカンマを自動削除 (例: ", }" -> "}" や ", ]" -> "]")
    for _ = 1, 5 do
        str = str:gsub(',%s*}', '}'):gsub(',%s*%]', ']')
    end

    return str
end

-- 安全な JSON デコーダー (環境ごとの関数名の違いを自動吸収)
local function safe_json_decode(raw_str)
    if not raw_str or raw_str == '' then return nil, '空のデータ' end
    local clean = sanitize_json_string(raw_str)
    if not json_ok or not json then
        return nil, 'WindowerのJSONライブラリが読み込まれていません'
    end

    local decode_fn = json.decode or json.read or json.parse
    if not decode_fn then
        return nil, 'JSONデコーダー関数が存在しません'
    end

    local ok, res_or_err = pcall(decode_fn, clean)
    if ok and res_or_err then
        return res_or_err, nil
    end
    return nil, tostring(res_or_err)
end

-- sc_routes.json の自動作成/復元ヘルパー (絶対エラーを出さない完全動作版)
local function create_default_sc_routes_file()
    local target_path = 'data/sc_routes.json'
    local new_f = files.new(target_path, true)
    if new_f then
        new_f:write(default_json_raw)
        routes_data = default_routes_data
        msg('data/sc_routes.json を正常に作成/復元しました！', 209)
        return true
    end
    msg('エラー: [data/sc_routes.json] の作成に失敗しました。', 123)
    return false
end

-- JSON ルート設定ファイルの読み込み関数
local function load_sc_routes()
    local target_path = 'data/sc_routes.json'
    local target_file = files.new(target_path)

    if not target_file or not target_file:exists() then
        return create_default_sc_routes_file()
    end

    local raw_content = target_file:read()
    if not raw_content or #raw_content == 0 then
        msg('エラー: [' .. target_path .. '] が空です。標準設定を復元します...', 123)
        return create_default_sc_routes_file()
    end

    local parsed, err_msg = safe_json_decode(raw_content)
    if not parsed then
        msg('エラー: [' .. target_path .. '] の読み込みに失敗しました。', 123)
        msg('詳細: ' .. tostring(err_msg):sub(1, 80), 123)
        msg('※ //sc route fix を実行すると正常なJSON設定ファイルに1秒で自動復元できます。', 209)
        return false
    end

    if not parsed.routes then
        msg('エラー: [' .. target_path .. '] 内に "routes" 定義がありません。', 123)
        return false
    end

    routes_data = parsed
    if parsed.active_route then
        settings.active_route = parsed.active_route
    end
    return true
end

-- 現在のアクティブなルートオブジェクトを取得
local function get_active_route()
    local active_id = settings.active_route or 1
    if routes_data and routes_data.routes then
        for _, r in ipairs(routes_data.routes) do
            if r.id == active_id then return r end
        end
    end
    return default_routes_data.routes[1]
end

-- アクションパケットから連携(Skillchain)が発生したか判定する関数
local function has_skillchain_effect(act)
    if not act or not act.targets then return false end
    for _, target in ipairs(act.targets) do
        if target.actions then
            for _, sub_act in ipairs(target.actions) do
                if sub_act.has_add_effect then
                    local msg_id = sub_act.add_effect_message
                    -- FFXI 連携メッセージID: 288~302, 385, 386, 767~770
                    if (msg_id >= 288 and msg_id <= 302) or msg_id == 385 or msg_id == 386 or (msg_id >= 767 and msg_id <= 770) or (sub_act.add_effect_animation and sub_act.add_effect_animation > 0) then
                        return true
                    end
                end
            end
        end
    end
    return false
end

-- 英語 -> 日本語 連携属性変換
local sc_elem_en_to_jp = {
    ['Light'] = '光', ['Darkness'] = '闇',
    ['Gravitation'] = '重力', ['Fragmentation'] = '分解', ['Distortion'] = '湾曲', ['Fusion'] = '核熱',
    ['Liquefaction'] = '溶解', ['Induration'] = '硬化', ['Detonation'] = '炸裂', ['Scission'] = '切断',
    ['Impaction'] = '衝撃', ['Reverberation'] = '振動', ['Transfixion'] = '貫通', ['Compression'] = '収縮'
}

local LV1 = {
    ['溶解'] = { ['衝撃'] = '核熱', ['切断'] = '切断' },
    ['硬化'] = { ['振動'] = '湾曲', ['衝撃'] = '硬化', ['収縮'] = '収縮' },
    ['炸裂'] = { ['切断'] = '切断', ['収縮'] = '重力' },
    ['切断'] = { ['貫通'] = '湾曲', ['溶解'] = '溶解', ['炸裂'] = '炸裂', ['振動'] = '振動' },
    ['衝撃'] = { ['溶解'] = '溶解', ['切断'] = '切断' },
    ['振動'] = { ['硬化'] = '硬化', ['衝撃'] = '衝撃' },
    ['貫通'] = { ['収縮'] = '収縮', ['切断'] = '湾曲', ['振動'] = '振動' },
    ['収縮'] = { ['貫通'] = '貫通', ['硬化'] = '収縮' }
}

local LV2 = {
    ['核熱'] = { ['重力'] = '光', ['分解'] = '核熱' },
    ['重力'] = { ['分解'] = '闇', ['湾曲'] = '重力' },
    ['分解'] = { ['核熱'] = '光', ['湾曲'] = '分解' },
    ['湾曲'] = { ['重力'] = '闇', ['核熱'] = '湾曲' }
}

local LV3 = {
    ['光'] = { ['光'] = '光' },
    ['闇'] = { ['闇'] = '闇' }
}

local function get_skillchain_result(elements1, elements2, has_ionic_am)
    local best_sc = nil
    local best_level = 0
    for _, elem1 in ipairs(elements1) do
        for _, elem2 in ipairs(elements2) do
            if has_ionic_am then
                if elem1 == '光' and elem2 == '光' then return '極光', 4
                elseif elem1 == '闇' and elem2 == '闇' then return '黒闇', 4 end
            end
            if LV3[elem1] and LV3[elem1][elem2] then
                if 3 > best_level then best_sc = LV3[elem1][elem2]; best_level = 3 end
            end
            if LV2[elem1] and LV2[elem1][elem2] then
                if 2 > best_level then best_sc = LV2[elem1][elem2]; best_level = 2 end
            end
            if LV1[elem1] and LV1[elem1][elem2] then
                if 1 > best_level then best_sc = LV1[elem1][elem2]; best_level = 1 end
            end
        end
    end
    return best_sc, best_level
end

local sam_ws_list = {
    { name = '祖之太刀・不動',   skill = 357, elements = {'光', '湾曲'} },
    { name = '十二之太刀・照破', skill = 357, elements = {'分解', '収縮'} },
    { name = '九之太刀・花車',   skill = 250, elements = {'核熱', '収縮'} },
    { name = '五之太刀・陣風',   skill = 150, elements = {'切断', '炸裂'} },
    { name = '八之太刀・月光',   skill = 225, elements = {'湾曲', '振動'} },
    { name = '七之太刀・雪風',   skill = 200, elements = {'硬化', '炸裂'} },
    { name = '十一之太刀・鳳蝶', skill = 300, elements = {'収縮', '切断'} },
    { name = '十之太刀・乱鴉',   skill = 290, elements = {'重力', '硬化'} },
    { name = '六之太刀・光輝',   skill = 175, elements = {'振動', '衝撃'} },
    { name = '四之太刀・陽炎',   skill = 125, elements = {'溶解'} },
    { name = '参之太刀・轟天',   skill = 100, elements = {'貫通', '衝撃'} },
    { name = '弐之太刀・鋒縛',   skill = 75,  elements = {'硬化'} },
    { name = '壱之太刀・燕飛',   skill = 1,   elements = {'貫通', '切断'} },
    { name = '絶之太刀・無名',   skill = 357, elements = {'炸裂', '収縮', '湾曲'} },
    { name = 'インパルスドライブ', skill = 250, elements = {'重力', '貫通'} },
    { name = 'ソニックトラスト',   skill = 290, elements = {'貫通', '切断'} }
}

local all_ws_elements = {
    ['祖之太刀・不動']   = {'光', '湾曲'},
    ['十二之太刀・照破'] = {'分解', '収縮'},
    ['九之太刀・花車']   = {'核熱', '収縮'},
    ['五之太刀・陣風']   = {'切断', '炸裂'},
    ['八之太刀・月光']   = {'湾曲', '振動'},
    ['七之太刀・雪風']   = {'硬化', '炸裂'},
    ['十一之太刀・鳳蝶'] = {'収縮', '切断'},
    ['十之太刀・乱鴉']   = {'重力', '硬化'},
    ['六之太刀・光輝']   = {'振動', '衝撃'},
    ['四之太刀・陽炎']   = {'溶解'},
    ['参之太刀・轟天']   = {'貫通', '衝撃'},
    ['弐之太刀・鋒縛']   = {'硬化'},
    ['壱之太刀・燕飛']   = {'貫通', '切断'},
    ['絶之太刀・無名']   = {'炸裂', '収縮', '湾曲'},
    ['インパルスドライブ'] = {'重力', '貫通'}, ['ソニックトラスト'] = {'貫通', '切断'}
}

local function resolve_ws_elements(info)
    if not info or not info.entry then return nil, nil end
    local name_ja = info.entry.ja or info.entry.japanese
    local name_en = info.entry.en or info.entry.name

    if name_ja and all_ws_elements[name_ja] then return name_ja, all_ws_elements[name_ja] end
    if name_en and all_ws_elements[name_en] then return name_en, all_ws_elements[name_en] end

    local elems = {}
    local raw_elems = {info.entry.skillchain_a, info.entry.skillchain_b, info.entry.skillchain_c}
    for _, e in ipairs(raw_elems) do
        if e and e ~= '' then
            local jp_elem = sc_elem_en_to_jp[e] or e
            if jp_elem then table.insert(elems, jp_elem) end
        end
    end
    if #elems > 0 then return (name_ja or name_en or 'WS'), elems end
    return name_ja or name_en or 'WS', {}
end

local function check_ionic_aftermath()
    local player = windower.ffxi.get_player()
    if not player or not player.buffs then return false end
    for _, buff_id in ipairs(player.buffs) do
        if buff_id == 270 or buff_id == 271 or buff_id == 272 then return true end
    end
    return false
end

local function find_best_sam_ws(target_ws_elements)
    local player = windower.ffxi.get_player()
    if not player or player.main_job ~= 'SAM' then return nil, nil, nil end
    local has_ionic_am = check_ionic_aftermath()

    for level_order = 1, 4 do
        local target_sc_level = (level_order == 1 and 3) or (level_order == 2 and 4) or (level_order == 3 and 2) or 1
        for _, ws in ipairs(sam_ws_list) do
            local sc_name, sc_lvl = get_skillchain_result(target_ws_elements, ws.elements, has_ionic_am)
            if sc_lvl == target_sc_level then
                return ws.name, sc_name, sc_lvl
            end
        end
    end
    return nil, nil, nil
end

local function try_execute_ws(ws_name, sc_result, is_solo, route_label, expected_step)
    local this_token = execution_token
    coroutine.schedule(function()
        local active_r = get_active_route()
        local delay = (active_r and active_r.delay_seconds) or settings.delay_seconds or 6.0
        coroutine.sleep(delay)

        local elapsed = 0
        local check_interval = 0.2
        local max_wait_after_delay = 2.5

        while elapsed <= max_wait_after_delay do
            -- トークン不一致またはステップ変更時は競合防止のため発動キャンセルの安全保護
            if this_token ~= execution_token or current_step ~= expected_step then
                return
            end

            local player = windower.ffxi.get_player()
            if not player or player.status ~= 1 then return end

            if player.vitals.tp >= 1000 then
                local prefix = is_solo and '【一人連携】' or '【PT連携】'
                local label_str = route_label and (' [' .. route_label .. ']') or ''
                local sc_str = sc_result and (' (目標:' .. sc_result .. ')') or ''
                msg(prefix .. label_str .. ' TP:' .. player.vitals.tp .. ' で次技自動発動 -> [' .. ws_name .. ']' .. sc_str, 209)
                windower.send_command(sjis('input /ws "' .. ws_name .. '" <t>'))
                return
            end

            coroutine.sleep(check_interval)
            elapsed = elapsed + check_interval
        end

        if this_token == execution_token and current_step == expected_step then
            msg('エラー: 待機時間終了後、受付時間内にTP1000に達しなかったため発動できませんでした。', 123)
            current_step = 1
            execution_token = execution_token + 1
        end
    end, 0.01)
end

local recent = {}
local function recent_key(actor_id, param)
    return tostring(actor_id) .. '|' .. tostring(param)
end

windower.register_event('action', function(act)
    if not settings.enabled then return end
    if not act or act.category ~= 3 then return end

    local player = windower.ffxi.get_player()
    if not player or player.main_job ~= 'SAM' or player.status ~= 1 then return end

    local r_key = recent_key(act.actor_id, act.param)
    local now = os.clock()
    if recent[r_key] and (now - recent[r_key]) < (settings.block_seconds or 1.5) then return end
    recent[r_key] = now

    local mob = windower.ffxi.get_mob_by_id(act.actor_id)
    if not mob then return end

    local my_target = windower.ffxi.get_mob_by_target('t')
    if not my_target then return end

    local target_matched = false
    if act.targets then
        for _, t in ipairs(act.targets) do
            if t.id == my_target.id then
                target_matched = true
                break
            end
        end
    end
    if not target_matched then return end

    local entry = res.weapon_skills[act.param]
    if not entry then return end

    local ws_display_name, ws_elements = resolve_ws_elements({entry = entry})
    if not ws_display_name then return end

    local is_me = (act.actor_id == player.id)
    if is_me and not settings.solo_mode then return end
    if not is_me and not settings.party_mode then return end

    local active_r = get_active_route()

    -- カスタムルート実行エンジン (厳格なStep進行＆連携不成立完全リセット)
    if active_r and active_r.mode == 'custom' and active_r.steps and #active_r.steps > 0 then
        local steps = active_r.steps
        local num_steps = #steps

        -- 1) 初段 (Step 1 起動判定): 初段技(trigger_ws)を検知した時のみ起動！
        if current_step == 1 then
            local step1 = steps[1]
            if step1 and step1.trigger_ws == ws_display_name then
                if step1.action_ws then
                    local delay_sec = active_r.delay_seconds or settings.delay_seconds or 6.0
                    msg('ルート[' .. active_r.id .. ':' .. (active_r.name or '') .. '] Step 1: 初段[' .. ws_display_name .. ']検知 -> 次技[' .. step1.action_ws .. '] (目標:' .. (step1.sc_result or '連携') .. ') ' .. string.format('%.1f', delay_sec) .. 's待機中...', 209)
                    current_step = 2
                    try_execute_ws(step1.action_ws, step1.sc_result, is_me, active_r.name, 2)
                else
                    msg('ルート[' .. active_r.id .. '] Step 1: 初段[' .. ws_display_name .. ']検知。次技設定なしのため終了します。', 209)
                    current_step = 1
                end
                return
            end
            -- 初段技以外のWS(例:不動)が単発で撃たれた場合は無視 (追撃しない)
            return
        end

        -- 2) 2段目以降 (Step 2以上) の検証と進行
        if current_step > 1 then
            local prev_step_index = current_step - 1
            local prev_step = steps[prev_step_index]

            -- 期待される追撃技が着弾した場合
            if prev_step and prev_step.action_ws == ws_display_name then
                -- 実際に連携エフェクト(Skillchain)が発生したか判定！
                local sc_ok = has_skillchain_effect(act)

                if sc_ok then
                    msg('★連携発生成功 [' .. (prev_step.sc_result or '連携') .. ']！ (Step ' .. prev_step_index .. ' 完了)', 209)

                    -- さらに次のステップが存在するか確認
                    local next_step_info = steps[current_step]
                    if next_step_info and next_step_info.action_ws then
                        local delay_sec = active_r.delay_seconds or settings.delay_seconds or 6.0
                        msg('ルート[' .. active_r.id .. '] Step ' .. current_step .. ': 次技[' .. next_step_info.action_ws .. '] (目標:' .. (next_step_info.sc_result or '連携') .. ') ' .. string.format('%.1f', delay_sec) .. 's待機中...', 209)
                        local expected = current_step + 1
                        current_step = expected
                        try_execute_ws(next_step_info.action_ws, next_step_info.sc_result, is_me, active_r.name, expected)
                    else
                        msg('★ルート完遂！ 最初の初段待機状態(Step 1)へリセットします。', 158)
                        current_step = 1
                        execution_token = execution_token + 1
                    end
                else
                    -- 連携不成立！ 即座に追撃中断＆初段へ強制的完全リセット！
                    msg('【連携不成立・追撃中断】 [' .. ws_display_name .. '] で連携が発生しなかったため、最初の初段待機状態へリセットします。', 123)
                    current_step = 1
                    execution_token = execution_token + 1
                end
                return
            end

            -- もし途中で初段技 (Step 1 trigger_ws) が撃ち直された場合は Step 1 から再起動
            if ws_display_name == steps[1].trigger_ws then
                execution_token = execution_token + 1
                current_step = 1
                local step1 = steps[1]
                if step1 and step1.action_ws then
                    local delay_sec = active_r.delay_seconds or settings.delay_seconds or 6.0
                    msg('ルート[' .. active_r.id .. '] Step 1 (再起動): 初段[' .. ws_display_name .. ']検知 -> 次技[' .. step1.action_ws .. '] ' .. string.format('%.1f', delay_sec) .. 's待機中...', 209)
                    current_step = 2
                    try_execute_ws(step1.action_ws, step1.sc_result, is_me, active_r.name, 2)
                end
                return
            end

            -- 想定外のWSが撃たれた場合はキャンセル＆初段へリセット
            msg('【ルート外WS検知】 連携シーケンスを解除し初段待機状態へリセットします。', 123)
            current_step = 1
            execution_token = execution_token + 1
            return
        end
    end

    -- 自動AIソルバー (Fallback)
    if not active_r or active_r.mode == 'auto' or settings.fallback_to_auto then
        if ws_elements and #ws_elements > 0 then
            local next_ws, sc_result, sc_level = find_best_sam_ws(ws_elements)
            if next_ws then
                local delay_sec = settings.delay_seconds or 6.0
                msg('AIソルバー: 前技[' .. ws_display_name .. ']検知 -> 最高階層連携【' .. sc_result .. ' (Lv' .. sc_level .. ')】 [' .. next_ws .. '] ' .. string.format('%.1f', delay_sec) .. 's待機中...', 209)
                try_execute_ws(next_ws, sc_result, is_me, '自動AIソルバー', current_step)
            end
        end
    end
end)

windower.register_event('addon command', function(...)
    local args = {...}
    local cmd = args and args[1] and args[1]:lower() or 'help'

    if cmd == 'reset' or cmd == 'clear' then
        current_step = 1
        execution_token = execution_token + 1
        msg('連携ステップを最初の【初段待機状態 (Step 1)】へ手動リセットしました。', 158)
        return
    end

    if cmd == 'fix' then
        create_default_sc_routes_file()
        current_step = 1
        execution_token = execution_token + 1
        return
    end

    if cmd == 'route' or cmd == 'r' then
        local sub = args[2] and args[2]:lower()
        if not sub or sub == 'status' or sub == 'show' then
            local active_r = get_active_route()
            msg('==================================================')
            msg('  [AutoSkillchain v5.1] 現在の連携ルート設定')
            msg('--------------------------------------------------')
            msg('  ・選択中ルート: ルート ' .. (settings.active_route or 1) .. ' 【 ' .. (active_r.name or '') .. ' 】')
            msg('  ・動作モード: ' .. (active_r.mode or 'custom'))
            msg('  ・現在ステップ: Step ' .. current_step)
            msg('  ・基本待機秒数: ' .. string.format('%.1f', active_r.delay_seconds or 6.0) .. '秒')
            msg('==================================================')
        elseif tonumber(sub) then
            local route_id = tonumber(sub)
            if route_id >= 1 and route_id <= 6 then
                settings.active_route = route_id
                current_step = 1
                execution_token = execution_token + 1
                config.save(settings)
                local active_r = get_active_route()
                msg('==================================================')
                msg('連携ルート切り替え -> ルート ' .. route_id .. ': 【 ' .. (active_r.name or '') .. ' 】 に変更完了')
                msg('==================================================')
            else
                msg('エラー: ルート番号は 1 ~ 6 で指定してください。', 123)
            end
        elseif sub == 'reload' then
            if load_sc_routes() then
                current_step = 1
                execution_token = execution_token + 1
                msg('sc_routes.json を再読み込みしました。(Step 1リセット)', 209)
            else
                msg('sc_routes.json の読み込みに失敗しました。', 123)
            end
        elseif sub == 'fix' then
            create_default_sc_routes_file()
            current_step = 1
            execution_token = execution_token + 1
        end
        return
    elseif cmd == 'toggle' then
        settings.enabled = not settings.enabled
        config.save(settings)
        msg('全体機能: ' .. (settings.enabled and '【ON】' or '【OFF】'))
    elseif cmd == 'party' then
        settings.party_mode = not settings.party_mode
        config.save(settings)
        msg('PT連携追撃: ' .. (settings.party_mode and '【ON】' or '【OFF】'))
    elseif cmd == 'solo' then
        settings.solo_mode = not settings.solo_mode
        config.save(settings)
        msg('一人連携追撃: ' .. (settings.solo_mode and '【ON】' or '【OFF】'))
    elseif cmd == 'delay' then
        local sec = tonumber(args[2])
        if sec and sec >= 1.0 and sec <= 8.0 then
            settings.delay_seconds = sec
            config.save(settings)
            msg('基本待機時間: 【' .. string.format('%.1f', settings.delay_seconds) .. '秒】 に変更')
        else
            msg('使用法: //sc delay <1.0~8.0>', 123)
        end
    elseif cmd == 'status' or cmd == 'show' then
        local active_r = get_active_route()
        msg('==================================================')
        msg('  [AutoSkillchain v5.1] 設定ステータス')
        msg('--------------------------------------------------')
        msg('  ・全体機能: ' .. (settings.enabled and 'ON' or 'OFF'))
        msg('  ・選択ルート: ルート ' .. (settings.active_route or 1) .. ' (' .. (active_r.name or '') .. ')')
        msg('  ・現在ステップ: Step ' .. current_step)
        msg('  ・PT連携追撃: ' .. (settings.party_mode and 'ON' or 'OFF'))
        msg('  ・一人連携追撃: ' .. (settings.solo_mode and 'ON' or 'OFF'))
        msg('  ・基本待機秒数: ' .. string.format('%.1f', settings.delay_seconds or 6.0) .. 's')
        msg('==================================================')
    elseif cmd == 'reload' then
        windower.send_command('lua r AutoSkillchain')
    else
        msg('==================================================')
        msg('  [AutoSkillchain v5.1] コマンドヘルプ')
        msg('--------------------------------------------------')
        msg('  //sc route <1~6>  : 連携ルート(1~6)の切り替え')
        msg('  //sc route reload : sc_routes.jsonの再読み込み')
        msg('  //sc route fix    : 設定ファイルの自動復元')
        msg('  //sc reset        : 連携ステップの手動リセット')
        msg('  //sc toggle       : アドオン全体のON/OFF切り替え')
        msg('  //sc party        : PT連携追撃のON/OFF切り替え')
        msg('  //sc solo         : 一人連携追撃のON/OFF切り替え')
        msg('  //sc delay <秒>   : 連携受付の基本待機秒数変更 (1.0~8.0秒)')
        msg('  //sc status       : 現在の設定状況を確認')
        msg('  //sc reload       : アドオンを再読み込み')
        msg('==================================================')
    end
end)

windower.register_event('load', function()
    load_sc_routes()
    msg('loaded v' .. _addon.version .. ' -- 侍自動連携追撃アドオン準備完了 (ルート' .. (settings.active_route or 1) .. '適用中)')
end)
