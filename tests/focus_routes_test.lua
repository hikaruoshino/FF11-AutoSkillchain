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
    resources = {weapon_skills={[156]={ja='祖之太刀・不動'}}, items={[1]={skill=10}}},
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
            get_abilities=function() return {weapon_skills={156}} end,
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
