_addon.name = 'AutoSkillchain'
_addon.author = 'hikaruoshino'
_addon.version = '5.5.0'
_addon.commands = {'sc', 'autoskillchain', 'autosc'}

local config = require('config')
local res = require('resources')
local files = require('files')
local packets = require('packets')

local sc_json = require('libs/sc_json')   -- 読むだけの JSON リーダー (libs/json.lua は入れ子の配列を読めず、json.decode も無いため)

local defaults = {
    enabled = true,
    party_mode = true,
    solo_mode = true,
    focus = true,             -- 同じ敵に自分以外のPCが2人以上なら連携より集中攻撃を優先
    delay_seconds = 6.0,
    delay_override = 0,       -- //sc delay <秒> で決めた待機秒数 (1.0〜8.0)。0 = 使わない (ルートの delay_seconds → delay_seconds の順)
    block_seconds = 1.5,
    ws_reach = 3.5,           -- 近接の技が届く距離 (敵の model_size が 2 を超えた分は足す)。届かないあいだは撃たずに待つ
    active_route = 1,
    kusanagi = false,         -- 侍が草薙剣を装備している間: 鳳蝶/轟天 → 無名を連携が続くかぎり
    kusanagi_delay = 5.0,     -- 草薙剣モードの、前の技を見てから次の無名を撃つまでの秒数
}

local settings = config.load(defaults)

