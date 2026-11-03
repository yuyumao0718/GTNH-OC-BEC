local component = require('component')
local computer = require('computer')
local event = require('event')
local fs = require('filesystem')
local shell = require('shell')
local serialization = require('serialization')
local unicode = require('unicode')
local term = require('term')
local base = fs.path(assert(shell.resolve('bec_multi.lua')))
local function load(name)
    return dofile(base .. name .. '.lua')
end
local U, C, M = load('ma_util'), load('ma_config'), load('ma_materials')
local modules =
    { U = U, I = load('ma_intake'), N = load('ma_nanites'), M = M, Log = load('ma_logistics') }
local Core, Refill = load('ma_core'), load('ma_refill')
local Recovery = load('ma_recovery')
local store = load('ma_store').new(base, fs, serialization)
local args = { ... }
local command = args[1] or 'help'
if command ~= 'setup' and command ~= 'check' and command ~= 'run' and command ~= 'recover' then
    print('bec_multi.lua setup | check | run | recover')
    print('setup：打开配置；check：检查配置和设备；run：开始运行或续做。')
    print(
        'recover：接管没有续做记录的节点任务；必要时手动指定蜂群归还位置。'
    )
    print(
        'S：完成已接订单后配置；Q：完成后退出；Ctrl+C：立即暂停并保存进度，下次运行时续做。'
    )
    return
end
local gui
local function screen()
    if not gui then
        gui = load('ma_gui').new(component.gpu, event, unicode, C, M)
        gui.Editor = load('ma_editor')
    end
    return gui
end

local function compatible(cfg, state)
    return Recovery.check(cfg, state, U, component.proxy, M)
end

local function configure()
    local readable, cfg = pcall(function()
        return C.defaults(store.read('multi.setup') or store.read('multi.cfg'))
    end)
    if not readable then
        print('配置读取失败：' .. tostring(cfg))
        io.write('输入 new 重新填写配置，或直接回车返回（不覆盖原配置）：')
        if io.read() ~= 'new' then
            return false
        end
        cfg = C.defaults()
    end
    local result = screen():edit(cfg, component, {
        U = U,
        draft = function(value)
            store.write('multi.setup', value)
        end,
        write = function(value)
            local state = store.read('multi.state') or {}
            compatible(value, state)
            store.write('multi.cfg', value)
            if fs.exists(base .. 'multi.setup') then
                fs.remove(base .. 'multi.setup')
            end
        end,
    })
    if not result then
        store.write('multi.setup', cfg)
    end
    return result
end
if command == 'setup' then
    configure()
    term.clear()
    return
end
local engine
local ok, err = xpcall(function()
    repeat
        local cfg = C.defaults(assert(store.read('multi.cfg'), '请先运行 bec_multi.lua setup'))
        C.validate(cfg, component, U)
        local state = store.read('multi.state') or {}
        compatible(cfg, state)
        engine = Core.new(cfg, state, {
            proxy = component.proxy,
            time = computer.uptime,
            save = function(s)
                store.write('multi.state', s)
            end,
        }, modules)
        if command == 'check' then
            engine:check()
            Refill.new(engine)
            print(
                '检查通过：'
                    .. #engine.arrays
                    .. ' 台阵列，'
                    .. #cfg.generators
                    .. ' 台纠缠装置。'
            )
            return
        end
        if command == 'recover' then
            engine:pause()
            local held
            repeat
                held = true
                for _, a in ipairs(engine.arrays) do
                    if not engine:hold(a) then
                        held = false
                    end
                end
                if not held then
                    local ev = event.pull(0.05)
                    assert(ev ~= 'interrupted', '接管已取消，机器保持暂停')
                end
            until held
            Recovery.adopt(engine, function(a, tier, candidates)
                print(
                    '阵列 '
                        .. a.address
                        .. ' 已装载 T'
                        .. tier
                        .. ' 蜂群，请指定原来的空元件：'
                )
                for _, c in ipairs(candidates) do
                    print('箱子 ' .. c.box .. ' / 槽位 ' .. c.slot)
                end
                io.write('输入箱子编号和槽位，用空格分隔；直接回车取消：')
                local line = io.read()
                local box, slot = (line or ''):match('^%s*(%d+)%s+(%d+)%s*$')
                if box then
                    return { box = tonumber(box), slot = tonumber(slot), tier = tier }
                end
            end)
            command = 'run'
        end
        engine:start()
        state.wiring = U.copy(cfg)
        engine.save()
        local refill = Refill.new(engine)
        local lastDraw
        local lastSave = computer.uptime()
        local editing = false
        local stopping = false
        local function input(timeout)
            local ev = table.pack(event.pull(timeout))
            while ev[1] do
                local action = screen():runtimeEvent(table.unpack(ev, 1, ev.n))
                if action == 'interrupt' then
                    editing = false
                    return true
                elseif action == 'quit' or action == 'setup' then
                    if not stopping then
                        editing = action == 'setup'
                        stopping = true
                        engine:requestStop()
                        lastDraw = -math.huge
                    end
                elseif action == 'redraw' then
                    lastDraw = -math.huge
                end
                ev = table.pack(event.pull(0))
            end
            return false
        end
        screen():runtime(engine, refill)
        lastDraw = computer.uptime()
        local interrupted = screen():discardInput()
        while not interrupted do
            interrupted = input(0.05)
            if interrupted then
                break
            end
            local now = computer.uptime()
            if now - lastDraw >= 0.5 then
                screen():runtime(engine, refill)
                lastDraw = now
            end
            engine:tick()
            if engine.ready and engine.recovered then
                refill:tick()
            end
            now = computer.uptime()
            if now - lastSave >= 5 then
                engine.save()
                lastSave = now
            end
            if stopping and engine:drain() then
                local pending = false
                for _, s in pairs(state.refill.feeds) do
                    if s.loading then
                        pending = true
                    end
                end
                if not pending then
                    engine.save()
                    break
                end
            end
        end
        if not editing then
            break
        end
        engine:pause()
        configure()
    until false
end, debug.traceback)
if engine and command ~= 'check' then
    engine:pause()
end
term.clear()
if not ok then
    io.stderr:write(M.text(err) .. '\n')
elseif command == 'run' then
    print('已停止。再次运行 bec_multi.lua run 可继续接单或恢复未完成配方。')
end
