-- AutoSkillchain の小さな JSON リーダー (読むだけ)
--   local sc_json = require('libs/sc_json')
--   local value, err = sc_json.decode(str)   -- 失敗したら nil と エラー文 (行番号付き)。例外は外に出さない
-- 読めるもの: オブジェクト・配列・文字列 (\" \\ \/ \b \f \n \r \t \uXXXX)・数・true / false / null
--   null はオブジェクトの値のときだけ認め、その項目は無いものとする。配列の中・最上位の null はエラー
--   入力は 256KB まで。inf / NaN になる数はエラー
-- JSON より寛容にするのは次の 3 つだけ: 文字列の外の // 行コメント・} ] の前の余分なカンマ・先頭の BOM
-- 字句を読みながら処理し、文字列の中身は書き換えない。入れ子は 32 段まで。返すのは素の表 (メタテーブル無し)

local M = {}

local MAX_DEPTH = 32
local MAX_BYTES = 256 * 1024

local byte, sub, find, char, floor = string.byte, string.sub, string.find, string.char, math.floor
local concat = table.concat
local tonumber, tostring, error, pcall, type, setmetatable, getmetatable = tonumber, tostring, error, pcall, type, setmetatable, getmetatable

local B_QUOTE, B_BSLASH, B_SLASH = 34, 92, 47
local B_LBRACE, B_RBRACE, B_LBRACK, B_RBRACK = 123, 125, 91, 93
local B_COMMA, B_COLON = 44, 58

local ESCAPES = {[34] = '"', [92] = '\\', [47] = '/', [98] = '\b', [102] = '\f', [110] = '\n', [114] = '\r', [116] = '\t'}

-- 内部のエラー (pos の位置で失敗) を表す印
local Fail = {}
Fail.__index = Fail

local function line_of(s, pos)
    local line = 1
    local i = 1
    while true do
        local nl = find(s, '\n', i, true)
        if not nl or nl >= pos then break end
        line = line + 1
        i = nl + 1
    end
    return line
end

local function utf8_char(cp)
    if cp < 0x80 then return char(cp) end
    if cp < 0x800 then return char(0xC0 + floor(cp / 0x40), 0x80 + cp % 0x40) end
    if cp < 0x10000 then
        return char(0xE0 + floor(cp / 0x1000), 0x80 + floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
    end
    return char(0xF0 + floor(cp / 0x40000), 0x80 + floor(cp / 0x1000) % 0x40, 0x80 + floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
end

local function decode_inner(s)
    local len = #s
    local pos = 1

    local function fail(msg, at)
        error(setmetatable({msg = msg, pos = at or pos}, Fail), 0)
    end

    -- 空白と // 行コメントを飛ばす
    local function skip()
        while true do
            local _, e = find(s, '^[ \t\r\n]+', pos)
            if e then pos = e + 1 end
            if byte(s, pos) == B_SLASH then
                if byte(s, pos + 1) ~= B_SLASH then fail('「/」が 1 つだけあります (コメントは // で始めてください)') end
                local nl = find(s, '\n', pos, true)
                pos = nl and (nl + 1) or (len + 1)
            else
                return
            end
        end
    end

    local parse_value

    local function parse_string()
        -- pos は開きの " を指している
        local start = pos
        local i = pos + 1
        local parts, n = nil, 0
        while true do
            local j = find(s, '[%z\1-\31"\\]', i)
            if not j then fail('文字列が閉じていません', start) end
            local c = byte(s, j)
            if c == B_QUOTE then
                local tail = sub(s, i, j - 1)
                pos = j + 1
                if not parts then return tail end
                n = n + 1; parts[n] = tail
                return concat(parts, '', 1, n)
            elseif c == B_BSLASH then
                parts = parts or {}
                n = n + 1; parts[n] = sub(s, i, j - 1)
                local e = byte(s, j + 1)
                local simple = e and ESCAPES[e]
                if simple then
                    n = n + 1; parts[n] = simple
                    i = j + 2
                elseif e == 117 then   -- \uXXXX
                    local hex = sub(s, j + 2, j + 5)
                    if not find(hex, '^%x%x%x%x$') then fail('\\u のあとに 16 進の 4 桁がありません', j) end
                    local cp = tonumber(hex, 16)
                    i = j + 6
                    if cp >= 0xD800 and cp <= 0xDBFF then   -- サロゲートペア
                        local hex2 = find(s, '^\\u%x%x%x%x', i) and sub(s, i + 2, i + 5)
                        local lo = hex2 and tonumber(hex2, 16)
                        if lo and lo >= 0xDC00 and lo <= 0xDFFF then
                            cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
                            i = i + 6
                        end
                    end
                    n = n + 1; parts[n] = utf8_char(cp)
                else
                    fail('文字列の中に使えない \\ の書き方があります', j)
                end
            else
                if c == 10 then fail('文字列が閉じていません (行の終わりまでに " がありません)', start) end
                fail('文字列の中に制御文字があります', j)
            end
        end
    end

    local function parse_number()
        local _, e = find(s, '^-?%d+', pos)
        if not e then fail('値が読めません') end
        if find(s, '^-?0%d', pos) then fail('数の先頭に 0 は付けられません') end
        local _, e2 = find(s, '^%.%d+', e + 1)
        if e2 then e = e2 end
        local _, e3 = find(s, '^[eE][-+]?%d+', e + 1)
        if e3 then e = e3 end
        local v = tonumber(sub(s, pos, e))
        if not v then fail('数が読めません') end
        if v ~= v or v == math.huge or v == -math.huge then fail('数が大きすぎます') end
        pos = e + 1
        return v
    end

    local function parse_object(depth)
        pos = pos + 1
        local obj = {}
        skip()
        if byte(s, pos) == B_RBRACE then pos = pos + 1; return obj end
        while true do
            if byte(s, pos) ~= B_QUOTE then fail('項目の名前 ("…") がありません') end
            local key = parse_string()
            skip()
            if byte(s, pos) ~= B_COLON then fail('項目の名前のあとに「:」がありません') end
            pos = pos + 1
            skip()
            obj[key] = parse_value(depth)
            skip()
            local c = byte(s, pos)
            if c == B_COMMA then
                pos = pos + 1
                skip()
                if byte(s, pos) == B_RBRACE then pos = pos + 1; return obj end   -- 余分なカンマ
            elseif c == B_RBRACE then
                pos = pos + 1
                return obj
            elseif not c then
                fail('「}」で閉じていません')
            else
                fail('「,」か「}」がありません')
            end
        end
    end

    local function parse_array(depth)
        pos = pos + 1
        local arr, n = {}, 0
        skip()
        if byte(s, pos) == B_RBRACK then pos = pos + 1; return arr end
        while true do
            n = n + 1
            local at = pos
            local v = parse_value(depth)
            if v == nil then fail('配列の中に null は使えません', at) end
            arr[n] = v
            skip()
            local c = byte(s, pos)
            if c == B_COMMA then
                pos = pos + 1
                skip()
                if byte(s, pos) == B_RBRACK then pos = pos + 1; return arr end   -- 余分なカンマ
            elseif c == B_RBRACK then
                pos = pos + 1
                return arr
            elseif not c then
                fail('「]」で閉じていません')
            else
                fail('「,」か「]」がありません')
            end
        end
    end

    parse_value = function(depth)
        local c = byte(s, pos)
        if c == B_LBRACE or c == B_LBRACK then
            if depth >= MAX_DEPTH then fail('入れ子が深すぎます (' .. MAX_DEPTH .. ' 段まで)') end
            if c == B_LBRACE then return parse_object(depth + 1) end
            return parse_array(depth + 1)
        elseif c == B_QUOTE then
            return parse_string()
        elseif c == 116 and sub(s, pos, pos + 3) == 'true' then
            pos = pos + 4; return true
        elseif c == 102 and sub(s, pos, pos + 4) == 'false' then
            pos = pos + 5; return false
        elseif c == 110 and sub(s, pos, pos + 3) == 'null' then
            pos = pos + 4; return nil
        elseif c == 45 or (c and c >= 48 and c <= 57) then
            return parse_number()
        elseif not c then
            fail('値がありません')
        end
        fail('値が読めません')
    end

    if sub(s, 1, 3) == '\239\187\191' then pos = 4 end   -- 先頭の BOM
    skip()
    if pos > len then fail('空のデータです') end
    local at = pos
    local value = parse_value(0)
    skip()
    if pos <= len then fail('値のあとに余分な文字があります') end
    if value == nil then fail('最上位が null です', at) end
    return value
end

function M.decode(str)
    if type(str) ~= 'string' then return nil, 'JSON の文字列ではありません' end
    if str == '' then return nil, '空のデータです' end
    if #str > MAX_BYTES then return nil, 'データが大きすぎます (' .. MAX_BYTES .. ' バイトまで)' end
    local ok, v = pcall(decode_inner, str)
    if ok then return v, nil end
    if getmetatable(v) == Fail then
        return nil, '行 ' .. line_of(str, v.pos) .. ': ' .. v.msg
    end
    return nil, 'JSON の読み込みで予期しないエラー: ' .. tostring(v)
end

return M