-- 設定の数値の範囲。範囲外・数でない・NaN のときは既定に戻す (読み込みのときに 1 回だけ知らせる)
local SETTING_RANGES = {
    {'delay_seconds', 1.0, 8.0}, {'kusanagi_delay', 1.0, 8.0},
    {'block_seconds', 0.5, 5.0}, {'ws_reach', 1.0, 10.0},
}
local settings_fixed = {}
local function validate_settings()
    settings_fixed = {}
    for _, r in ipairs(SETTING_RANGES) do
        local key, lo, hi = r[1], r[2], r[3]
        local v = tonumber(settings[key])
        if not v or v ~= v or v < lo or v > hi then
            settings_fixed[#settings_fixed + 1] = key .. ' (' .. tostring(settings[key]) .. ' → ' .. tostring(defaults[key]) .. ')'
            settings[key] = defaults[key]
        else
            settings[key] = v
        end
    end
end
validate_settings()
if config.register then config.register(settings, validate_settings) end

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

-- JSON から来た文字列 (ルートの name・sc_result・mode・技名など) を表示するための形: 制御文字を除き、40 文字で切る
local DISP_MAX = 40
local function disp(v)
    local str = tostring(v):gsub('%c', '')
    local out, n = {}, 0
    for ch in str:gmatch('[%z\1-\127\194-\244][\128-\191]*') do
        n = n + 1
        if n > DISP_MAX then out[#out + 1] = '…'; break end
        out[#out + 1] = ch
    end
    return table.concat(out)
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
        { "step": 4, "trigger_ws": "十二之太刀・照破", "action_ws": "九之太刀・花車",   "sc_result": "光" },
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
        { "step": 1, "trigger_ws": "十二之太刀・照破", "action_ws": "九之太刀・花車",   "sc_result": "光" },
        { "step": 2, "trigger_ws": "九之太刀・花車",   "action_ws": "祖之太刀・不動",   "sc_result": "光" }
      ]
    },
    {
      "id": 4,
      "name": "照破 -> 不動 (2段光連携・照破にアフターマスがあるとき。無ければ湾曲)",
      "mode": "custom",
      "delay_seconds": 6.0,
      "steps": [
        { "step": 1, "trigger_ws": "十二之太刀・照破", "action_ws": "祖之太刀・不動",   "sc_result": "光" }
      ]
    },
    {
      "id": 5,
      "name": "雪風 -> 月光 -> 花車 (3段光連携)",
      "mode": "custom",
      "delay_seconds": 6.0,
      "steps": [
        { "step": 1, "trigger_ws": "七之太刀・雪風",   "action_ws": "八之太刀・月光",   "sc_result": "分解" },
        { "step": 2, "trigger_ws": "八之太刀・月光",   "action_ws": "九之太刀・花車",   "sc_result": "光" }
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

local ROUTES_PATH = 'data/sc_routes.json'
local MAX_ROUTES = 50   -- ルートの数の上限
local MAX_STEPS = 10    -- カスタムルートの steps の上限
local MAX_WARN = 8      -- 読み込みの警告をチャットに出す行数の上限
local MAX_ROUTE_ID = 1000   -- ルートの id の上限

-- 日本語の技名 → res の技の ID。起動時に 1 回だけ作る (res.weapon_skills を何度も引き直さない)
-- 技の照合は日本語名で行うので、ルートの技名も日本語名だけを認める (英語名は警告して飛ばす)
local ws_id_by_name = {}
local ws_en_names = {}
for id, row in pairs(res.weapon_skills) do
    if type(row) == 'table' then
        if row.ja then ws_id_by_name[row.ja] = id end
        if row.en then ws_en_names[row.en] = true end
    end
end

-- /ws "…" に入れてよい技名か (空でない文字列で、" ; \ と制御文字を含まない)
local function safe_ws_name(n)
    return type(n) == 'string' and n ~= '' and not n:find('["\\;%c]')
end

-- 配列 (1〜n の整数キーだけ) の件数。配列でなければ nil
local function array_length(t)
    if type(t) ~= 'table' then return nil end
    local n = #t
    local count = 0
    for k in pairs(t) do
        if type(k) ~= 'number' or k < 1 or k > n or k ~= math.floor(k) then return nil end
        count = count + 1
    end
    if count ~= n then return nil end
    return n
end

-- JSON から読んだ表を確かめ、知っている項目だけを写した表を返す
-- 戻り値: 表 (成功) / nil と理由 (失敗)。3 つ目は警告の一覧
local function validate_routes(parsed)
    local warns = {}
    local function warn(s) warns[#warns + 1] = s end
    if type(parsed) ~= 'table' then return nil, 'JSON の最上位がオブジェクトではありません', warns end
    local n = array_length(parsed.routes)
    if not n or n < 1 or n > MAX_ROUTES then
        return nil, '"routes" が 1～' .. MAX_ROUTES .. ' 件の配列ではありません', warns
    end
    local out, seen = {}, {}
    for i = 1, n do
        local r = parsed.routes[i]
        local ok = true
        local id = type(r) == 'table' and r.id or nil
        if type(r) ~= 'table' then
            warn('routes の ' .. i .. ' 件目がオブジェクトではないので飛ばします'); ok = false
        elseif type(id) ~= 'number' or id < 1 or id > MAX_ROUTE_ID or id ~= math.floor(id) then
            warn('routes の ' .. i .. ' 件目の id (' .. disp(id) .. ') が 1～' .. MAX_ROUTE_ID .. ' の整数ではないので飛ばします'); ok = false
        elseif seen[id] then
            warn('ルート ' .. id .. ' の id が重複しているので、' .. i .. ' 件目を飛ばします'); ok = false
        elseif r.mode ~= 'custom' and r.mode ~= 'auto' then
            warn('ルート ' .. id .. ' の mode (' .. disp(r.mode) .. ') が custom / auto ではないので飛ばします'); ok = false
        end
        local delay = nil
        if ok and r.delay_seconds ~= nil then
            if type(r.delay_seconds) == 'number' and r.delay_seconds >= 1.0 and r.delay_seconds <= 8.0 then
                delay = r.delay_seconds
            else
                warn('ルート ' .. id .. ' の delay_seconds (' .. disp(r.delay_seconds) .. ') が 1.0～8.0 ではないので使いません')
            end
        end
        local steps = {}
        if ok and r.mode == 'custom' then
            local sn = array_length(r.steps)
            if not sn or sn < 1 or sn > MAX_STEPS then
                warn('ルート ' .. id .. ' の steps が 1～' .. MAX_STEPS .. ' 件の配列ではないので飛ばします'); ok = false
            else
                for k = 1, sn do
                    local s = r.steps[k]
                    if type(s) ~= 'table' then
                        warn('ルート ' .. id .. ' の ' .. k .. ' 段目がオブジェクトではないので、ルートを飛ばします'); ok = false; break
                    end
                    for _, key in ipairs{'trigger_ws', 'action_ws'} do
                        local name = s[key]
                        if not safe_ws_name(name) then
                            warn('ルート ' .. id .. ' の ' .. k .. ' 段目の ' .. key .. ' が使えない文字列なので、ルートを飛ばします'); ok = false
                        elseif not ws_id_by_name[name] and ws_en_names[name] then
                            warn('ルート ' .. id .. ' の技名 [' .. disp(name) .. '] は英語の名前です。日本語の技名のみ対応のため、ルートを飛ばします'); ok = false
                        elseif not ws_id_by_name[name] then
                            warn('ルート ' .. id .. ' の技名 [' .. disp(name) .. '] が Windower の一覧にありません (誤字?)。ルートを飛ばします'); ok = false
                        end
                        if not ok then break end
                    end
                    if not ok then break end
                    if k >= 2 and s.trigger_ws ~= r.steps[k - 1].action_ws then
                        warn('ルート ' .. id .. ' の ' .. k .. ' 段目の trigger_ws が、前の段の action_ws と違います (そのまま使います)')
                    end
                    steps[k] = {step = k, trigger_ws = s.trigger_ws, action_ws = s.action_ws,
                                sc_result = type(s.sc_result) == 'string' and disp(s.sc_result) or nil}
                end
            end
        end
        if ok then
            seen[id] = true
            out[#out + 1] = {id = id, name = type(r.name) == 'string' and disp(r.name) or ('ルート ' .. id),
                             mode = r.mode, delay_seconds = delay, steps = steps}
        end
    end
    if #out == 0 then return nil, '使えるルートがありません', warns end
    local active = parsed.active_route
    if type(active) ~= 'number' then active = nil end
    return {active_route = active, routes = out}, nil, warns
end

local function show_warnings(warns)
    for i = 1, math.min(#warns, MAX_WARN) do msg('警告: ' .. warns[i], 123) end
    if #warns > MAX_WARN then msg('(ほかに警告が ' .. (#warns - MAX_WARN) .. ' 件あります)', 123) end
end

-- 既定のルートは default_json_raw だけを正にする (起動時に読んで確かめる)
local DEFAULT_ROUTES, DEFAULT_ERR = validate_routes((sc_json.decode(default_json_raw)))
if not DEFAULT_ROUTES then DEFAULT_ROUTES = {routes = {}} end

local routes_data = DEFAULT_ROUTES

-- 進行の状態は、この 1 つの表にまとめる。取り消しは cancel_all だけで行う
--   token: 予約の番号 (進めると、待っている予約がすべて無効になる) / step: カスタムルートの次に待つ段 (1 = 初段待ち)
--   mode: 動いているもの (nil / 'custom' / 'auto' / 'kusanagi' / 'kus_am') / target_id: 予約した相手の id
--   pending: 予約中の技 {ws = 技名, sent_at = 送った時刻 (送る前は nil)} / auto_count・auto_start: 全自動の回数と始めた時刻
--   chain_prop: 全自動の直前の連携 / kus_count・kus_prev・kus_last: 草薙剣モード (無名の回数・直前の連携・最後の予約の時刻)
--   notice_at: 草薙剣モードの知らせを最後に出した時刻 / fix_until: //sc route fix confirm の期限 (この 2 つは取り消しでは戻さない)
local st = {
    token = 0, step = 1, mode = nil, target_id = nil, pending = nil,
    auto_count = 0, auto_start = 0, chain_prop = nil,
    kus_count = 0, kus_prev = nil, kus_last = 0,
    notice_at = -1000, fix_until = 0,
}

local function is_running()
    return st.mode ~= nil or st.pending ~= nil
end

-- 予約と進行をすべて取り消す (唯一の取り消し口)。動いていたときだけ reason を出す。戻り値: 動いていたか
local function cancel_all(reason, color)
    local was = is_running()
    st.token = st.token + 1
    st.step = 1
    st.mode = nil
    st.target_id = nil
    st.pending = nil
    st.auto_count = 0
    st.auto_start = 0
    st.chain_prop = nil
    st.kus_count = 0
    st.kus_prev = nil
    st.kus_last = 0
    st.kus_am_since = nil
    -- notice_at と fix_until は戻さない (知らせの間隔と、//sc route fix confirm の期限は進行とは別)
    if was and reason then msg(reason, color or 123) end
    return was
end

-- 番号のルート (無ければ nil)
local function find_route(id)
    id = tonumber(id)
    if not id then return nil end
    for _, r in ipairs(routes_data.routes) do
        if r.id == id then return r end
    end
    return nil
end

-- 今あるルートの番号の一覧 ("1, 2, 3")
local function route_ids_text()
    local ids = {}
    for i, r in ipairs(routes_data.routes) do ids[i] = tostring(r.id) end
    if #ids == 0 then return 'なし' end
    return table.concat(ids, ', ')
end

-- 選択中のルートが無いときの知らせ (読み込み・再読み込み・status で出す)
local function notify_missing_route()
    msg('選択中のルート ' .. tostring(settings.active_route) .. ' はありません (あるのは ' .. route_ids_text() .. ')。何もしません。//sc route <番号> で選んでください。', 123)
end

local FIX_CONFIRM_SEC = 30   -- //sc route fix のあと、confirm を受け付ける秒数

-- ファイルを読む (例外を出さない)。戻り値: 中身 / nil
local function read_file(path)
    local f = files.new(path)
    local ok_exists, exists = pcall(f.exists, f)
    if not ok_exists or not exists then return nil end
    local ok, content = pcall(f.read, f)
    if ok and type(content) == 'string' then return content end
    return nil
end

-- content を書き、読み直して同じか確かめる (libs/files.lua の write は io.open に失敗すると例外になるので pcall で包む)
-- 戻り値: true / false と理由
local function write_routes_file(content, path)
    path = path or ROUTES_PATH
    local f = files.new(path, true)
    local ok, err = pcall(f.write, f, content)
    if not ok then return false, '書き込めません: ' .. tostring(err) end
    if read_file(path) ~= content then return false, '書き込んだ内容を読み直すと違っていました' end
    return true
end

-- 今の data/sc_routes.json を data/sc_routes_backup_YYYYMMDD_HHMMSS.json に残す。戻り値: true とファイル名 / false と理由
local function backup_routes_file()
    local content = read_file(ROUTES_PATH)
    if not content then return false, '今のファイルを読めません' end
    -- バックアップは fix confirm のたびに 1 つ増える。数の上限は設けない (古いものはユーザーが消す)
    local base = 'data/sc_routes_backup_' .. os.date('%Y%m%d_%H%M%S')
    local name = base .. '.json'
    local n = 1
    -- 同じ名前のファイルがあれば、連番を付けた別の名前にする (前のバックアップを上書きしない)
    while true do
        local f = files.new(name)
        local ok, exists = pcall(f.exists, f)
        if not ok then return false, 'バックアップの名前を確かめられません' end
        if not exists then break end
        n = n + 1
        if n > 99 then return false, '同じ時刻のバックアップが多すぎます' end
        name = base .. '_' .. n .. '.json'
    end
    local ok, err = write_routes_file(content, name)
    if not ok then return false, err end
    return true, name
end

-- ファイルが無い / 空のとき: 確認なしで既定のルートを書く。書けなければ、内蔵の既定のルートをメモリで使う
local function create_default_sc_routes_file()
    routes_data = DEFAULT_ROUTES
    local ok, err = write_routes_file(default_json_raw)
    if ok then
        msg('data/sc_routes.json を既定のルートで作りました。', 209)
    else
        msg('data/sc_routes.json を作れませんでした (' .. tostring(err) .. ')。内蔵の既定のルートをメモリで使います。', 123)
    end
    return true
end

-- ファイルが無い / 空 (空白だけ) か (あるのに読めないときは false。上書きしないため)
local function routes_file_missing_or_empty()
    local f = files.new(ROUTES_PATH)
    local ok, exists = pcall(f.exists, f)
    if ok and not exists then return true end
    local content = read_file(ROUTES_PATH)
    return content ~= nil and not content:find('%S')
end

local NO_ROUTES = {routes = {}}
local NO_ROUTES_TEXT = 'ルートの JSON を読めないので、ルートは動きません (内蔵の既定は //sc route fix で書き出せます)'

-- JSON ルート設定ファイルの読み込み関数
--   initial = 起動時の最初の読み込み: 失敗したらルートを空にして何もしない (内蔵の既定で黙って動かない)
--   再読み込み (//sc route reload): 失敗したら前のルートをそのまま使う
local function load_sc_routes(initial)
    local target_path = ROUTES_PATH
    local function failed()
        if initial then
            routes_data = NO_ROUTES
            msg(NO_ROUTES_TEXT, 123)
        end
        return false
    end
    if routes_file_missing_or_empty() then
        return create_default_sc_routes_file()
    end

    local raw_content = read_file(target_path)
    if not raw_content then
        msg('エラー: [' .. target_path .. '] を読めませんでした' .. (initial and '。' or ' (前のルートのまま)。'), 123)
        return failed()
    end

    local parsed, err_msg = sc_json.decode(raw_content)
    if type(parsed) ~= 'table' then
        msg('エラー: [' .. target_path .. '] の読み込みに失敗しました。', 123)
        msg('詳細: ' .. tostring(err_msg or 'JSON の最上位がオブジェクトではありません'), 123)
        if raw_content:find('“', 1, true) or raw_content:find('”', 1, true) then
            msg('全角の引用符があります (“ ” を半角の " に直してください)', 123)
        end
        msg('※ //sc route fix を実行すると正常なJSON設定ファイルに1秒で自動復元できます。', 209)
        return failed()
    end

    local checked, why, warns = validate_routes(parsed)
    show_warnings(warns)
    if not checked then
        msg('エラー: [' .. target_path .. '] の読み込みに失敗しました: ' .. tostring(why) .. (initial and '' or ' (前のルートのまま)'), 123)
        return failed()
    end

    routes_data = checked
    -- 選択中のルートの正は設定 (settings.active_route)。JSON の active_route は、設定の番号が JSON に無いときだけ使う
    if not find_route(settings.active_route) and checked.active_route and find_route(checked.active_route) then
        settings.active_route = checked.active_route
    end
    return true
end

-- //sc route fix [confirm]: 既定のルートに戻す。ファイルがあるときは確認を取り、バックアップを残してから上書きする
-- 戻り値: ルートを入れ替えたら true (呼び出し側が進行を取り消す)
local function fix_routes(confirm)
    if routes_file_missing_or_empty() then
        st.fix_until = 0
        create_default_sc_routes_file()
        return true
    end
    if not confirm then
        st.fix_until = os.clock() + FIX_CONFIRM_SEC
        msg('data/sc_routes.json を既定のルートで上書きします (今のファイルは data/sc_routes_backup_日時.json に残します)。', 209)
        msg('よければ ' .. FIX_CONFIRM_SEC .. ' 秒以内に //sc route fix confirm と入力してください。', 209)
        return false
    end
    if st.fix_until == 0 or os.clock() > st.fix_until then
        st.fix_until = 0
        msg('確認の期限が切れているか、まだ //sc route fix を実行していません。先に //sc route fix を実行してください。', 123)
        return false
    end
    st.fix_until = 0
    local bok, bname = backup_routes_file()
    if not bok then
        msg('バックアップを作れなかったので上書きしません (' .. tostring(bname) .. ')。', 123)
        return false
    end
    local wok, werr = write_routes_file(default_json_raw)
    if not wok then
        msg('data/sc_routes.json の上書きに失敗しました (' .. tostring(werr) .. ')。ファイルが壊れた可能性があります。バックアップ: ' .. bname .. ' (今のルートは前のまま使います)', 123)
        return false
    end
    routes_data = DEFAULT_ROUTES
    msg('data/sc_routes.json を既定のルートに戻しました (バックアップ: ' .. bname .. ')。', 209)
    return true
end

-- 選択中のルート。無ければ nil (既定のルートへ黙って戻らない)
local function get_active_route()
    return find_route(settings.active_route)
end

-- 前の技を見てから次の技を撃つまでの秒数と、その出どころ
-- 優先順: //sc delay の上書き (delay_override) > ルートの delay_seconds > 設定の delay_seconds
local function effective_delay(route)
    local o = tonumber(settings.delay_override) or 0
    if o >= 1.0 and o <= 8.0 then return o, '//sc delay の上書き' end
    if route and route.delay_seconds then return route.delay_seconds, 'ルート ' .. tostring(route.id) .. ' の設定' end
    return tonumber(settings.delay_seconds) or 6.0, '基本設定'
end

local function delay_text(route)
    local sec, src = effective_delay(route)
    return string.format('%.1f', sec) .. '秒 (' .. src .. ')'
end

-- 追加効果のメッセージ番号 → 起きた連携の名前 (Windower の res/action_messages.lua)
--   288〜301 ダメージ / 385〜398 回復 (敵が属性を吸収したとき) は同じ並び。767・769 極光 / 768・770 黒闇
--   302 は res の文が Cosmic Elucidation (特殊な連携) なので、名前は仮に「特殊(302)」とする
local SC_BY_MESSAGE = {}
do
    local order = {'光', '闇', '重力', '分解', '湾曲', '核熱', '収縮', '溶解', '硬化', '振動', '貫通', '切断', '炸裂', '衝撃'}
    for i, name in ipairs(order) do
        SC_BY_MESSAGE[287 + i] = name
        SC_BY_MESSAGE[384 + i] = name
    end
    SC_BY_MESSAGE[767] = '極光'; SC_BY_MESSAGE[769] = '極光'
    SC_BY_MESSAGE[768] = '黒闇'; SC_BY_MESSAGE[770] = '黒闇'
    SC_BY_MESSAGE[302] = '特殊(302)'
end

-- 技が target_id の相手に起こした連携の名前。起きていなければ nil
-- (追加効果のメッセージ番号だけを見る。番号が無くアニメーションだけのものは連携とみなさない)
local function skillchain_of(act, target_id)
    local targets = act and act.targets
    if not targets then return nil end
    for i = 1, #targets do
        local t = targets[i]
        if t.id == target_id then
            local actions = t.actions
            if actions then
                for j = 1, #actions do
                    local a = actions[j]
                    if a.has_add_effect then
                        local name = SC_BY_MESSAGE[a.add_effect_message or 0]
                        if name then return name end
                    end
                end
            end
            return nil
        end
    end
    return nil
end

-- 当たらなかった技の結果のメッセージ (Windower の res/action_messages.lua): 31 分身で消された / 188・189 外れ / 323・324 効果なし・外れ
local NO_HIT_MESSAGES = {[31] = true, [188] = true, [189] = true, [323] = true, [324] = true}

-- 技が target_id の相手に当たったか
local function landed_on(act, target_id)
    for _, t in ipairs(act.targets or {}) do
        if t.id == target_id and t.actions and t.actions[1] then
            return not NO_HIT_MESSAGES[t.actions[1].message or 0]
        end
    end
    return false
end

-- 初段の技で、ルートを始めてよいか。当たっていて、それ自体で連携を起こしていない (= 新しい始点になった) ときだけ始める
-- (外れた初段や、前の技の続きとして連携を締めた初段から始めると、次の技が必ず連携不成立になるため)
local function can_open_route(act, target_id, ws_name)
    if not landed_on(act, target_id) then
        msg('初段[' .. ws_name .. ']が当たらなかったため、ルートを始めません。', 123)
        return false
    end
    if skillchain_of(act, target_id) then
        msg('初段[' .. ws_name .. ']で連携が起きた (前の技の続きになった) ため、ルートを始めません。', 123)
        return false
    end
    return true
end

-- 英語 -> 日本語 連携属性変換
local sc_elem_en_to_jp = {
    ['Light'] = '光', ['Darkness'] = '闇',
    ['Gravitation'] = '重力', ['Fragmentation'] = '分解', ['Distortion'] = '湾曲', ['Fusion'] = '核熱',
    ['Liquefaction'] = '溶解', ['Induration'] = '硬化', ['Detonation'] = '炸裂', ['Scission'] = '切断',
    ['Impaction'] = '衝撃', ['Reverberation'] = '振動', ['Transfixion'] = '貫通', ['Compression'] = '収縮'
}

-- 連携の組み合わせ表: SC[先の属性][後の属性] = {できる連携, 階層}。順番は先→後で、逆向きは別の行 (表にある組み合わせだけ連携になる)
-- 照合: Ivaar/Skillchains の表と Horizon wiki (2026-10)。光+光 / 闇+闇 は Lv3 の 光 / 闇 で、イオニックAM中だけ Lv4 の 極光 / 黒闇 (get_skillchain_result)
local SC = {
    ['溶解'] = { ['切断'] = {'切断', 1}, ['衝撃'] = {'核熱', 2} },
    ['硬化'] = { ['衝撃'] = {'衝撃', 1}, ['振動'] = {'分解', 2}, ['収縮'] = {'収縮', 1} },
    ['炸裂'] = { ['切断'] = {'切断', 1}, ['収縮'] = {'重力', 2} },
    ['切断'] = { ['溶解'] = {'溶解', 1}, ['炸裂'] = {'炸裂', 1}, ['振動'] = {'振動', 1} },
    ['衝撃'] = { ['溶解'] = {'溶解', 1}, ['炸裂'] = {'炸裂', 1} },
    ['振動'] = { ['硬化'] = {'硬化', 1}, ['衝撃'] = {'衝撃', 1} },
    ['貫通'] = { ['切断'] = {'湾曲', 2}, ['振動'] = {'振動', 1}, ['収縮'] = {'収縮', 1} },
    ['収縮'] = { ['炸裂'] = {'炸裂', 1}, ['貫通'] = {'貫通', 1} },
    ['核熱'] = { ['重力'] = {'重力', 2}, ['分解'] = {'光', 3} },
    ['重力'] = { ['分解'] = {'分解', 2}, ['湾曲'] = {'闇', 3} },
    ['分解'] = { ['核熱'] = {'光', 3}, ['湾曲'] = {'湾曲', 2} },
    ['湾曲'] = { ['核熱'] = {'核熱', 2}, ['重力'] = {'闇', 3} },
    ['光'] = { ['光'] = {'光', 3} },
    ['闇'] = { ['闇'] = {'闇', 3} },
}

local function get_skillchain_result(elements1, elements2, has_ionic_am)
    local best_sc = nil
    local best_level = 0
    for _, elem1 in ipairs(elements1) do
        local row = SC[elem1]
        for _, elem2 in ipairs(elements2) do
            if has_ionic_am then
                if elem1 == '光' and elem2 == '光' then return '極光', 4
                elseif elem1 == '闇' and elem2 == '闇' then return '黒闇', 4 end
            end
            local hit = row and row[elem2]
            if hit and hit[2] > best_level then best_sc = hit[1]; best_level = hit[2] end
        end
    end
    return best_sc, best_level
end

-- 侍の技と連携属性 (1 つの表。並び順は全自動で選ぶ優先順なので変えない)。名前・属性は Windower の res のとおり
local sam_ws_list = {
    { name = '祖之太刀・不動',   elements = {'光', '湾曲'} },
    { name = '十二之太刀・照破', elements = {'分解', '収縮'} },
    { name = '九之太刀・花車',   elements = {'核熱', '収縮'} },
    { name = '五之太刀・陣風',   elements = {'切断', '炸裂'} },
    { name = '八之太刀・月光',   elements = {'湾曲', '振動'} },
    { name = '七之太刀・雪風',   elements = {'硬化', '炸裂'} },
    { name = '十一之太刀・鳳蝶', elements = {'収縮', '切断'} },
    { name = '十之太刀・乱鴉',   elements = {'重力', '硬化'} },
    { name = '六之太刀・光輝',   elements = {'振動', '衝撃'} },
    { name = '四之太刀・陽炎',   elements = {'溶解'} },
    { name = '参之太刀・轟天',   elements = {'貫通', '衝撃'} },
    { name = '弐之太刀・鋒縛',   elements = {'硬化'} },
    { name = '壱之太刀・燕飛',   elements = {'貫通', '切断'} },
    { name = '絶之太刀・無名',   elements = {'炸裂', '収縮', '湾曲'} },
    { name = 'インパルスドライヴ', elements = {'重力', '硬化'} },   -- 名前は Windower の res のとおり (ヴ)
    { name = 'ソニックスラスト',   elements = {'貫通', '切断'} },
}

-- 技名 → 属性 (sam_ws_list から作る)
local all_ws_elements = {}
for _, ws in ipairs(sam_ws_list) do all_ws_elements[ws.name] = ws.elements end

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

-- 今使える (武器・習得済みの) 技の ID の集合。取れないときは nil (絞り込まない)
local function usable_ws_ids()
    local ok, ab = pcall(windower.ffxi.get_abilities)
    if not ok or type(ab) ~= 'table' or type(ab.weapon_skills) ~= 'table' then return nil end
    local set = {}
    for _, id in ipairs(ab.weapon_skills) do set[id] = true end
    return set
end

local function ws_is_usable(usable, name)
    if not usable then return true end
    local id = ws_id_by_name[name]
    if not id then return true end   -- 一覧に無い名前は、絞らない (判断できない)
    return usable[id] == true
end

local function find_best_sam_ws(target_ws_elements)
    local player = windower.ffxi.get_player()
    if not player or player.main_job ~= 'SAM' then return nil, nil, nil end
    local has_ionic_am = check_ionic_aftermath()
    local usable = usable_ws_ids()

    for level_order = 1, 4 do
        local target_sc_level = (level_order == 1 and 3) or (level_order == 2 and 4) or (level_order == 3 and 2) or 1
        for _, ws in ipairs(sam_ws_list) do
            local sc_name, sc_lvl = get_skillchain_result(target_ws_elements, ws.elements, has_ionic_am)
            if sc_lvl == target_sc_level and ws_is_usable(usable, ws.name) then
                return ws.name, sc_name, sc_lvl
            end
        end
    end
    return nil, nil, nil
end

local DEFAULT_TP = 1000      -- 次の技を撃つ TP
local ACCEPT_WINDOW = 2.5    -- 待機秒数のあと、TP や距離を待つ秒数 (受付)
local LAND_TIMEOUT = 8       -- 送ってから着弾を待つ秒数。過ぎたら古い予約として捨てる
local AUTO_MAX_WS = 6        -- 全自動: 1 回の連携で送る /ws の上限
local AUTO_MAX_SEC = 75      -- 全自動: 1 回の連携を続ける秒数の上限
local AUTO_TOTAL_MAX = 12    -- 全自動: 通算の上限 (AUTO_TOTAL_SEC 秒のあいだに送る /ws の回数)
local AUTO_TOTAL_SEC = 300
local AUTO_PARTY_SEC = 600   -- 全自動: 自分の手動の始点も //sc start も無いまま、PT の始点だけで続けられる秒数

-- 行動できない状態 (res/buffs.lua: 2 睡眠 / 7 石化 / 10 スタン / 14 魅了 / 16 アムネジア / 17 魅了 / 19 睡眠 / 28 テラー / 193 ララバイ)
local INCAPACITATED = {[2] = true, [7] = true, [10] = true, [14] = true, [16] = true, [17] = true, [19] = true, [28] = true, [193] = true}

-- 送った技の記録 (cancel_all では消さない)。送ってから LAND_TIMEOUT 秒のあいだ、自分のこの技の着弾は
-- 予約の確認 (confirm) にならなくても新しい始点にしない (取り消しの直後に着弾した自動の技から、また始めないため)
-- 1 件 = 1 回の送信 {ws, target_id, at, token}。token は送った予約の番号 (st.token)。
-- 着弾は送った順に 1 件ずつ結びつけ、結びついた記録の token が今の予約のときだけ確認 (confirm) にする
-- 0x029 の失敗通知は個々の送信に結び付かないため、着弾がなければ LAND_TIMEOUT で予約を捨てる
-- ゾーン移動・ログアウト・アンロードで消す
local sent_log = {}
local saw_injected_ws = false
local function sent_log_clear()
    saw_injected_ws = false
    for i = #sent_log, 1, -1 do sent_log[i] = nil end
end
local function sent_log_prune(now)
    for i = #sent_log, 1, -1 do
        local at = tonumber(sent_log[i].at)
        if not at or now - at >= LAND_TIMEOUT then table.remove(sent_log, i) end
    end
end
local function sent_log_add(ws, target_id, now, token)
    sent_log_prune(now)
    local entry = {ws = ws, target_id = target_id, at = now, token = token}
    -- 再予約は受付時間内に送る。前回分が残る場合はどちらの着弾でも次段を起動しない。
    for _, old in ipairs(sent_log) do
        if old.ambiguous and old.ws == ws and old.target_id == target_id then
            entry.ambiguous = true
            break
        end
    end
    sent_log[#sent_log + 1] = entry
end
-- 記録にあるか (取り除かない)
local function sent_log_has(ws, target_id, now)
    for i = 1, #sent_log do
        local e = sent_log[i]
        if e.ws == ws and e.target_id == target_id and now - e.at < LAND_TIMEOUT then return true end
    end
    return false
end
-- 記録にあれば、いちばん古い 1 件を取り除いて返す (無ければ nil)
local function sent_log_take(ws, target_id, now)
    sent_log_prune(now)
    for i = 1, #sent_log do
        local e = sent_log[i]
        if e.ws == ws and e.target_id == target_id then
            if e.ambiguous and (e.requests or 0) > 1 then
                e.requests = e.requests - 1
            else
                table.remove(sent_log, i)
            end
            return e
        end
    end
    return nil
end
-- 全自動の通算の記録 (送った時刻の表。cancel_all・//sc reset では消さない)
-- ゾーン移動・ログアウト・アンロード・//sc stop・//sc start で消す
local auto_total = {}
local auto_total_noticed = false
-- PT (フェイスを含む) の始点だけで全自動が続いている始まりの時刻 (cancel_all では消さない)
-- 自分の手動の始点・//sc start (OFF → ON)・ゾーン移動・ログアウト・アンロード・//sc stop と、
-- 戦闘が終わったとき (交戦の解除・前の PT の始点の敵が倒れた/いなくなった) で消す (ユーザー決定 2026-11-15)
-- auto_party_target: 最後に PT の始点で全自動を始めた敵の id
local auto_party_since = nil
local auto_party_noticed = false
local auto_party_target = nil
local function auto_party_clear()
    auto_party_since = nil
    auto_party_noticed = false
    auto_party_target = nil
end
local function auto_total_clear()
    for i = #auto_total, 1, -1 do auto_total[i] = nil end
    auto_total_noticed = false
end
local function auto_total_count(now)
    for i = #auto_total, 1, -1 do
        if now - auto_total[i] >= AUTO_TOTAL_SEC then table.remove(auto_total, i) end
    end
    if #auto_total < AUTO_TOTAL_MAX then auto_total_noticed = false end
    return #auto_total
end

-- 草薙剣モードが有効で装備中か (草薙剣モードの節で中身を入れる。撃つ直前の確認で使うので先に名前だけ置く)
local kusanagi_active
local kus_wait_aftermath
local KUS_AM_TP = 3000
local KUS_MUMEI = '絶之太刀・無名'
local function has_any_aftermath(player)
    player = player or windower.ffxi.get_player()
    for _, buff_id in pairs(player and player.buffs or {}) do
        if buff_id >= 270 and buff_id <= 273 then return true end
    end
    return false
end
local focus = {next_poll=0}
function focus.required_tp(now, ws, player)
    if ws == KUS_MUMEI and not has_any_aftermath(player) then return KUS_AM_TP end
    return focus.normal_tp_at and now >= focus.normal_tp_at and 1500 or 2550
end
local focus_slots = {'p1','p2','p3','p4','p5','a10','a11','a12','a13','a14','a15','a20','a21','a22','a23','a24','a25'}
function focus.eligible(player, target, count_all)
    if not settings.enabled or not settings.focus or not player or player.status ~= 1 or player.main_job ~= 'SAM'
        or not target or target.spawn_type ~= 16 or not target.index or target.index <= 0 or (target.hpp or 0) <= 0 then return false end
    if not get_active_route() then return false end
    local party = windower.ffxi.get_party()
    if not party then return false end
    local first
    local seen = count_all and {} or nil
    local count = 0
    for _, slot in ipairs(focus_slots) do
        local mob = party[slot] and party[slot].mob
        if mob and mob.is_npc == false and mob.id and mob.id ~= player.id and mob.target_index == target.index then
            if seen then
                if not seen[mob.id] then seen[mob.id] = true; count = count + 1 end
            else
                if first and first ~= mob.id then return true end
                first = mob.id
            end
        end
    end
    return count >= 2, count
end

function focus.weapon_skill()
    local eq = windower.ffxi.get_items('equipment')
    if type(eq) ~= 'table' or not eq.main or eq.main == 0 then return end
    local item = windower.ffxi.get_items(eq.main_bag, eq.main)
    local row = item and res.items[item.id]
    if not row then return end
    local ws
    if settings.kusanagi == true and row.en == 'Kusanagi' then ws = '絶之太刀・無名'
    elseif row.en == 'Dojikiri Yasutsuna' then ws = '十二之太刀・照破'
    elseif row.skill == 10 then ws = '祖之太刀・不動' end
    local usable = ws and usable_ws_ids()
    if usable and usable[ws_id_by_name[ws]] then return ws end
end

-- 撃つ直前の確認。戻り値: 'ok' と player / 'wait' と player (届かない) / 'cancel' と理由
-- (valid_target は使わない: 大きな敵で、手動なら通るのに false になることがあるため。OmniChain と同じ)
local function can_fire(spec, now)
    local player = windower.ffxi.get_player()
    if not player then return 'cancel', '自分の情報が取れないので、予約を取り消しました。' end
    if player.status ~= 1 then return 'cancel', '交戦状態でなくなったので、予約を取り消しました。' end
    local buffs = player.buffs
    if buffs then
        for i = 1, #buffs do
            if INCAPACITATED[buffs[i]] then return 'cancel', '行動できない状態なので、予約を取り消しました。' end
        end
    end
    local t = windower.ffxi.get_mob_by_target('t')
    if spec.focus then
        if not focus.eligible(player, t) or not t.distance or focus.weapon_skill() ~= spec.ws then
            return 'cancel', '集中攻撃の対象・人数・装備が変わったので予約を取り消しました。'
        end
    elseif focus.eligible(player, t) then
        return 'cancel', '集中攻撃の人数に達したので連携の予約を取り消しました。'
    elseif spec.kusanagi then
        if not get_active_route() then return 'cancel', '選択中のルートがないので予約を取り消しました。' end
        if not kusanagi_active() then return 'cancel', '[草薙剣] 草薙剣を外した / 草薙剣モードを OFF にしたので、無名の予約を取り消しました。' end
    elseif kusanagi_active() then
        return 'cancel', '草薙剣モードが有効になったので、ルートの予約を取り消しました。'
    end
    if not t or t.id ~= spec.target_id then return 'cancel', '予約した相手がターゲットでなくなったので、予約を取り消しました。' end
    if t.hpp and t.hpp <= 0 then return 'cancel', '予約した相手が倒れたので、予約を取り消しました。' end
    if t.distance then
        -- 大きな敵は体の分だけ遠くから届く (model_size が 2 を超えた分だけ広げる。OmniChain と同じ)
        local reach = (tonumber(settings.ws_reach) or 3.5) + math.max(0, (tonumber(t.model_size) or 0) - 2.0)
        if math.sqrt(t.distance) > reach then return 'wait', player end
    end
    if spec.is_auto and now - st.auto_start >= AUTO_MAX_SEC then
        return 'cancel', '自動: 連続時間の上限 (' .. AUTO_MAX_SEC .. ' 秒) に達したので止めます。'
    end
    return 'ok', player
end

-- 技を予約する。spec = {ws, sc_result, is_solo, label, delay, target_id, min_tp, max_wait, abort, is_auto, kusanagi}
--   予約した時刻 (os.clock) から delay 秒たったら、確認 (can_fire) が通り TP が足りていれば /ws を 1 回だけ送る
--   受付 (delay + max_wait または ACCEPT_WINDOW 秒) を過ぎたら送らずに取り消す (時間は os.clock の差で数える)
--   送ったあと LAND_TIMEOUT 秒たっても着弾を確かめられなければ、古い予約として取り消す
local function schedule_ws(spec)
    st.token = st.token + 1
    local my = st.token
    st.pending = {ws = spec.ws, sent_at = nil}
    st.target_id = spec.target_id
    local need = spec.min_tp or DEFAULT_TP
    local interval = spec.max_wait and 0.5 or 0.2
    local window = spec.max_wait or (spec.delay + ACCEPT_WINDOW)
    local start = os.clock()
    -- 時計が進まない異常に備えた、回る回数の上限 (ふつうは window / interval 回ほどで終わる)
    local max_loops = math.ceil(window / interval) * 4 + 50
    coroutine.schedule(function()
        local last   -- 直前の確認の結果 ('ok' / 'wait')。時間切れの理由の表示に使う
        local loops = 0
        while true do
            if my ~= st.token then return end
            if spec.abort and spec.abort() then
                cancel_all(spec.abort_reason)
                return
            end
            local now = os.clock()
            local elapsed = now - start
            loops = loops + 1
            if elapsed > window + 1e-6 or loops > max_loops then
                if spec.max_wait then
                    cancel_all('[草薙剣] TP ' .. need .. ' に達しなかったので、アフターマス付けの無名をやめます。')
                elseif last == 'wait' then
                    cancel_all('相手が遠いまま受付時間を過ぎたので、[' .. spec.ws .. '] の予約を取り消しました。')
                else
                    cancel_all('エラー: 待機時間終了後、受付時間内にTP' .. need .. 'に達しなかったため発動できませんでした。')
                end
                return
            end
            local verdict, info = can_fire(spec, now)
            if verdict == 'cancel' then
                cancel_all(info)
                return
            end
            last = verdict
            local tp = verdict == 'ok' and info.vitals and info.vitals.tp or 0
            if verdict == 'ok' and spec.kusanagi and st.mode == 'kusanagi' and not has_any_aftermath(info) then
                cancel_all(nil)
                kus_wait_aftermath(spec.is_solo, spec.target_id)
                return
            end
            if elapsed >= spec.delay - 1e-6 and verdict == 'ok' and tp >= (spec.focus and focus.required_tp(now, spec.ws, info) or need) then
                local prefix = spec.is_solo and '【一人連携】' or '【PT連携】'
                local label_str = spec.label and (' [' .. spec.label .. ']') or ''
                local sc_str = spec.sc_result and (' (目標:' .. spec.sc_result .. ')') or ''
                msg(prefix .. label_str .. ' TP:' .. tp .. ' で次技自動発動 -> [' .. spec.ws .. ']' .. sc_str, 209)
                st.pending.sent_at = now
                sent_log_add(spec.ws, spec.target_id, now, my)
                if spec.is_auto or spec.focus then auto_total[#auto_total + 1] = now end
                if spec.focus then
                    focus.waiting = true
                    focus.count = focus.count + 1
                    focus.first = focus.first or now
                    focus.ready_at = now + 2
                end
                windower.send_command(sjis('input /ws "' .. spec.ws .. '" <t>'))
                break
            end
            coroutine.sleep(interval)
        end
        -- 着弾の期限
        coroutine.sleep(LAND_TIMEOUT + 0.1)
        local p = st.pending
        if my == st.token and p and p.sent_at and os.clock() - p.sent_at >= LAND_TIMEOUT then
            cancel_all('前の予約の状態が古いので捨てます (着弾を確認できませんでした)')
        end
    end, 0.01)
end

windower.register_event('prerender', function()
    if not settings.enabled or not settings.focus then return end
    local now = os.clock()
    if now < focus.next_poll then return end
    focus.next_poll = now + 0.25
    local player = windower.ffxi.get_player()
    local target = windower.ffxi.get_mob_by_target('t')
    local eligible, count = focus.eligible(player, target, true)
    if not eligible then
        if count ~= nil and focus.target == target.id then
            msg(('通常連携の始点待ちへ：敵ID=%s 同じ敵を狙う味方PC=%d人'):format(target.id, count), 158)
        end
        focus.target = nil
        if st.mode == 'focus' and st.pending and not st.pending.sent_at then cancel_all(nil) end
        return
    end
    if st.pending and st.pending.sent_at then return end
    if focus.target ~= target.id then
        focus.target, focus.count, focus.first, focus.waiting = target.id, 0, nil, false
        focus.normal_tp_at = now + 6
        msg(('集中攻撃へ：敵ID=%s 同じ敵を狙う味方PC=%d人'):format(target.id, count), 158)
    end
    if st.mode == 'focus' then return end
    if is_running() then cancel_all('同じ敵を狙う味方が2人以上のため、集中攻撃に切り替えます。', 158) end
    if focus.waiting or now < (focus.ready_at or 0) or focus.count >= AUTO_MAX_WS
        or (focus.first and now - focus.first >= AUTO_MAX_SEC) or auto_total_count(now) >= AUTO_TOTAL_MAX
        or not player.vitals or (player.vitals.tp or 0) < focus.required_tp(now) or not target.distance then return end
    local reach = settings.ws_reach + math.max(0, (tonumber(target.model_size) or 0) - 2)
    if target.distance > reach * reach then return end
    for _, buff in ipairs(player.buffs or {}) do if INCAPACITATED[buff] then return end end
    local ws = focus.weapon_skill()
    if ws and player.vitals.tp >= focus.required_tp(now, ws, player) then
        st.mode = 'focus'
        schedule_ws{focus=true, ws=ws, target_id=target.id, delay=0, min_tp=1500, label='集中攻撃'}
    end
end)


-- -----------------------------------------------------------------------------
-- 草薙剣モード。この手元版の既定は ON、公開版 v5.5.0 の既定は OFF。
--   侍が草薙剣 (メイン) を装備している間、ルートより先にこちらが動く:
--   ・始点 = 十一之太刀・鳳蝶 / 参之太刀・轟天 (自分でも仲間でも)。そのあと 絶之太刀・無名 を、連携が続くかぎり撃つ
--     (鳳蝶 → 無名 → 無名 → 無名 で 闇。轟天からは無名が 1 回多くなることがある。連携が閉じる / 失敗したら止めて、始点待ちへ戻る)
--   ・アフターマスが無いときは、始点を見ても連携を追わず、無名を 1 回撃ってアフターマスを付ける (次の始点から連携)
--   ・上限は 6 回 (暴走防止)。//sc reset で止まる。//sc kusanagi on|off で切り替え
-- -----------------------------------------------------------------------------
local KUS_OPENERS = {['十一之太刀・鳳蝶'] = true, ['参之太刀・轟天'] = true}
local KUS_MAX_MUMEI = 6
local KUS_STALE_SEC = 30  -- この秒数をこえて予約が無いまま st.kus_count が残っていたら、古い状態とみなす
local KUS_NOTICE_SEC = 60 -- 「ルートは動きません」の知らせを、技を捨てたときに出す間隔

local function kusanagi_equipped()
    local value = false
    local ok, eq = pcall(windower.ffxi.get_items, 'equipment')
    local index = ok and type(eq) == 'table' and eq.main
    if index and index ~= 0 then
        local ok2, item = pcall(windower.ffxi.get_items, eq.main_bag, index)
        local info = ok2 and item and res.items and res.items[item.id]
        value = info ~= nil and info ~= false and info.en == 'Kusanagi'
    end
    return value
end

-- 草薙剣モードが有効で装備中か (このあいだ、ルートは動かない)
kusanagi_active = function()
    return settings.kusanagi == true and kusanagi_equipped()
end

local function kusanagi_notice_text()
    return '草薙剣モードが有効で装備中のため、ルート ' .. tostring(settings.active_route) .. ' は動きません (//sc kusanagi off で戻す)'
end

-- 草薙剣モードが技を捨てたときの知らせ (60 秒に 1 回だけ)
local function kusanagi_notice_throttled()
    local now = os.clock()
    if now - st.notice_at < KUS_NOTICE_SEC then return end
    st.notice_at = now
    msg(kusanagi_notice_text(), 158)
end


local function kus_reset(why)
    cancel_all(why and ('[草薙剣] ' .. why) or nil, 158)
end

-- アフターマス付けの無名を、TP 3000 になるまで待ってから撃つ (最長 120 秒・付いた / 武器を替えた / OFF にしたら取り消す)
local KUS_AM_WAIT = 120   -- アフターマス付けの無名で、TP が貯まるのを待つ最長の秒数
kus_wait_aftermath = function(is_me, target_id, since)
    local now = os.clock()
    since = since or now                 -- 入り直しのときは、最初の待ちの開始時刻を持ち越す
    local left = KUS_AM_WAIT - (now - since)
    if left <= 0 then
        cancel_all('[草薙剣] TP ' .. KUS_AM_TP .. ' に達しなかったので、アフターマス付けの無名をやめます。')
        return
    end
    st.mode = 'kus_am'
    st.kus_am_since = since
    schedule_ws{
        ws = KUS_MUMEI, is_solo = is_me, label = '草薙剣', delay = settings.kusanagi_delay or 5.0, target_id = target_id,
        kusanagi = true,
        min_tp = KUS_AM_TP,
        max_wait = left,   -- TP が貯まるのを待つ秒数 (開始から KUS_AM_WAIT 秒まで)
        abort = function() return has_any_aftermath() or not kusanagi_equipped() or not settings.enabled or settings.kusanagi == false end,   -- 付いた・武器を替えた・OFF にしたら取り消す
        abort_reason = '[草薙剣] アフターマスが付いた / 武器を替えた / OFF にしたので、アフターマス付けの無名を取り消しました。',
    }
end

-- 次の無名を予約する。つながらない (連携が閉じた) ときは予約せず終わる
local function kus_next_mumei(is_me, result_name, target_id)
    local mumei_elements = all_ws_elements[KUS_MUMEI]
    if not st.kus_prev or not get_skillchain_result({st.kus_prev}, mumei_elements, false) then
        kus_reset('連携が閉じたので終わります (' .. tostring(st.kus_prev) .. ')')
        return
    end
    if st.kus_count >= KUS_MAX_MUMEI then
        -- (PT の始点で入り直した直後は、もう取り消してあるので cancel_all の知らせは出ない。ここで必ず知らせる)
        msg('[草薙剣] 無名の上限 (' .. KUS_MAX_MUMEI .. ' 回) に達したので終わります', 158)
        cancel_all(nil)
        return
    end
    -- 連携の途中でアフターマスが切れた: 連携は続けず、TP 3000 になってから無名で付け直す (ユーザー指示 2026-11-06)
    if not has_any_aftermath() then
        kus_reset(nil)
        msg('[草薙剣] 連携の途中でアフターマスが切れたので、連携は続けず TP ' .. KUS_AM_TP .. ' になったら 無名 で付け直します', 158)
        kus_wait_aftermath(is_me, target_id)
        return
    end
    st.kus_count = st.kus_count + 1
    st.kus_last = os.clock()
    st.mode = 'kusanagi'
    msg('[草薙剣] ' .. st.kus_count .. ' 回目の無名を予約 (' .. tostring(st.kus_prev) .. ' → ' .. string.format('%.1f', settings.kusanagi_delay or 5.0) .. ' 秒後)', 209)
    schedule_ws{ws = KUS_MUMEI, sc_result = result_name, is_solo = is_me, label = '草薙剣',
                delay = settings.kusanagi_delay or 5.0, target_id = target_id, kusanagi = true}
end

-- 技を使った人の種類: 'me' (自分) / 'party' (自分の PT の p1〜p5。フェイスを含む・アライアンスは含めない) / 'other'
local PARTY_KEYS = {'p1', 'p2', 'p3', 'p4', 'p5'}
local function actor_kind(actor_id, player)
    if actor_id == player.id then return 'me' end
    local party = windower.ffxi.get_party()
    if type(party) == 'table' then
        for i = 1, #PARTY_KEYS do
            local m = party[PARTY_KEYS[i]]
            local mob = type(m) == 'table' and m.mob
            if mob and mob.id == actor_id then return 'party' end
        end
    end
    return 'other'
end

-- 始点にしてよい使用者か (自分は solo_mode・PT は party_mode。ほかの人の技は始点にしない)
local function can_start(kind)
    if kind == 'me' then return settings.solo_mode and true or false end
    if kind == 'party' then return settings.party_mode and true or false end
    return false
end

-- 草薙剣モード: ws_name を kind の人が使った。confirm = 自分の予約した無名の着弾
local function handle_kusanagi(act, ws_name, kind, confirm, target_id)
    -- 追っている途中で、最後の予約から長く経っていたら古い状態として捨てる
    -- (TP 待ちの時間切れや着弾の取りこぼしのあと、数分後の無名を「連携の続き」と取り違えないため)
    -- (送ったあとの予約は着弾の期限 (8 秒) で先に捨てるので、ここに来るのは送る前の予約が残ったまま
    --  コルーチンが止まっていたときの保険)
    if st.kus_count > 0 and os.clock() - st.kus_last > KUS_STALE_SEC then
        kus_reset('最後の予約から ' .. KUS_STALE_SEC .. ' 秒をこえた古い状態なので捨てます')
        confirm = false
    end
    -- PT (フェイスを含む) の始点で入り直すときは、無名の回数 (上限 6 回) とアフターマス付けの待ちの開始時刻を持ち越す
    local keep_count, keep_am_since = 0, nil
    local is_opener = KUS_OPENERS[ws_name] and can_start(kind)
    if st.mode == 'kus_am' then
        -- アフターマス付けの無名を待っている: 自分の無名の着弾で終わる。始点は付け直しの待ちをやり直す。ほかの人の技なら取り消す
        if confirm then cancel_all(nil) return end
        if kind == 'other' then kus_reset('PT 外の技 [' .. ws_name .. '] が入ったので、アフターマス付けの無名を取り消します') return end
        if not is_opener then kusanagi_notice_throttled() return end
        if not can_open_route(act, target_id, ws_name) then return end
        keep_am_since = st.kus_am_since
        cancel_all(nil)
    elseif st.mode == 'kusanagi' then
        -- 追っている途中
        if confirm then
            local result = skillchain_of(act, target_id)
            if result then
                msg('★連携発生 [' .. result .. '] (無名 ' .. st.kus_count .. ' 回目)', 209)
                st.kus_prev = result
                kus_next_mumei(kind == 'me', result, target_id)
            else
                kus_reset('無名で連携が発生しなかったので、始点待ちへ戻ります')
            end
            return
        end
        if not is_opener then
            kus_reset('想定外の技 [' .. ws_name .. '] が入ったので、始点待ちへ戻ります')
            return
        end
        -- 途中で始点が撃ち直された: 取り消して、始点として扱い直す
        if kind == 'party' then keep_count = st.kus_count end
        cancel_all(nil)
    end

    -- 追っていない: 始点を待つ (始点以外の技・始点にしない人の技は追撃しない。捨てたことは 60 秒に 1 回知らせる)
    if not is_opener then kusanagi_notice_throttled() return end
    if not can_open_route(act, target_id, ws_name) then return end
    if not has_any_aftermath() then
        msg('[草薙剣] アフターマスが無いので、連携は追わず TP ' .. KUS_AM_TP .. ' になったら 無名 でアフターマスを付けます', 209)
        kus_wait_aftermath(kind == 'me', target_id, keep_am_since)
        return
    end
    st.kus_count = keep_count
    st.kus_prev = nil
    for _, e in ipairs(all_ws_elements[ws_name] or {}) do
        if get_skillchain_result({e}, all_ws_elements[KUS_MUMEI], false) then st.kus_prev = e break end
    end
    if not st.kus_prev then
        msg('[草薙剣] ' .. ws_name .. ' から無名がつながらないので追いません', 123)
        return
    end
    msg('[草薙剣] 始点 [' .. ws_name .. '] を検知 → 無名を続けます', 209)
    kus_next_mumei(kind == 'me', nil, target_id)
end

-- カスタムルートの step 段目 (action_ws) を予約する。st.step はこの段の着弾を待つ番号 (= step + 1) にする
local function reserve_route_step(route, index, is_solo, target_id, trigger_name)
    local s = route.steps[index]
    st.mode = 'custom'
    st.step = index + 1
    msg('ルート[' .. route.id .. ':' .. (route.name or '') .. '] Step ' .. index .. ': ' .. (index == 1 and ('初段[' .. trigger_name .. ']検知 -> ') or '')
        .. '次技[' .. s.action_ws .. '] (目標:' .. (s.sc_result or '連携') .. ') ' .. delay_text(route) .. ' 待機中...', 209)
    schedule_ws{ws = s.action_ws, sc_result = s.sc_result, is_solo = is_solo, label = route.name,
                delay = effective_delay(route), target_id = target_id}
end

-- カスタムルート: 自分の予約の着弾 (confirm) で次の段へ進む。初段は始点にしてよい人の trigger_ws。ほかの技が入ったら取り消す
-- (2 段目以降の trigger_ws は進行には使わない。前の段の action_ws の着弾だけを見る。読み込みで前段とのずれを警告するだけ)
local function handle_custom(route, act, ws_name, kind, confirm, target_id)
    local steps = route.steps
    if confirm and st.mode == 'custom' then
        local done_index = st.step - 1
        local done = steps[done_index]
        local sc = skillchain_of(act, target_id)
        if not sc then
            cancel_all('【連携不成立・追撃中断】 [' .. ws_name .. '] で連携が発生しなかったため、最初の初段待機状態へリセットします。')
            return
        end
        -- どの連携でも進む。目標 (sc_result) と違ったときは、その旨を添える
        local note = (done and done.sc_result and done.sc_result ~= sc) and (' (目標の ' .. done.sc_result .. ' とは違いました)') or ''
        msg('★連携発生成功 [' .. sc .. ']！' .. note .. ' (Step ' .. done_index .. ' 完了)', 209)
        if not steps[st.step] then
            cancel_all('★ルート完遂！ 最初の初段待機状態(Step 1)へリセットします。', 158)
            return
        end
        reserve_route_step(route, st.step, true, target_id)
        return
    end
    if ws_name == steps[1].trigger_ws and can_start(kind) then
        if is_running() then cancel_all(nil) end   -- 途中で初段が撃ち直された: 最初からやり直す
        if not can_open_route(act, target_id, ws_name) then return end
        reserve_route_step(route, 1, kind == 'me', target_id, ws_name)
        return
    end
    if is_running() then
        cancel_all('【ルート外WS検知】 [' .. ws_name .. '] が入ったので、連携シーケンスを解除し初段待機状態へリセットします。')
    end
end

-- 全自動: 連携が閉じたか (極光・黒闇・特殊、または 光→光 / 闇→闇)
local function auto_closed(sc)
    if sc == '極光' or sc == '黒闇' or sc == '特殊(302)' then return true end
    return (sc == '光' or sc == '闇') and st.chain_prop == sc
end

-- 全自動: props (属性の一覧) につながる、いちばん階層の高い技を予約する。上限を超えるなら止める
local function auto_reserve(route, props, from_label, is_solo, target_id)
    if auto_total_count(os.clock()) >= AUTO_TOTAL_MAX then
        cancel_all('自動: 通算の上限 (' .. AUTO_TOTAL_SEC .. ' 秒のうち ' .. AUTO_TOTAL_MAX .. ' 回) に達したので止めます。間が空けば、次の始点 (自分・PT) から再開します。', 158)
        auto_total_noticed = true
        return
    end
    if st.auto_count >= AUTO_MAX_WS or os.clock() - st.auto_start >= AUTO_MAX_SEC then
        cancel_all('自動: 1 回の連携の上限 (' .. AUTO_MAX_WS .. ' 回・' .. AUTO_MAX_SEC .. ' 秒) に達したので止めます。', 158)
        return
    end
    local next_ws, sc_result, sc_level = find_best_sam_ws(props)
    if not next_ws then
        cancel_all('自動: [' .. from_label .. '] のあとにつながる技が無いので止めます。', 158)
        return
    end
    st.auto_count = st.auto_count + 1
    msg('AIソルバー: 前[' .. from_label .. ']検知 -> 最高階層連携【' .. sc_result .. ' (Lv' .. sc_level .. ')】 [' .. next_ws .. '] '
        .. delay_text(route) .. ' 待機中... (' .. st.auto_count .. '/' .. AUTO_MAX_WS .. ' 回目)', 209)
    schedule_ws{ws = next_ws, sc_result = sc_result, is_solo = is_solo, label = '自動AIソルバー',
                delay = effective_delay(route), target_id = target_id, is_auto = true}
end

-- 全自動: 始点 (自分の手動の技 / PT の技) の属性から選び、そのあとは「起きた連携」だけから選ぶ
--   自分の予約した技が連携しなかった・外れた・連携が閉じた・上限 → 止める (自分の自動の技を新しい始点にしない)
local function handle_auto(route, act, ws_name, ws_elements, kind, confirm, target_id)
    if confirm and st.mode == 'auto' then
        if not landed_on(act, target_id) then
            cancel_all('自動: [' .. ws_name .. '] が当たらなかったので止めます。')
            return
        end
        local sc = skillchain_of(act, target_id)
        if not sc then
            cancel_all('自動: 連携が起きなかったので止めます')
            return
        end
        if auto_closed(sc) then
            cancel_all('自動: 連携 [' .. sc .. '] で閉じたので止めます。', 158)
            return
        end
        msg('★連携発生 [' .. sc .. '] (自動 ' .. st.auto_count .. ' 回目)', 209)
        st.chain_prop = sc
        auto_reserve(route, {sc}, sc, true, target_id)
        return
    end
    if can_start(kind) and ws_elements and #ws_elements > 0
        and landed_on(act, target_id) and not skillchain_of(act, target_id) then
        -- 新しい始点 (当たっていて、それ自体は連携を起こしていない技)
        -- PT (フェイスを含む) の始点で入り直すときは、回数と時間を戻さない (PT の技で上限が戻り続けないように)。
        -- ただし別の敵 (前の戦闘) の回数は持ち越さない (戦闘が終わったら戻す: ユーザー決定 2026-11-15)
        local keep_count, keep_start
        if kind == 'party' and st.mode == 'auto' and st.target_id == target_id then
            keep_count, keep_start = st.auto_count, st.auto_start
        end
        if is_running() then cancel_all(nil) end
        if not find_best_sam_ws(ws_elements) then return end   -- つながる技が無い始点は、黙って見送る
        local now = os.clock()
        if auto_total_count(now) >= AUTO_TOTAL_MAX then
            -- 通算の上限: 窓が空くまで始めない (知らせは 1 回だけ)
            if not auto_total_noticed then
                auto_total_noticed = true
                msg('自動: 通算の上限 (' .. AUTO_TOTAL_SEC .. ' 秒のうち ' .. AUTO_TOTAL_MAX .. ' 回) に達しているので始めません。', 158)
            end
            return
        end
        if kind ~= 'me' and auto_party_target ~= nil and auto_party_target ~= target_id then
            -- 前の PT の始点の敵が倒れた・いなくなった: 戦闘が終わったので数え直す (敵が替わったときだけ引く)
            local old = windower.ffxi.get_mob_by_id(auto_party_target)
            if old == nil or (type(old.hpp) == 'number' and old.hpp <= 0) then auto_party_clear() end
        end
        if kind == 'me' then
            auto_party_clear()                 -- 自分の手動の始点: PT の始点だけの連続時間を数え直す
        elseif not auto_party_since then
            auto_party_since = now             -- PT の始点だけで続く全自動の始まり
        elseif now - auto_party_since >= AUTO_PARTY_SEC then
            if not auto_party_noticed then
                auto_party_noticed = true
                msg('自動: PT の始点だけで ' .. AUTO_PARTY_SEC .. ' 秒続いたので、自分の手動の始点か //sc start まで止めます。交戦を解く・敵が倒れると数え直します。', 158)
            end
            return
        end
        if kind ~= 'me' then auto_party_target = target_id end
        st.mode = 'auto'
        st.auto_count = keep_count or 0
        st.auto_start = keep_start or os.clock()
        st.chain_prop = nil
        auto_reserve(route, ws_elements, ws_name, kind == 'me', target_id)
        return
    end
    if is_running() then
        cancel_all('自動: [' .. ws_name .. '] が入った (始点にしない人の技・外れ・ほかの連携) ので止めます。')
    end
end

local recent = {}
local recent_count = 0
local function recent_key(actor_id, param, target_id)
    return tostring(actor_id) .. '|' .. tostring(param) .. '|' .. tostring(target_id)
end

local function read_action_fields(direction, raw, modified, min_length)
    local data = modified or raw
    if type(data) ~= 'string' or #data < min_length then return end
    local ok, fields = pcall(packets.parse, direction, data)
    if ok and type(fields) == 'table' then return fields end
end
-- GearSwap がコマンドを処理済みでも元の入力を参照する。
windower.register_event('outgoing text', function(original)
    if type(original) ~= 'string' or not st.pending or not st.pending.sent_at then return end
    local prefix = original:match('^%s*(/%S+)')
    if not prefix then return end
    prefix = prefix:lower()
    if prefix ~= '/ws' and prefix ~= '/weaponskill' then return end
    for _, entry in ipairs(sent_log) do
        if entry.token == st.token then
            if entry.command_seen then entry.ambiguous = true end
            entry.command_seen = true
        end
    end
end)
windower.register_event('outgoing chunk', function(id, raw, modified, injected, blocked)
    if id ~= 0x01A or blocked then return end
    if #sent_log == 0 and (saw_injected_ws or not injected) then return end
    local fields = read_action_fields('outgoing', raw, modified, 16)
    if not fields or fields.Category ~= 7 then return end
    if injected then saw_injected_ws = true end
    if #sent_log == 0 then return end
    local ws = res.weapon_skills[fields.Param]
    local now = os.clock()
    sent_log_prune(now)
    for i = #sent_log, 1, -1 do
        local entry = sent_log[i]
        if ws and ws.ja == entry.ws and fields.Target == entry.target_id then
            entry.requests = (entry.requests or 0) + 1
            -- 注入とクライアント直接送信が混在するときは、直接送信の着弾で次段へ進めない。
            if entry.requests > 1 or (saw_injected_ws and injected == false) then
                entry.ambiguous = true
            end
            break
        end
    end
end)

windower.register_event('action', function(act)
    if not settings.enabled then return end
    if not act or act.category ~= 3 then return end

    -- 送ってから LAND_TIMEOUT 秒たっても着弾を確かめられなかった予約は、古い状態として捨てる (コルーチンの保険)
    local p = st.pending
    if p and p.sent_at and os.clock() - p.sent_at >= LAND_TIMEOUT then
        cancel_all('前の予約の状態が古いので捨てます (着弾を確認できませんでした)')
    end

    local player = windower.ffxi.get_player()
    if not player or player.main_job ~= 'SAM' or player.status ~= 1 then return end

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

    local r_key = recent_key(act.actor_id, act.param, my_target.id)
    local now = os.clock()
    if recent[r_key] and (now - recent[r_key]) < (settings.block_seconds or 1.5) then
        -- 自分が送った技の着弾は、重複よけで捨てない (照破 → 照破 などで、待機秒数が block_seconds に近いとき)
        local e = act.actor_id == player.id and res.weapon_skills[act.param]
        if not (e and e.ja and sent_log_has(e.ja, my_target.id, now)) then return end
    end
    recent[r_key] = now
    recent_count = recent_count + 1
    if recent_count >= 64 then   -- 古い記録を掃除する (増え続けないように)
        recent_count = 0
        local keep = (settings.block_seconds or 1.5)
        for k, t in pairs(recent) do
            if now - t >= keep then recent[k] = nil end
        end
    end

    local entry = res.weapon_skills[act.param]
    if not entry then return end

    local ws_display_name, ws_elements = resolve_ws_elements({entry = entry})
    if not ws_display_name then return end

    -- 進める (confirm) のは、自分が使った・予約中の技と同じ名前・予約した相手への着弾で、
    -- 結びついた送信の記録が今の予約で送ったもののときだけ
    -- (前の予約で送った技の着弾では進めない)
    -- 始めるのは自分 (solo_mode) / PT (party_mode)。止める (取り消し) のは誰の技でも
    local kind = actor_kind(act.actor_id, player)
    if kind == 'me' and focus.target == my_target.id and landed_on(act, my_target.id) then
        focus.normal_tp_at = now + 6
    end
    local pend = st.pending
    local sent = kind == 'me' and sent_log_take(ws_display_name, my_target.id, now) or nil
    local confirm = sent ~= nil and sent.requests and sent.command_seen and not sent.ambiguous and sent.token == st.token
        and pend ~= nil and pend.sent_at ~= nil and pend.ws == ws_display_name
        and st.target_id == my_target.id
    if st.mode == 'focus' and sent then
        focus.waiting = not (confirm and landed_on(act, my_target.id))
        cancel_all(nil)
        return
    end
    if focus.eligible(player, my_target) then
        if confirm then cancel_all(nil) end
        return
    end
    if st.mode == 'focus' then
        if pend and pend.sent_at then return end
        cancel_all(nil)
    end
    -- 自分が送った技の着弾は、確認 (confirm) でなければ捨てる (取り消しのあとに着弾した自動の技を、新しい始点にしない)
    -- 進行中なら、それも取り消す (送ったあと着弾の前に入り直して予約が新しくなった: 古い前提のまま次を送らない)
    if sent and not confirm then
        if sent.ambiguous and sent.token ~= st.token then return end
        if is_running() then
            cancel_all('[' .. ws_display_name .. '] の着弾を現在の予約に結び付けられないため、進行を取り消しました。')
        end
        return
    end

    local active_r = get_active_route()
    if not active_r then return end   -- 選択中のルートが無いときは何もしない (読み込み・status で知らせる)

    -- 草薙剣モードが有効になった (on にした・装備した) ら、ルートの進行を取り消す
    local kus_on = kusanagi_active()
    local switched = false
    if kus_on and (st.mode == 'custom' or st.mode == 'auto') then
        cancel_all('草薙剣モードが有効になったので、ルートの進行を取り消しました。', 158)
        switched = true
    elseif not kus_on and (st.mode == 'kusanagi' or st.mode == 'kus_am') then
        kus_reset('草薙剣を外した / 止めたので、追うのをやめます')
        switched = true
    end
    -- 取り消したときは、この着弾を前の予約の確認 (confirm) として扱わない
    -- 自分が送った技 (confirm だったもの) の着弾は、もう一方の新しい始点にもしない (上の sent_log と同じ考え方)
    -- (confirm でない着弾 = 自分の手動の技・PT の技は、取り消したあとも従来どおり始点にしてよい)
    if switched and confirm then return end

    -- 草薙剣モード (侍が草薙剣を装備している間は、ルートの代わりにこちらが処理する)
    if kus_on then
        handle_kusanagi(act, ws_display_name, kind, confirm, my_target.id)
        return
    end


    if active_r.mode == 'custom' then
        handle_custom(active_r, act, ws_display_name, kind, confirm, my_target.id)
    else
        handle_auto(active_r, act, ws_display_name, ws_elements, kind, confirm, my_target.id)
    end
end)

windower.register_event('addon command', function(...)
    local args = {...}
    local cmd = args and args[1] and args[1]:lower() or 'help'

    if cmd == 'focus' then
        local value = args[2] and args[2]:lower()
        if value == 'on' or value == 'off' then
            settings.focus = value == 'on'
            if st.mode == 'focus' then cancel_all(nil) end
            focus.target = nil
            config.save(settings)
        end
        msg('集中攻撃: ' .. (settings.focus and 'ON' or 'OFF') .. ' (//sc focus on|off)')
        return
    end

    if cmd == 'reset' or cmd == 'clear' then
        focus.target = nil
        cancel_all(nil)
        saw_injected_ws = false
        msg('連携ステップを最初の【初段待機状態 (Step 1)】へ手動リセットしました。', 158)
        return
    end

    -- 中断: 予約と進行を取り消して、全体を OFF にする (//sc start で戻す)
    if cmd == 'stop' or cmd == 'abort' or cmd == 'off' then
        focus.target = nil
        cancel_all(nil)
        saw_injected_ws = false
        sent_log_prune(os.clock())
        auto_total_clear()
        auto_party_clear()
        settings.enabled = false
        config.save(settings)
        msg('止めました (予約と進行を取り消し、全体機能を OFF にしました)。//sc start で再開します。', 158)
        return
    end

    if cmd == 'start' or cmd == 'on' then
        if not settings.enabled then   -- OFF → ON のときだけ、通算の上限と PT の始点だけの連続時間を消す (ON のままなら消さない)
            auto_total_clear()
            auto_party_clear()
        end
        settings.enabled = true
        config.save(settings)
        msg('全体機能: 【ON】 (//sc stop で止めます)')
        return
    end

    if cmd == 'fix' then
        if fix_routes(args[2] and args[2]:lower() == 'confirm') then cancel_all(nil) end
        return
    end

    if cmd == 'route' or cmd == 'r' then
        local sub = args[2] and args[2]:lower()
        if not sub or sub == 'status' or sub == 'show' then
            local active_r = get_active_route()
            if not active_r then notify_missing_route(); return end
            msg('==================================================')
            msg('  [AutoSkillchain v' .. _addon.version .. '] 現在の連携ルート設定')
            msg('--------------------------------------------------')
            msg('  ・選択中ルート: ルート ' .. active_r.id .. ' 【 ' .. (active_r.name or '') .. ' 】')
            msg('  ・動作モード: ' .. (active_r.mode or 'custom'))
            msg('  ・現在ステップ: Step ' .. st.step)
            msg('  ・基本待機秒数: ' .. delay_text(active_r))
            msg('==================================================')
            if kusanagi_active() then msg(kusanagi_notice_text(), 158) end
        elseif tonumber(sub) then
            local route_id = tonumber(sub)
            local target_r = find_route(route_id)
            if target_r then
                cancel_all('ルートを切り替えたので、進行を取り消しました。', 158)
                settings.active_route = route_id
                config.save(settings)
                msg('==================================================')
                msg('連携ルート切り替え -> ルート ' .. route_id .. ': 【 ' .. (target_r.name or '') .. ' 】 に変更完了')
                msg('==================================================')
                if kusanagi_active() then msg(kusanagi_notice_text(), 158) end
            else
                msg('ルート ' .. sub .. ' はありません (あるのは ' .. route_ids_text() .. ')。切り替えません。', 123)
            end
        elseif sub == 'reload' then
            if load_sc_routes() then
                cancel_all('ルートを読み直したので、進行を取り消しました。', 158)
                msg('sc_routes.json を再読み込みしました。(Step 1リセット)', 209)
                if not get_active_route() then notify_missing_route() end
            else
                msg('sc_routes.json の読み込みに失敗しました。', 123)
            end
        elseif sub == 'fix' then
            if fix_routes(args[3] and args[3]:lower() == 'confirm') then cancel_all(nil) end
        else
            msg('不明な route サブコマンドです: ' .. tostring(sub) .. ' (show / 番号 / reload / fix)', 123)
        end
        return
    elseif cmd == 'toggle' then
        settings.enabled = not settings.enabled
        config.save(settings)
        if not settings.enabled then cancel_all('全体機能を OFF にしたので、予約と進行を取り消しました。', 158) end
        msg('全体機能: ' .. (settings.enabled and '【ON】' or '【OFF】'))
    elseif cmd == 'kusanagi' then
        local sub = args[2] and args[2]:lower()
        if sub == 'on' or sub == 'off' then
            settings.kusanagi = (sub == 'on')
            config.save(settings)
            if sub == 'off' and (st.mode == 'kusanagi' or st.mode == 'kus_am') then cancel_all('[草薙剣] 草薙剣モードを OFF にしたので、追うのをやめます', 158) end
            if sub == 'on' and (st.mode == 'custom' or st.mode == 'auto') and kusanagi_active() then
                cancel_all('草薙剣モードが有効になったので、ルートの進行を取り消しました。', 158)
            end
        end
        msg('草薙剣モード: ' .. (settings.kusanagi == true and '【ON】' or '【OFF】') .. ' (侍で草薙剣を装備中: 鳳蝶/轟天 → 無名を連携が続くかぎり。アフターマス無しなら無名で付ける)')
    elseif cmd == 'party' then
        settings.party_mode = not settings.party_mode
        config.save(settings)
        if not settings.party_mode then cancel_all('PT連携追撃を OFF にしたので、予約と進行を取り消しました。', 158) end
        msg('PT連携追撃: ' .. (settings.party_mode and '【ON】' or '【OFF】'))
    elseif cmd == 'solo' then
        settings.solo_mode = not settings.solo_mode
        config.save(settings)
        if not settings.solo_mode then cancel_all('一人連携追撃を OFF にしたので、予約と進行を取り消しました。', 158) end
        msg('一人連携追撃: ' .. (settings.solo_mode and '【ON】' or '【OFF】'))
    elseif cmd == 'delay' then
        local arg2 = args[2] and args[2]:lower()
        local sec = tonumber(arg2)
        if arg2 == 'off' then
            settings.delay_override = 0
            config.save(settings)
            msg('待機秒数の上書きをやめました。今の待機秒数: ' .. delay_text(get_active_route()))
        elseif sec and sec >= 1.0 and sec <= 8.0 then
            settings.delay_override = sec
            config.save(settings)
            msg('待機秒数: ' .. delay_text(get_active_route()) .. ' (すべてのルートで使います。戻すときは //sc delay off)')
        else
            msg('使用法: //sc delay <1.0~8.0> (すべてのルートの待機秒数を上書き) / //sc delay off (上書きをやめる)。今: ' .. delay_text(get_active_route()), 123)
        end
    elseif cmd == 'status' or cmd == 'show' then
        local active_r = get_active_route()
        msg('==================================================')
        msg('  [AutoSkillchain v' .. _addon.version .. '] 設定ステータス')
        msg('  ・集中攻撃: ' .. (settings.focus and 'ON' or 'OFF') .. '（味方PC2人以上・6秒経過でTP1500、早撃ちはTP2550）')
        msg('--------------------------------------------------')
        msg('  ・全体機能: ' .. (settings.enabled and 'ON' or 'OFF'))
        msg('  ・選択ルート: ルート ' .. tostring(settings.active_route) .. ' (' .. (active_r and active_r.name or 'ありません') .. ')')
        msg('  ・現在ステップ: Step ' .. st.step)
        msg('  ・PT連携追撃: ' .. (settings.party_mode and 'ON' or 'OFF'))
        msg('  ・一人連携追撃: ' .. (settings.solo_mode and 'ON' or 'OFF'))
        msg('  ・基本待機秒数: ' .. delay_text(active_r))
        msg('==================================================')
        if not active_r then notify_missing_route() end
        if kusanagi_active() then msg(kusanagi_notice_text(), 158) end
    elseif cmd == 'reload' then
        -- 読み込み直すと、通算の上限・PT の始点だけの連続時間・送った技の記録も消える (仕様)
        windower.send_command('lua r AutoSkillchain')
    else
        msg('==================================================')
        msg('  [AutoSkillchain v' .. _addon.version .. '] コマンドヘルプ')
        msg('  //sc focus on|off : 草薙剣を含め、集中攻撃を連携より優先')
        msg('--------------------------------------------------')
        msg('  //sc route <番号> : 連携ルートの切り替え (sc_routes.json にある番号)')
        msg('  //sc route        : 選択中のルートを表示')
        msg('  //sc route reload : sc_routes.jsonの再読み込み')
        msg('  //sc route fix    : 設定ファイルを既定に戻す (確認のあと、30 秒以内に //sc route fix confirm)')
        msg('  //sc stop         : 予約と進行を取り消して止める (別名 abort / off)')
        msg('  //sc start        : 止めたのを再開する (別名 on)')
        msg('  //sc reset        : 連携ステップの手動リセット (別名 clear / 予約も取り消す)')
        msg('  //sc toggle       : アドオン全体のON/OFF切り替え')
        msg('  //sc kusanagi [on|off] : 草薙剣モードの状態表示・ON/OFF（既定OFF）')
        msg('  //sc party        : PT連携追撃のON/OFF切り替え')
        msg('  //sc solo         : 一人連携追撃のON/OFF切り替え')
        msg('  //sc delay <秒>   : 待機秒数をすべてのルートで上書き (1.0~8.0秒)')
        msg('  //sc delay off    : 待機秒数の上書きをやめる (ルート → 基本設定の秒数に戻す)')
        msg('  //sc status       : 現在の設定状況を確認')
        msg('  //sc reload       : アドオンを再読み込み')
        msg('==================================================')
    end
end)

-- ゾーン移動・ログアウト・アンロード: 予約と進行 (草薙剣モードの TP 待ちを含む) を片付ける
-- (予約が残ると、ゾーン移動後の別の敵へ <t> で撃つため)
-- (送った技の記録と全自動の通算も消す)
local function clear_all_records()
    focus.target, focus.ready_at = nil, nil
    sent_log_clear()
    auto_total_clear()
    auto_party_clear()
end
windower.register_event('zone change', function()
    cancel_all('エリアを移動したので、予約と進行を取り消しました。', 158)
    clear_all_records()
end)
windower.register_event('logout', function() cancel_all(nil); clear_all_records() end)
windower.register_event('unload', function() cancel_all(nil); clear_all_records() end)
-- 交戦の解除・戦闘不能など (status が 1 = 戦闘 以外になった) / ジョブの変更でも取り消す
-- 交戦の解除は戦闘の終わり: PT の始点だけの連続時間も数え直す (全自動の回数と時間は cancel_all で戻る。通算は戻さない)
windower.register_event('status change', function(new_status)
    if new_status ~= 1 then
        focus.target = nil
        cancel_all('交戦状態でなくなったので、予約と進行を取り消しました。', 158)
        auto_party_clear()
    end
end)
windower.register_event('job change', function()
    focus.target = nil
    cancel_all('ジョブが変わったので、予約と進行を取り消しました。', 158)
end)

windower.register_event('load', function()
    if DEFAULT_ERR then msg('エラー: 内蔵の既定ルートを読めませんでした (' .. tostring(DEFAULT_ERR) .. ')。', 123) end
    load_sc_routes(true)
    if #settings_fixed > 0 then
        msg('設定の値が範囲の外だったので、既定に戻しました: ' .. table.concat(settings_fixed, ', '), 123)
    end
    msg('loaded v' .. _addon.version .. ' -- 侍自動連携追撃アドオン準備完了 (ルート' .. tostring(settings.active_route) .. '適用中・全体機能: '
        .. (settings.enabled and 'ON' or 'OFF') .. ')')
    -- //sc stop の OFF は保存されるので、読み込み直しても OFF のまま。止まっていることと戻し方を知らせる
    if not settings.enabled then msg('全体機能が OFF なので、連携を追いません。//sc start で再開します。', 158) end
    if not get_active_route() and #routes_data.routes > 0 then notify_missing_route() end
end)
