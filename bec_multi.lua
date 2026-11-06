local component = require('component')
local computer = require('computer')
local event = require('event')
local fs = require('filesystem')
local shell = require('shell')
local serialization = require('serialization')
local unicode = require('unicode')
local term = require('term')
local pendingInput = {}
local function pull(timeout)
    if #pendingInput > 0 then
        local ev = table.remove(pendingInput, 1)
        return table.unpack(ev, 1, ev.n)
    end
    return event.pull(timeout)
end
local lastYield = computer.realTime()
local base = fs.path(assert(shell.resolve('bec_multi.lua')))
local function load(name)
    return dofile(base .. name .. '.lua')
end
local U, C, M = load('ma_util'), load('ma_config'), load('ma_materials')
local modules =
    { U = U, I = load('ma_intake'), N = load('ma_nanites'), M = M, Log = load('ma_logistics') }
local Core, Refill = load('ma_core'), load('ma_refill')
local Recovery = load('ma_recovery')
local store = load('ma_store').new(base, fs, serialization, function()
    if computer.realTime() - lastYield >= 0.05 then
        -- Finish the snapshot before handling input or changing runtime state.
        local ev = table.pack(event.pull(0))
        if ev[1] then
            pendingInput[#pendingInput + 1] = ev
        end
        lastYield = computer.realTime()
    end
end)
local args = { ... }
local command = args[1] or 'help'
if command ~= 'setup' and command ~= 'check' and command ~= 'run' and command ~= 'recover' then
    print('bec_multi.lua setup | check | run | recover')
    print('setup：打开配置；check：检查配置和设备；run：开始运行或续做。')
    print('recover：与 run 相同，扫描机器并接管节点任务。')
    print(
        'S：完成已接订单后配置；Q：完成后退出；Ctrl+C：暂停；下次运行时从机器现场续做。'
    )
    return
end
local gui, engine
local function screen()
    if not gui then
        gui = load('ma_gui').new(component.gpu, { pull = pull }, unicode, C, M)
        gui.Editor = load('ma_editor')
    end
    return gui
end

local function compatible(cfg, state)
    return Recovery.check(cfg, state, U, component.proxy)
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
        clearRecipes = function()
            Recovery.idle(store.read('multi.cfg') or cfg, component.proxy)
            return store.clearRecipes()
        end,
        draft = function(value)
            store.write('multi.setup', value)
        end,
        write = function(value)
            compatible(value, store.read('multi.cfg'))
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
local ok, err = xpcall(function()
    repeat
        local cfg = C.defaults(assert(store.read('multi.cfg'), '请先运行 bec_multi.lua setup'))
        C.validate(cfg, component, U)
        local state = store.read('multi.state') or {}
        engine = Core.new(cfg, state, {
            proxy = component.proxy,
            time = computer.uptime,
            save = function(s)
                store.write('multi.state', s)
            end,
        }, modules)
        if command == 'check' then
            engine:check()
            if not engine:scanBees() then
                print(
                    '检查尚未完成：蜂群元件仍在 ME-IO 端口中，归位后可再次检查。'
                )
                return
            end
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
        command = 'run'
        engine:start()
        local refill = Refill.new(engine)
        local lastDraw
        local editing = false
        local stopping = false
        local interrupted = false
        local function input(timeout)
            local ev = table.pack(pull(timeout))
            while ev[1] do
                engine:event(ev[1], ev[2])
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
                ev = table.pack(pull(0))
            end
            return false
        end
        local function draw()
            local now = computer.realTime()
            if now - lastDraw >= 1 then
                screen():runtime(engine, refill)
                lastDraw = now
            end
        end
        screen():runtime(engine, refill)
        lastDraw = computer.realTime()
        interrupted = screen():discardInput()
        engine.io.pulse = function()
            interrupted = interrupted or input(0)
            if not interrupted then
                draw()
            end
            return interrupted
        end
        while not interrupted do
            interrupted = input(0.05)
            if interrupted then
                break
            end
            draw()
            engine:tick()
            if interrupted then
                break
            end
            if engine.ready and engine.recovered then
                refill:tick()
            end
            if stopping and engine:drain() then
                local pending = false
                for _, s in pairs(state.refill.feeds) do
                    if s.loading then
                        pending = true
                    end
                end
                if not pending then
                    break
                end
            end
        end
        if not editing then
            break
        end
        engine:pause()
        engine = nil
        configure()
    until false
end, debug.traceback)
local paused, pauseErr = true
if engine and command ~= 'check' then
    paused, pauseErr = pcall(engine.pause, engine)
end
term.clear()
if not ok then
    io.stderr:write(M.text(err) .. '\n')
end
if not paused then
    io.stderr:write('暂停或保存失败：' .. M.text(pauseErr) .. '\n')
elseif ok and command == 'run' then
    print('已停止。再次运行 bec_multi.lua run 可继续接单或恢复未完成配方。')
end
