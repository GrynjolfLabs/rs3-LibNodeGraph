local luaunit = require("luaunit")
local Registry = require("registry")
local Graph = require("graph")

TestGraph = {}

function TestGraph:setUp()
    self.registry = Registry.new()
    self.pureRunCount = 0
    self.counterRunCount = 0
    self.counterValue = 0
    self.actionLog = {}

    self.registry:RegisterNodeType("fixture.trigger", {
        category = "trigger",
        pins = { { name = "out", kind = "exec", direction = "out" } },
        run = function(ctx) ctx:Fire("out") end,
    })

    self.registry:RegisterNodeType("fixture.trigger2", {
        category = "trigger",
        pins = { { name = "out", kind = "exec", direction = "out" } },
        run = function(ctx) ctx:Fire("out") end,
    })

    self.registry:RegisterNodeType("fixture.add", {
        category = "pure",
        pins = {
            { name = "a", kind = "data", direction = "in", dataType = "number", default = 0 },
            { name = "b", kind = "data", direction = "in", dataType = "number", default = 0 },
            { name = "sum", kind = "data", direction = "out", dataType = "number" },
        },
        run = function(ctx)
            self.pureRunCount = self.pureRunCount + 1
            ctx:Out("sum", ctx:In("a") + ctx:In("b"))
        end,
    })

    self.registry:RegisterNodeType("fixture.passthrough", {
        category = "pure",
        pins = {
            { name = "in", kind = "data", direction = "in", dataType = "any", default = 0 },
            { name = "out", kind = "data", direction = "out", dataType = "any" },
        },
        run = function(ctx)
            ctx:Out("out", ctx:In("in"))
        end,
    })

    self.registry:RegisterNodeType("fixture.coord", {
        category = "pure",
        pins = {
            { name = "pos", kind = "data", direction = "in", dataType = "coord", default = { x = 0, y = 0 } },
        },
        run = function() end,
    })

    self.registry:RegisterNodeType("fixture.action", {
        category = "action",
        pins = {
            { name = "in", kind = "exec", direction = "in", terminates = true },
            { name = "value", kind = "data", direction = "in", dataType = "number", default = 0 },
        },
        run = function(ctx)
            table.insert(self.actionLog, { kind = "action", value = ctx:In("value") })
        end,
    })

    self.registry:RegisterNodeType("fixture.action2", {
        category = "action",
        pins = { { name = "in", kind = "exec", direction = "in", terminates = true } },
        run = function()
            table.insert(self.actionLog, { kind = "action2" })
        end,
    })

    -- step (non-terminator) -> out; reset (terminator) does nothing but demonstrates
    -- that a wire looping back into it is legal (docs/adr/0004, rule 4).
    self.registry:RegisterNodeType("fixture.counter", {
        category = "stateful",
        pins = {
            { name = "step", kind = "exec", direction = "in" },
            { name = "reset", kind = "exec", direction = "in", terminates = true },
            { name = "out", kind = "exec", direction = "out" },
            { name = "count", kind = "data", direction = "out", dataType = "number" },
        },
        run = function(ctx)
            self.counterRunCount = self.counterRunCount + 1
            self.counterValue = self.counterValue + 1
            ctx:Out("count", self.counterValue)
            ctx:Fire("out")
        end,
    })

    -- A Trigger that republishes its injected payload onto a Data output (docs/adr/0009).
    self.registry:RegisterNodeType("fixture.echo", {
        category = "trigger",
        pins = {
            { name = "out", kind = "exec", direction = "out" },
            { name = "msg", kind = "data", direction = "out", dataType = "any" },
        },
        run = function(ctx)
            ctx:Out("msg", ctx.payload)
            ctx:Fire("out")
        end,
    })

    -- Records what ctx exposed when it ran, to assert payload/exec scoping downstream.
    self.probeLog = {}
    self.registry:RegisterNodeType("fixture.probe", {
        category = "action",
        pins = {
            { name = "in", kind = "exec", direction = "in", terminates = true },
            { name = "value", kind = "data", direction = "in", dataType = "any", default = nil },
        },
        run = function(ctx)
            table.insert(self.probeLog, {
                payload = ctx.payload,
                exec = ctx.exec,
                value = ctx:In("value"),
            })
        end,
    })

    -- Two exec inputs (one a Terminator) recording ctx.exec to prove input identity.
    self.entryLog = {}
    self.registry:RegisterNodeType("fixture.twoin", {
        category = "stateful",
        pins = {
            { name = "a", kind = "exec", direction = "in" },
            { name = "b", kind = "exec", direction = "in", terminates = true },
            { name = "out", kind = "exec", direction = "out" },
        },
        run = function(ctx)
            -- wrapped in a table so a nil ctx.exec still records an entry
            table.insert(self.entryLog, { exec = ctx.exec })
            if ctx.exec == "a" then
                ctx:Fire("out")
            end
        end,
    })

    -- Uses ctx.state to count its own runs across Fires (docs/adr/0010).
    self.registry:RegisterNodeType("fixture.statecounter", {
        category = "stateful",
        pins = {
            { name = "in", kind = "exec", direction = "in" },
            { name = "out", kind = "exec", direction = "out" },
            { name = "n", kind = "data", direction = "out", dataType = "number" },
        },
        run = function(ctx)
            ctx.state.n = (ctx.state.n or 0) + 1
            ctx:Out("n", ctx.state.n)
            ctx:Fire("out")
        end,
    })

    self.graph = Graph.new(self.registry)
