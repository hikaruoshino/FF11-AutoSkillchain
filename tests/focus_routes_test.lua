-- 公開版のルートディレクトリで lua5.1 tests/focus_routes_test.lua を実行する。
local events, sent = {}, {}
local now, scheduled = 10, nil
local contents = '{'
local target = {id=500, index=8, spawn_type=16, hpp=100, distance=1}
local player = {id=1, main_job='SAM', status=1, buffs={}, vitals={tp=3000}}
local party = {p1={mob={id=2, is_npc=false, target_index=8}},
               a10={mob={id=3, is_npc=false, target_index=8}}}
local modules = {
    config = {load=function(defaults) return defaults end, save=function() end},
    resources = {weapon_skills={[156]={ja='祖之太刀・不動'}, [159]={ja='絶之太刀・無名'}}, items={[1]={en='Kusanagi',skill=10}}},
    files = {new=function()
        return {exists=function() return true end, read=function() return contents end}
    end},
    packets = {},
    ['libs/sc_json'] = dofile('libs/sc_json.lua'),
}
local env = setmetatable({
    _addon = {},
    os = {clock=function() return now end},
    require = function(name) return assert(modules[name], name) end,
    coroutine = {
        schedule=function(fn) scheduled = coroutine.create(fn) end,
        sleep=coroutine.yield,
    },
    windower = {
        register_event=function(name, fn) events[name] = fn end,
        add_to_chat=function() end,
        to_shift_jis=function(s) return s end,
        send_command=function(cmd) sent[#sent+1] = cmd end,
        ffxi={
            get_player=function() return player end,
            get_mob_by_target=function() return target end,
            get_party=function() return party end,
            get_abilities=function() return {weapon_skills={156,159}} end,
            get_items=function(bag)
                if bag == 'equipment' then return {main=1, main_bag=0} end
                return {id=1}
            end,
        },
    },
}, {__index=_G})
setfenv(assert(loadfile('AutoSkillchain.lua')), env)()
local function frame()
    now = now + 0.3
    events.prerender()
    if scheduled then
        local task = scheduled
        scheduled = nil
        assert(coroutine.resume(task))
    end
end

events.load()
frame()
assert(#sent == 0, '起動時のJSON破損で集中攻撃を送った')
events['addon command']('route', 'reload')
frame()
assert(#sent == 0, '再読込も失敗したのに集中攻撃を送った')
contents = '{"routes":[{"id":2,"mode":"auto"}]}'
events['addon command']('route', 'reload')
frame()
assert(#sent == 0, '選択中のルートが存在しないのに集中攻撃を送った')
events['addon command']('route', '2')
frame()
assert(#sent == 1 and sent[1] == 'input /ws "祖之太刀・不動" <t>', 'ルート選択後に復旧しなかった')

sent, scheduled = {}, nil
contents = '{'
setfenv(assert(loadfile('AutoSkillchain.lua')), env)()
events.load()
contents = '{"routes":[{"id":1,"mode":"auto"}]}'
events['addon command']('route', 'reload')
frame()
assert(#sent == 1, '選択中のルートを再読込しても集中攻撃が復旧しなかった')
print('集中攻撃のルート読込失敗・再読込・選択による復旧を確認')

-- 保存済みの設定を引き継ぐ、通常の起動とコマンド操作を再現する。
local saved = {focus=true}
local current, refresh
modules.config.load = function(defaults)
    local merged = {}
    for key, value in pairs(defaults) do merged[key] = value end
    for key, value in pairs(saved) do merged[key] = value end
    current, refresh = merged, nil
    return current
end
modules.config.register = function(settings, fn)
    assert(settings == current)
    refresh = fn
end
modules.config.save = function(settings) saved.kusanagi = settings.kusanagi end
local function reload()
    sent, scheduled = {}, nil
    setfenv(assert(loadfile('AutoSkillchain.lua')), env)()
    events.load()
end
local command = function(value) events['addon command']('kusanagi', value) end
reload()
assert(current.kusanagi == false, '旧設定の草薙剣モードは既定OFF')
player.vitals.tp = 2550
frame()
assert(sent[1] == 'input /ws "祖之太刀・不動" <t>', 'OFFでは草薙剣も従来の不動')
command('on')
assert(saved.kusanagi == true, '明示ONを保存')
reload()
assert(current.kusanagi == true, '再起動でONを復元')
player.vitals.tp = 2999
frame()
assert(#sent == 0, 'AMなしでTP2999では無名を送らない')
player.vitals.tp = 3000
frame()
assert(sent[1] == 'input /ws "絶之太刀・無名" <t>', 'AMなしでTP3000なら無名')
contents = '{'
reload()
frame()
assert(#sent == 0, '草薙剣ONでもルート破損時は送らない')
contents = '{"routes":[{"id":1,"mode":"auto"}]}'
events['addon command']('route', 'reload')
command('off')
assert(saved.kusanagi == false, '明示OFFを保存')
reload()
frame()
assert(sent[1] == 'input /ws "祖之太刀・不動" <t>', 'OFFを復元して不動に戻る')
saved = {}
reload()
assert(current.kusanagi == false, '初回はOFF')
print('草薙剣の初期値・保存と再起動・集中攻撃の技とTP境界を確認')

-- config.reload は load/login/logout で同じ設定表を更新し、登録済み関数を呼ぶ。
modules.resources.weapon_skills[155] = {ja='十一之太刀・鳳蝶'}
saved = {focus=false, kusanagi=true}
reload()
local function refresh_settings(event, delay)
    current.kusanagi_tp, current.kusanagi_delay = 1000, delay
    if refresh then refresh(current) end
    if events[event] then events[event]() end
end
local opener = {category=3, actor_id=1, param=155,
    targets={{id=target.id, actions={{message=185}}}}}
local function resume_at(task, timestamp)
    now = timestamp
    assert(coroutine.resume(task))
end
local failures = {}
local function check(ok, message)
    if not ok then failures[#failures+1] = message end
end
for _, case in ipairs({
    {'load', 0.99, 5}, {'login', 1, 1}, {'logout', 8, 8},
    {'login', 8.01, 5}, {'login', '不正', 5},
}) do
    reload()
    player.vitals.tp = 3000
    refresh_settings(case[1], case[2])
    check(current.kusanagi_delay == case[3], case[1] .. ' 遅延 ' .. tostring(case[2]))
    events.action(opener)
    local task, start = assert(scheduled), now
    resume_at(task, start + case[3] - 0.01)
    check(#sent == 0, '指定した遅延より早く無名を送った')
    resume_at(task, start + case[3])
    check(sent[1] == 'input /ws "絶之太刀・無名" <t>', '指定した遅延で無名を送らなかった')
end
reload()
refresh_settings('login', 1)
events.action(opener)
local task, start = assert(scheduled), now
player.vitals.tp = 2999
resume_at(task, start + 1)
check(#sent == 0, '通常連携のAM付与がTP2999で送信された')
player.vitals.tp = 3000
resume_at(task, start + 1.5)
check(#sent == 1 and sent[1] == 'input /ws "絶之太刀・無名" <t>',
    '通常連携のAM付与がTP3000で1回送信されない')
assert(#failures == 0, table.concat(failures, ' / '))
print('設定自動再読込後の遅延境界・通常連携のAM付与TPを確認')
