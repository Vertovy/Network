--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Network = require(ReplicatedStorage:WaitForChild("Network"))

local TIMEOUT = 12

local Control = Network.Channel("NetworkTestControl")
local Channel = Network.Channel("NetworkTest")
local MiddlewareChannel = Network.Channel("NetworkTestMiddleware")
local PooledChannel = Network.Channel("NetworkTestPool")
local PipelineChannel = Network.Channel("NetworkTestPipeline")

local function fail(message: string): never
	error(`[NetworkTest/client] {message}`, 2)
end

local function waitUntilReady(action: () -> (), label: string)
	local started = os.clock()
	local lastError: any = nil

	while os.clock() - started < TIMEOUT do
		local success, err = pcall(action)

		if success then
			return
		end

		lastError = err
		task.wait()
	end

	fail(`timed out waiting for {label}: {tostring(lastError)}`)
end

local function sendResult(key: string, ...: any)
	local args = table.pack(...)

	waitUntilReady(function()
		Control:FireServer("ClientResult", key, table.unpack(args, 1, args.n))
	end, `ClientResult/{key}`)
end

local function sendEvent(channel: any, remoteName: string, ...)
	local args = table.pack(...)

	waitUntilReady(function()
		channel:FireServer(remoteName, table.unpack(args, 1, args.n))
	end, remoteName)
end

local function sendInvokeResult(key: string, channel: any, remoteName: string, ...)
	local args = table.pack(...)

	waitUntilReady(function()
		sendResult(key, channel:InvokeServer(remoteName, table.unpack(args, 1, args.n)))
	end, remoteName)
end

Control.OnClientEvent("Done"):Connect(function()
	print("[NetworkTest/client] all tests passed")
end)

Channel.OnClientEvent("ServerToClient"):Connect(function(...)
	sendResult("server-to-client", ...)
end)

Channel.OnClientEvent("ServerToClientAll"):Connect(function(...)
	sendResult("server-to-client-all", ...)
end)

Channel.OnClientEvent("ServerToClientBut"):Connect(function(...)
	sendResult("server-to-client-but", ...)
end)

Channel.OnClientEvent("ServerToClientUnreliable"):Connect(function(...)
	sendResult("server-to-client-unreliable", ...)
end)

Channel.OnClientEvent("ServerToClientAllUnreliable"):Connect(function(...)
	sendResult("server-to-client-all-unreliable", ...)
end)

Channel.OnClientEvent("ServerToClientButUnreliable"):Connect(function(...)
	sendResult("server-to-client-but-unreliable", ...)
end)

Channel.OnClientInvoke("ServerInvokeClient").OnInvoke = function(...)
	return "client-invoke-ok", ...
end

PooledChannel.OnClientEvent("Pooled"):Connect(function(...)
	sendResult("pooled", ...)
end)

PipelineChannel.OnClientEvent("PipelineEvent"):Connect(function(...)
	sendResult("pipeline-client", ...)
end)

PipelineChannel.OnClientEvent("PipelineAll"):Connect(function(...)
	sendResult("pipeline-all", ...)
end)

PipelineChannel.OnClientEvent("PipelineBut"):Connect(function(...)
	sendResult("pipeline-but", ...)
end)

PipelineChannel.OnClientEvent("PipelineAfterRemove"):Connect(function(...)
	sendResult("pipeline-after-remove", ...)
end)

task.spawn(function()
	sendResult("ready")

	sendEvent(Channel, "ClientToServer", "client-event", 8)
	sendEvent(Channel, "ClientToServerUnreliable", "client-unreliable-event", 9)
	sendEvent(Network, "GlobalEvent", "global-event", 10)

	sendInvokeResult("client-invoke-server", Channel, "ClientInvoke", "invoke-server", 11)
	sendInvokeResult("global-invoke-server", Network, "GlobalInvoke", "global-invoke", 12)
	sendInvokeResult("middleware-invoke", MiddlewareChannel, "Run", "middleware")
	sendInvokeResult("middleware-cancel", MiddlewareChannel, "Cancel", "middleware-cancel")
end)