end

--- AddNode / controls -------------------------------------------------------------

function TestGraph:testAddNodeSeedsControlsFromDefaults()
    local id = self.graph:AddNode("fixture.add")
    luaunit.assertEquals(self.graph:GetControl(id, "a"), 0)
    luaunit.assertEquals(self.graph:GetControl(id, "b"), 0)
end

function TestGraph:testAddNodeOverridesDefaultsWithProvidedControls()
    local id = self.graph:AddNode("fixture.add", { a = 10, b = 20 })
    luaunit.assertEquals(self.graph:GetControl(id, "a"), 10)
    luaunit.assertEquals(self.graph:GetControl(id, "b"), 20)
end

function TestGraph:testAddNodeCopiesTableDefaultsPerInstance()
    local id1 = self.graph:AddNode("fixture.coord")
    local id2 = self.graph:AddNode("fixture.coord")

    local pos1 = self.graph:GetControl(id1, "pos")
    pos1.x = 99

    local pos2 = self.graph:GetControl(id2, "pos")
    luaunit.assertEquals(pos2.x, 0)
end

function TestGraph:testRemoveNodeCascadesConnections()
    local triggerId = self.graph:AddNode("fixture.trigger")
    local actionId = self.graph:AddNode("fixture.action")
    self.graph:Connect(triggerId, "out", actionId, "in")

    self.graph:RemoveNode(actionId)

    luaunit.assertEquals(#self.graph:GetConnections(), 0)
    local ids = {}
    for _, node in ipairs(self.graph:GetNodes()) do
        ids[node.id] = true
    end
    luaunit.assertIsNil(ids[actionId])
end

--- Connect validation ---------------------------------------------------------------

function TestGraph:testConnectRejectsUnknownPin()
    local triggerId = self.graph:AddNode("fixture.trigger")
    local actionId = self.graph:AddNode("fixture.action")
    local id, reason = self.graph:Connect(triggerId, "nope", actionId, "in")
    luaunit.assertIsNil(id)
    luaunit.assertEquals(reason, "unknown_pin")
end

function TestGraph:testConnectRejectsExecToDataKindMismatch()
    local triggerId = self.graph:AddNode("fixture.trigger")
    local addId = self.graph:AddNode("fixture.add")
    local id, reason = self.graph:Connect(triggerId, "out", addId, "a")
    luaunit.assertIsNil(id)
    luaunit.assertEquals(reason, "kind_mismatch")
end

function TestGraph:testConnectRejectsFromInputPin()
    local addId = self.graph:AddNode("fixture.add")
    local action = self.graph:AddNode("fixture.action")
    local id, reason = self.graph:Connect(addId, "a", action, "value")
    luaunit.assertIsNil(id)
    luaunit.assertEquals(reason, "not_output")
end

function TestGraph:testConnectRejectsToOutputPin()
    local addId = self.graph:AddNode("fixture.add")
    local add2Id = self.graph:AddNode("fixture.add")
    local id, reason = self.graph:Connect(addId, "sum", add2Id, "sum")
    luaunit.assertIsNil(id)
    luaunit.assertEquals(reason, "not_input")
end

function TestGraph:testConnectRejectsDataTypeMismatch()
    local addId = self.graph:AddNode("fixture.add")
    local coordId = self.graph:AddNode("fixture.coord")
    local id, reason = self.graph:Connect(addId, "sum", coordId, "pos")
    luaunit.assertIsNil(id)
    luaunit.assertEquals(reason, "type_mismatch")
end

function TestGraph:testConnectAllowsAnyWildcard()
    local addId = self.graph:AddNode("fixture.add")
    local passId = self.graph:AddNode("fixture.passthrough")
    -- should not raise: "any" accepts any concrete tag
    self.graph:Connect(addId, "sum", passId, "in")
end

function TestGraph:testConnectRejectsSecondConnectionToSameDataInput()
    local addId = self.graph:AddNode("fixture.add")
    local add2Id = self.graph:AddNode("fixture.add")
    local actionId = self.graph:AddNode("fixture.action")

    self.graph:Connect(addId, "sum", actionId, "value")
    local id, reason = self.graph:Connect(add2Id, "sum", actionId, "value")
    luaunit.assertIsNil(id)
    luaunit.assertEquals(reason, "data_input_occupied")
end

function TestGraph:testConnectRejectsExactDuplicateEdge()
    local triggerId = self.graph:AddNode("fixture.trigger")
    local actionId = self.graph:AddNode("fixture.action")

    self.graph:Connect(triggerId, "out", actionId, "in")
    local id, reason = self.graph:Connect(triggerId, "out", actionId, "in")
    luaunit.assertIsNil(id)
    luaunit.assertEquals(reason, "duplicate")
    -- the graph never holds two identical edges
    luaunit.assertEquals(#self.graph:GetConnections(), 1)
end

function TestGraph:testFindConnectionMatchesExactTupleOnly()
    local triggerId = self.graph:AddNode("fixture.trigger")
    local actionId = self.graph:AddNode("fixture.action")
    local action2Id = self.graph:AddNode("fixture.action2")
    self.graph:Connect(triggerId, "out", actionId, "in")

    luaunit.assertNotIsNil(self.graph:FindConnection(triggerId, "out", actionId, "in"))
    luaunit.assertIsNil(self.graph:FindConnection(triggerId, "out", action2Id, "in"))
end

function TestGraph:testConnectAllowsMultipleConnectionsIntoSameExecInput()
    local trigger1 = self.graph:AddNode("fixture.trigger")
    local trigger2 = self.graph:AddNode("fixture.trigger2")
    local actionId = self.graph:AddNode("fixture.action")

    self.graph:Connect(trigger1, "out", actionId, "in")
    self.graph:Connect(trigger2, "out", actionId, "in")
    luaunit.assertEquals(#self.graph:GetConnections(), 2)
end

function TestGraph:testConnectAllowsFanOutFromSameExecOutput()
    local triggerId = self.graph:AddNode("fixture.trigger")
    local actionId = self.graph:AddNode("fixture.action")
    local action2Id = self.graph:AddNode("fixture.action2")

    self.graph:Connect(triggerId, "out", actionId, "in")
    self.graph:Connect(triggerId, "out", action2Id, "in")
    luaunit.assertEquals(#self.graph:GetConnections(), 2)
end

--- Cycle detection (docs/adr/0004, rule 4) ------------------------------------------

function TestGraph:testConnectRejectsDirectDataSelfLoop()
    local addId = self.graph:AddNode("fixture.add")
    local id, reason = self.graph:Connect(addId, "sum", addId, "a")
    luaunit.assertIsNil(id)
    luaunit.assertEquals(reason, "cycle")
end

function TestGraph:testConnectRejectsExecCycleBetweenTwoNodes()
    local counterA = self.graph:AddNode("fixture.counter")
    local counterB = self.graph:AddNode("fixture.counter")

    self.graph:Connect(counterA, "out", counterB, "step")
    local id, reason = self.graph:Connect(counterB, "out", counterA, "step")
    luaunit.assertIsNil(id)
    luaunit.assertEquals(reason, "cycle")
end

function TestGraph:testConnectAllowsLoopIntoTerminator()
    local counterId = self.graph:AddNode("fixture.counter")
    -- a Terminator input contributes no intra-node edges, so looping into it is legal
    self.graph:Connect(counterId, "out", counterId, "reset")
end

--- SetControl / GetControl -----------------------------------------------------------

function TestGraph:testSetControlUpdatesValue()
    local addId = self.graph:AddNode("fixture.add")
    self.graph:SetControl(addId, "a", 42)
    luaunit.assertEquals(self.graph:GetControl(addId, "a"), 42)
end

function TestGraph:testSetControlRejectsUnknownPin()
    local addId = self.graph:AddNode("fixture.add")
    luaunit.assertError(function()
        self.graph:SetControl(addId, "nope", 1)
    end)
end

function TestGraph:testSetControlRejectsExecPin()
    local counterId = self.graph:AddNode("fixture.counter")
    luaunit.assertErrorMsgContains("not a data input pin", function()
        self.graph:SetControl(counterId, "step", 1)
    end)
end

function TestGraph:testSetControlRejectsDataOutputPin()
    local addId = self.graph:AddNode("fixture.add")
    luaunit.assertErrorMsgContains("not a data input pin", function()
        self.graph:SetControl(addId, "sum", 1)
    end)
end

function TestGraph:testGetControlUnknownNodeReturnsNil()
    luaunit.assertIsNil(self.graph:GetControl(999, "a"))
end

--- Execution semantics (docs/adr/0003, docs/adr/0004) -------------------------------

function TestGraph:testFireRunsActionOnce()
    local triggerId = self.graph:AddNode("fixture.trigger")
    local actionId = self.graph:AddNode("fixture.action")
    self.graph:Connect(triggerId, "out", actionId, "in")

    self.graph:Fire(triggerId)

    luaunit.assertEquals(#self.actionLog, 1)
    luaunit.assertEquals(self.actionLog[1].value, 0)
end

function TestGraph:testFirePerArrivalRunsNodeOncePerIncomingSignal()
    -- Two arrivals into one exec input via two DISTINCT sources (identical wires are now
    -- rejected as duplicates): a trigger fans out to two counters, each of which fires into
    -- the same action input -> the action runs once per arrival.
    local triggerId = self.graph:AddNode("fixture.trigger")
    local counterA = self.graph:AddNode("fixture.counter")
    local counterB = self.graph:AddNode("fixture.counter")
    local actionId = self.graph:AddNode("fixture.action")

    self.graph:Connect(triggerId, "out", counterA, "step")
    self.graph:Connect(triggerId, "out", counterB, "step")
    self.graph:Connect(counterA, "out", actionId, "in")
    self.graph:Connect(counterB, "out", actionId, "in")

    self.graph:Fire(triggerId)

    luaunit.assertEquals(#self.actionLog, 2)
end

function TestGraph:testFireFanOutRunsAllConnectedActionsUnordered()
    local triggerId = self.graph:AddNode("fixture.trigger")
    local actionId = self.graph:AddNode("fixture.action")
    local action2Id = self.graph:AddNode("fixture.action2")

    self.graph:Connect(triggerId, "out", actionId, "in")
    self.graph:Connect(triggerId, "out", action2Id, "in")

    self.graph:Fire(triggerId)

    luaunit.assertEquals(#self.actionLog, 2)
    local kinds = {}
    for _, entry in ipairs(self.actionLog) do
        kinds[entry.kind] = true
    end
    luaunit.assertIsTrue(kinds["action"])
    luaunit.assertIsTrue(kinds["action2"])
end

function TestGraph:testPullReEvaluatesPureNodeOnEveryConsumer()
    local triggerId = self.graph:AddNode("fixture.trigger")
    local addId = self.graph:AddNode("fixture.add", { a = 2, b = 3 })
    local action1 = self.graph:AddNode("fixture.action")
    local action2 = self.graph:AddNode("fixture.action")

    self.graph:Connect(triggerId, "out", action1, "in")
    self.graph:Connect(triggerId, "out", action2, "in")
    self.graph:Connect(addId, "sum", action1, "value")
    self.graph:Connect(addId, "sum", action2, "value")

    self.graph:Fire(triggerId)

    -- no memoization: the Pure Node re-runs once per pull (docs/adr/0004, rule 3)
    luaunit.assertEquals(self.pureRunCount, 2)
    luaunit.assertEquals(self.actionLog[1].value, 5)
    luaunit.assertEquals(self.actionLog[2].value, 5)
end

function TestGraph:testExecutionNodeOutputPersistsAcrossFiresWithoutExtraRuns()
    local triggerId = self.graph:AddNode("fixture.trigger")
    local counterId = self.graph:AddNode("fixture.counter")
    local actionId = self.graph:AddNode("fixture.action")

    self.graph:Connect(triggerId, "out", counterId, "step")
    self.graph:Connect(counterId, "out", actionId, "in")
    self.graph:Connect(counterId, "count", actionId, "value")

    self.graph:Fire(triggerId)
    luaunit.assertEquals(self.counterRunCount, 1)
    luaunit.assertEquals(self.actionLog[1].value, 1)

    self.graph:Fire(triggerId)
    luaunit.assertEquals(self.counterRunCount, 2)
    luaunit.assertEquals(self.actionLog[2].value, 2)

    -- pulling the stored value directly must not re-run the execution node
    luaunit.assertEquals(self.graph:GetLastValue(counterId, "count"), 2)
    luaunit.assertEquals(self.counterRunCount, 2)
end

function TestGraph:testPullBeforeExecutionNodeHasRunReturnsNil()
    local counterId = self.graph:AddNode("fixture.counter")
    local actionId = self.graph:AddNode("fixture.action")
    self.graph:Connect(counterId, "count", actionId, "value")

    -- Fire the action directly; the counter has never executed this Fire (or ever)
    self.graph:Fire(actionId)

    luaunit.assertIsNil(self.actionLog[1].value)
    luaunit.assertEquals(self.counterRunCount, 0)
end

--- Payload injection (docs/adr/0009) --------------------------------------------------

function TestGraph:testFirePayloadReachesEntryNodeAndPropagatesViaPins()
    local echoId = self.graph:AddNode("fixture.echo")
    local probeId = self.graph:AddNode("fixture.probe")
    self.graph:Connect(echoId, "out", probeId, "in")
    self.graph:Connect(echoId, "msg", probeId, "value")

    self.graph:Fire(echoId, { text = "hello" })

    luaunit.assertEquals(#self.probeLog, 1)
    luaunit.assertEquals(self.probeLog[1].value, { text = "hello" })
end

function TestGraph:testFireWithoutPayloadLeavesCtxPayloadNil()
    local echoId = self.graph:AddNode("fixture.echo")
    local probeId = self.graph:AddNode("fixture.probe")
    self.graph:Connect(echoId, "msg", probeId, "value")
    self.graph:Connect(echoId, "out", probeId, "in")

    self.graph:Fire(echoId)

    luaunit.assertIsNil(self.probeLog[1].value)
end

function TestGraph:testPayloadIsNotVisibleToDownstreamNodes()
    local echoId = self.graph:AddNode("fixture.echo")
    local probeId = self.graph:AddNode("fixture.probe")
    self.graph:Connect(echoId, "out", probeId, "in")

    self.graph:Fire(echoId, { text = "secret" })

    -- the downstream action's own ctx.payload must be nil; only the entry Trigger saw it
    luaunit.assertIsNil(self.probeLog[1].payload)
end

--- Entered exec input, ctx.exec (docs/adr/0010) ---------------------------------------

function TestGraph:testCtxExecReportsWhichInputFired()
    local triggerId = self.graph:AddNode("fixture.trigger")
    local twoInId = self.graph:AddNode("fixture.twoin")
    self.graph:Connect(triggerId, "out", twoInId, "b")

    self.graph:Fire(triggerId)

    luaunit.assertEquals(#self.entryLog, 1)
    luaunit.assertEquals(self.entryLog[1].exec, "b")
end

function TestGraph:testCtxExecIsNilForExternallyFiredEntryNode()
    local twoInId = self.graph:AddNode("fixture.twoin")

    self.graph:Fire(twoInId)

    luaunit.assertEquals(#self.entryLog, 1)
    luaunit.assertIsNil(self.entryLog[1].exec)
end

--- FireInput: entering a node through a chosen exec input ------------------------------

function TestGraph:testFireInputEntersThroughTheNamedExecPin()
    local twoInId = self.graph:AddNode("fixture.twoin")

    self.graph:FireInput(twoInId, "b")

    luaunit.assertEquals(#self.entryLog, 1)
    luaunit.assertEquals(self.entryLog[1].exec, "b")
end

function TestGraph:testFireInputPropagatesDownstream()
    local twoInId = self.graph:AddNode("fixture.twoin")
    local probeId = self.graph:AddNode("fixture.probe")
    self.graph:Connect(twoInId, "out", probeId, "in")

    -- "a" makes fixture.twoin fire its "out", so the probe runs too; "b" would not.
    self.graph:FireInput(twoInId, "a")

    luaunit.assertEquals(#self.entryLog, 1)
    luaunit.assertEquals(self.entryLog[1].exec, "a")
    luaunit.assertEquals(#self.probeLog, 1)
end

function TestGraph:testFireInputGivesTheEntryNodeNilPayload()
    local twoInId = self.graph:AddNode("fixture.twoin")
    local probeId = self.graph:AddNode("fixture.probe")
    self.graph:Connect(twoInId, "out", probeId, "in")

    self.graph:FireInput(twoInId, "a")

    luaunit.assertIsNil(self.probeLog[1].payload)
end

function TestGraph:testFireInputRejectsANonExecInputPin()
    local twoInId = self.graph:AddNode("fixture.twoin")
    -- "out" is an exec OUTPUT, not an input.
    luaunit.assertErrorMsgContains("not an exec input pin", function()
        self.graph:FireInput(twoInId, "out")
    end)
end

--- Node identity, ctx.nodeId ----------------------------------------------------------

function TestGraph:testCtxNodeIdIsTheRunningNodesId()
    local nodeIdLog = {}
    self.registry:RegisterNodeType("fixture.identity", {
        category = "action",
        pins = { { name = "in", kind = "exec", direction = "in", terminates = true } },
        run = function(ctx) table.insert(nodeIdLog, ctx.nodeId) end,
    })
    local a = self.graph:AddNode("fixture.identity")
    local b = self.graph:AddNode("fixture.identity")

    self.graph:FireInput(a, "in")
    self.graph:FireInput(b, "in")

    luaunit.assertEquals(nodeIdLog, { a, b })
end

--- Node state, ctx.state (docs/adr/0010) ----------------------------------------------

function TestGraph:testCtxStatePersistsAcrossFires()
    local triggerId = self.graph:AddNode("fixture.trigger")
    local counterId = self.graph:AddNode("fixture.statecounter")
    local probeId = self.graph:AddNode("fixture.probe")
    self.graph:Connect(triggerId, "out", counterId, "in")
    self.graph:Connect(counterId, "out", probeId, "in")
    self.graph:Connect(counterId, "n", probeId, "value")

    self.graph:Fire(triggerId)
    self.graph:Fire(triggerId)
    self.graph:Fire(triggerId)

    luaunit.assertEquals(self.probeLog[1].value, 1)
    luaunit.assertEquals(self.probeLog[2].value, 2)
    luaunit.assertEquals(self.probeLog[3].value, 3)
end

function TestGraph:testGetStateReturnsTheLiveNodeStateTable()
    local triggerId = self.graph:AddNode("fixture.trigger")
    local counterId = self.graph:AddNode("fixture.statecounter")
    self.graph:Connect(triggerId, "out", counterId, "in")

    luaunit.assertEquals(self.graph:GetState(counterId), {})
    luaunit.assertNil(self.graph:GetState(999))

    self.graph:Fire(triggerId)
    luaunit.assertEquals(self.graph:GetState(counterId).n, 1)
    self.graph:Fire(triggerId)
    luaunit.assertEquals(self.graph:GetState(counterId).n, 2)
end

function TestGraph:testCtxStateIsPerNodeInstance()
    local triggerId = self.graph:AddNode("fixture.trigger")
    local counterA = self.graph:AddNode("fixture.statecounter")
    local counterB = self.graph:AddNode("fixture.statecounter")
    self.graph:Connect(triggerId, "out", counterA, "in")
    self.graph:Connect(triggerId, "out", counterB, "in")

    self.graph:Fire(triggerId)
    self.graph:Fire(triggerId)

    luaunit.assertEquals(self.graph:GetLastValue(counterA, "n"), 2)
    luaunit.assertEquals(self.graph:GetLastValue(counterB, "n"), 2)
end

--- Read-only accessors (docs/adr/0006) -----------------------------------------------

function TestGraph:testGetNodesReturnsAllWithTypeKey()
    local id = self.graph:AddNode("fixture.add")
    local nodes = self.graph:GetNodes()
    luaunit.assertEquals(#nodes, 1)
    luaunit.assertEquals(nodes[1].id, id)
    luaunit.assertEquals(nodes[1].typeKey, "fixture.add")
end

function TestGraph:testGetNodesByCategoryFilters()
    self.graph:AddNode("fixture.trigger")
    self.graph:AddNode("fixture.add")
    local triggers = self.graph:GetNodesByCategory("trigger")
    luaunit.assertEquals(#triggers, 1)
    luaunit.assertEquals(triggers[1].typeKey, "fixture.trigger")
end

function TestGraph:testGetConnectionsReturnsAllFields()
    local triggerId = self.graph:AddNode("fixture.trigger")
    local actionId = self.graph:AddNode("fixture.action")
    self.graph:Connect(triggerId, "out", actionId, "in")

    local conns = self.graph:GetConnections()
    luaunit.assertEquals(#conns, 1)
    luaunit.assertEquals(conns[1].fromNode, triggerId)
    luaunit.assertEquals(conns[1].fromPin, "out")
    luaunit.assertEquals(conns[1].toNode, actionId)
    luaunit.assertEquals(conns[1].toPin, "in")
end

function TestGraph:testGetPinsReturnsDeclaredPinsInOrder()
    local addId = self.graph:AddNode("fixture.add")
    local pins = self.graph:GetPins(addId)
    luaunit.assertEquals(#pins, 3)
    luaunit.assertEquals(pins[1].name, "a")
    luaunit.assertEquals(pins[2].name, "b")
    luaunit.assertEquals(pins[3].name, "sum")
    luaunit.assertEquals(pins[3].dataType, "number")
    luaunit.assertEquals(pins[1].default, 0)  -- pin defaults are exposed for UI Control boxes
end

function TestGraph:testGetPinsUnknownNodeReturnsNil()
    luaunit.assertIsNil(self.graph:GetPins(999))
end

--- Trace (docs/adr/0006) --------------------------------------------------------------

function TestGraph:testTraceRecordsExecuteFireAndPullEntries()
    local triggerId = self.graph:AddNode("fixture.trigger")
    local addId = self.graph:AddNode("fixture.add", { a = 1, b = 1 })
    local actionId = self.graph:AddNode("fixture.action")

    self.graph:Connect(triggerId, "out", actionId, "in")
    self.graph:Connect(addId, "sum", actionId, "value")

    self.graph:Fire(triggerId)

    local trace = self.graph:GetLastTrace()
    luaunit.assertIsTrue(#trace > 0)

    local kinds = {}
    for _, entry in ipairs(trace) do
        kinds[entry.type] = true
    end
    luaunit.assertIsTrue(kinds["execute"])
    luaunit.assertIsTrue(kinds["fire"])
    luaunit.assertIsTrue(kinds["pull"])
end

function TestGraph:testTraceReflectsOnlyTheLatestFire()
    local triggerId = self.graph:AddNode("fixture.trigger")
    local actionId = self.graph:AddNode("fixture.action")
    self.graph:Connect(triggerId, "out", actionId, "in")

    self.graph:Fire(triggerId)
    local firstTrace = self.graph:GetLastTrace()

    self.graph:Fire(triggerId)
    local secondTrace = self.graph:GetLastTrace()

    luaunit.assertEquals(#firstTrace, #secondTrace)
    luaunit.assertNotIs(firstTrace, secondTrace)
end

--- Recursion depth backstop (docs/adr/0004, rule 4) -----------------------------------

function TestGraph:testDeepPureChainExceedsRecursionCap()
    local firstId = self.graph:AddNode("fixture.passthrough", { ["in"] = 42 })
    local previousId = firstId
    -- one more link than MAX_DEPTH in graph.lua, all pulled within a single Fire
    for _ = 1, 300 do
        local nextId = self.graph:AddNode("fixture.passthrough")
        self.graph:Connect(previousId, "out", nextId, "in")
        previousId = nextId
    end

    local actionId = self.graph:AddNode("fixture.action")
    self.graph:Connect(previousId, "out", actionId, "value")

    luaunit.assertErrorMsgContains("recursion depth exceeded", function()
        self.graph:Fire(actionId)
    end)
end

return TestGraph
