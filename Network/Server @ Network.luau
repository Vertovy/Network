--!strict
--[=[
	Written by Max. Discord @614437551498854431
	https://github.com/Vertovy

	------ | ABOUT | ------
	Server-side wrapper around RemoteEvents and RemoteFunctions
	replicated to the client Network module.

	Use channels to group remotes by feature while keeping simple remote
	names such as "Get", "Update", and "Buy" reusable in every channel.

	Every request goes through built-in middleware in this order:
	Global Network middleware -> Channel middleware -> Remote middleware

	This module returns the Global channel, so you can either use
	`Network.Channel("Inventory")` for feature-specific traffic or call
	remote methods directly on `Network` for shared global remotes.

	This module creates and owns the replicated channel folders and remotes.
	The client observes those instances and reports when each remote has
	loaded, so first server-to-client sends wait until replication is ready.

	Pipelines are scoped channel views with their own player allow-list.
	They use the owning channel's remotes, middleware registration, and pool
	state, but client fire methods only reach players inside that pipeline.

	Use `Channel:CreatePipeline()` when one feature channel needs multiple
	independent streams of the same event contract. For example, customer
	updates can use one "Customers" channel while creating one pipeline per
	business, so only players close enough to that business receive its
	customer stream.

	Players are automatically removed from scoped pipelines when they leave
	the server.

	Pools batch repeated client fires per remote and per player during a
	short time window. When the pool flushes, the client receives an array
	of buffered packets, where each entry is the argument list from one fire.
	=======================
	Code sample:
	```luau
		local Network = ...
		local Channel = Network.Channel("Example")

		Channel.OnServerEvent("Buy"):Connect(function(player: Player, ...)
		end)

		Channel.OnServerInvoke("Get").OnInvoke = function(player: Player, ...)
			return {}
		end

		Channel:FireClient("Update", player, "something")
		Channel:FireAllClients("Update", "something")

		local Pipeline = Channel:CreatePipeline()
		Pipeline:AddToPipeline(player)
		Pipeline:FireClient("Update", player, "only if player is inside")
		Pipeline:FireAllClients("Update", "only players inside this pipeline")
	```
	=======================
	\\\ Create a network channel (optional, Network itself is a Global channel)
	```luau
		Network.Channel(channelId: string) -> Channel
	```

	\\\ Global middleware, executed for every remote
	```luau
		Network.use(middleware: middleware) -> Channel
	```

	\\\ Channel middleware, executed for every remote owned by the channel
	```luau
		Channel.use(middleware: middleware) -> Channel
	```

	\\\ Substitute for RemoteEvent.OnServerEvent
	```luau
		Channel.OnServerEvent(event: string, ...: middleware) -> Substitute for RbxSignal
	```

	\\\ Substitute for UnreliableRemoteEvent.OnServerEvent
	```luau
		Channel.OnServerEventUnreliable(event: string, ...: middleware) -> Substitute for RbxSignal
	```

	\\\ Substitute for RemoteFunction.OnServerInvoke
	```luau
		Channel.OnServerInvoke(event: string, ...: middleware) -> { OnInvoke: invokeFn }
	```

	\\\ Substitute for RemoteEvent:FireClient
	```luau
		Channel:FireClient(event: string, player: Player, ...: any) -> ()
	```

	\\\ Substitute for RemoteEvent:FireAllClients
	```luau
		Channel:FireAllClients(event: string, ...: any) -> ()
	```

	\\\ Same as FireAllClients, but skips the provided player
	```luau
		Channel:FireAllClientsBut(event: string, exception: Player, ...: any) -> ()
	```

	\\\ Substitute for RemoteFunction:InvokeClient
	```luau
		Channel:InvokeClient(event: string, player: Player, ...: any) -> ...any
	```

	\\\ Creates a scoped pipeline with its own player allow-list
	```luau
		Channel:CreatePipeline() -> Pipeline
	```

	\\\ Pipeline membership
	```luau
		Pipeline:IsInPipeline(player: Player) -> boolean
		Pipeline:GetPlayersInPipeline() -> { Player }
		Pipeline:AddToPipeline(player: Player) -> ()
		Pipeline:RemoveFromPipeline(player: Player) -> ()
		Pipeline:ClearPipeline() -> ()
		Pipeline:DestroyPipeline() -> ()
	```

	\\\ Pipeline fire methods use the owning channel's remotes and pooling,
	\\\ but are filtered by this pipeline's player list.
	```luau
		Pipeline:FireClient(event: string, player: Player, ...: any) -> ()
		Pipeline:FireAllClients(event: string, ...: any) -> ()
		Pipeline:FireAllClientsBut(event: string, exception: Player, ...: any) -> ()
	```

	\\\ Enables packet pooling for the FireClient family on this channel
	\\\ Buffered sends flush after `delta` seconds as `{ {...}, {...} }`
	```luau
		Channel:MakePool(delta: number) -> ()
	```

	\\\ Unreliable client fire methods, same signatures as the reliable versions
	```luau
		Channel:FireClientUnreliable(event: string, player: Player, ...: any) -> ()
		Channel:FireAllClientsUnreliable(event: string, ...: any) -> ()
		Channel:FireAllClientsButUnreliable(event: string, exception: Player, ...: any) -> ()
	```
--]=]

const Network = { _middlewares = {} }

--- Modules
const ReplicatedStorage = game:GetService("ReplicatedStorage")
const NetworkUtils = require(ReplicatedStorage:WaitForChild("NetworkUtils"))

const Observe = NetworkUtils.Observe
const Signal = NetworkUtils.Signal

--- Reference
const RunService = game:GetService("RunService")
const Folder = Instance.new("Folder")
Folder.Name = "Remotes"
Folder.Parent = ReplicatedStorage

--- Variables
const Remotes = {}

--- Types
type middleware_request = {
	player: Player,
	args: { [number]: any },
}

type middleware_response = {
	cancelled: boolean,
	result: { any },
	send: (...any) -> (),
}

type middleware = (player: Player, response: middleware_response, args: any?) -> ...any
type remote_class = "RemoteEvent" | "UnreliableRemoteEvent" | "RemoteFunction"

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------

function getRemoteLookupClass(remoteClass: string): string
	if remoteClass == "UnreliableRemoteEvent" then
		return "RemoteEvent"
	end

	return remoteClass
end

--------------------------------------------------------------------------------

--- ClientBeggar is the remote that handles client-to-server notifications
--- when remotes have loaded for players. This is important for FireClient & InvokeClient
--- because they might not be initialized yet.
const ClientBeggar = Instance.new("RemoteEvent")
ClientBeggar.Name = "Init"
ClientBeggar.Parent = Folder

const PlayerLoadedRemotes = {}

ClientBeggar.OnServerEvent:Connect(function(player: Player, channelName: string, remoteClass: remote_class, remoteName: string)
	if not Remotes[channelName] then
		return
	end

	const lookupClass = getRemoteLookupClass(remoteClass)

	if not Remotes[channelName]._events[lookupClass] or not Remotes[channelName]._events[lookupClass][remoteName] then
		return
	end

	if not PlayerLoadedRemotes[player] then
		PlayerLoadedRemotes[player] = {}
	end

	if not PlayerLoadedRemotes[player][channelName] then
		PlayerLoadedRemotes[player][channelName] = {}
	end

	if not PlayerLoadedRemotes[player][channelName][lookupClass] then
		PlayerLoadedRemotes[player][channelName][lookupClass] = {}
	end

	PlayerLoadedRemotes[player][channelName][lookupClass][remoteName] = true
end)

Observe.observePlayer(function(player: Player)
	if not PlayerLoadedRemotes[player] then
		PlayerLoadedRemotes[player] = {} :: { [string]: any }
	end

	return function()
		PlayerLoadedRemotes[player] = nil
	end
end)

function await(player: Player, channelName: string, remoteClass: remote_class, remoteName: string)
	if not PlayerLoadedRemotes[player] then
		PlayerLoadedRemotes[player] = {}
	end

	const store = PlayerLoadedRemotes[player]

	if store[channelName] and store[channelName][remoteClass] and store[channelName][remoteClass][remoteName] then
		return true
	end

	while (not store[channelName] or not store[channelName][remoteClass] or not store[channelName][remoteClass][remoteName])
		and player
		and player.Parent
	do
		RunService.Heartbeat:Wait()
		RunService.Heartbeat:Wait()
	end

	return player and player.Parent and true or false
end

function keys(t: { [any]: any }): { any }
	const _keys = {}
	for k in t do
		table.insert(_keys, k)
	end
	return _keys
end

--------------------------------------------------------------------------------

--[[
	Middleware is called before a request is processed and can cancel the
	request or send a response to the client.
	Any middleware MUST return `true` to proceed to the next middleware.
	Middleware functions are called in order:
	
	------------------------------------------------------------------
	1.Global Middleware   2. Channel Middleware   3. Remote Middleware
	------------------------------------------------------------------
	
	Each point can have as many middleware functions as needed. If middleware
	cancels the request, the next middleware functions will not be called.
--]]

const MiddlewareMethods = {}
const Middleware = setmetatable({
	_class = "Middleware",
}, {
	__index = MiddlewareMethods,
})

function MiddlewareMethods:use(
	middleware: middleware,
	req: middleware_request,
	res: middleware_response,
	nextFunc: () -> any
): (boolean, ...any?)
	const success, middlewareResponse = pcall(function()
		return table.pack(middleware(req.player, res, unpack(req.args))) --nextFunc))
	end)

	if not success then
		warn(("[Network Middleware] Error in middleware: %*"):format(middlewareResponse))
		return false
	end

	const success = middlewareResponse[1]
	if success == true then
		return nextFunc()
	end

	res.send(false, table.unpack(middlewareResponse))

	return false
end

--------------------------------------------------------------------------------

function insertMiddlewares(data: { _middlewares: { middleware } }, ...)
	const t = { ... } :: { middleware }
	for i, middleware in ipairs(t) do
		table.insert(data._middlewares, middleware)
	end
end

function getChannelData(channelOrPipeline: any): any
	return channelOrPipeline._channelData or channelOrPipeline
end

function isPipeline(data: any): boolean
	return data._channelData ~= nil
end

function getFirePlayers(data: any): { Player }
	if isPipeline(data) then
		return data:GetPlayersInPipeline()
	end

	return game.Players:GetPlayers()
end

--[=[
	Executes the middleware functions and decides whether the remote
	should proceed with the request.
	Read more about middleware above.
--]=]
function executeMiddleware(
	channelData: any,
	remoteData: any,
	player: Player,
	args: { any }
): (middleware_request, middleware_response)
	const req = { player = player, args = args } :: middleware_request
	const res = { cancelled = false, result = {} } :: middleware_response

	res.send = function(...)
		res.result = table.pack(...)
	end

	local currentIndex = 0
	const middlewareIndex: { [middleware]: true } = {}
	const middlewareList: { middleware } = {}

	--- Collect all middleware functions
	--- for easier execution in the next step.
	for i, v in { Network, channelData, remoteData } do
		const middlewares = v._middlewares :: { middleware }

		for _, mw in middlewares do
			if not mw or middlewareIndex[mw] then
				continue
			end

			--- Register middleware functions to avoid duplicates.
			middlewareIndex[mw] = true

			--- Main list of middleware functions that will be used.
			table.insert(middlewareList, mw)
		end
	end

	--- Continuously call middleware functions until one of them fails.
	--- As soon as one fails, stop execution and let the request process further.
	const function nextFunc()
		currentIndex += 1

		--- Get next middleware
		const middleware = middlewareList[currentIndex]
		if middleware then
			--- Execute it
			if Middleware:use(middleware, req, res, nextFunc) == false then
				res.cancelled = true
			end
		end
	end

	nextFunc()

	return req, res
end

--[=[
	Creates a channel and stores it by its original name.
]=]
function findChannel(channelName: string, _middlewares: any?)
	local channelData = Remotes[channelName]

	if not channelData then
		const f = Instance.new("Folder") :: Folder
		f.Name = channelName
		f:AddTag("NetworkingChannel")
		f.Parent = Folder

		channelData = setmetatable({
			_channel = channelName,

			_events = {
				RemoteEvent = {},
				RemoteFunction = {},
			},
			_middlewares = _middlewares or {},
		}, { __index = Network }) :: any

		Remotes[channelName] = channelData
	end

	return channelData
end

--[=[
	Creates a remote and stores it in channelData._events,
	then sets it up to receive client requests.
]=]
function findEvent(channelName: string, remoteName: string, remoteClass: remote_class)
	const channelData = findChannel(channelName)
	const lookupClass = getRemoteLookupClass(remoteClass)

	local remoteData = channelData._events[lookupClass][remoteName]

	if not remoteData then
		--- Create a remote and tag it with the channel name.
		--- Later, the client will cache and process it.
		const remoteEvent = Instance.new(remoteClass)
		remoteEvent.Parent = Folder
		remoteEvent.Name = remoteName
		remoteEvent:AddTag(channelName)

		--- Create a data table for each remote with a _signal
		--- attribute for handling RemoteEvent middleware.
		remoteData = {
			_remote = remoteEvent,
			_channel = channelName,
			_class = lookupClass,
			_name = remoteName,
			_signal = Signal.new(),
			_middlewares = {},
		}

		--- Listen for fired events, execute middleware, and call the final
		--- handler through _signal for RemoteEvents.
		if remoteClass == "RemoteEvent" or remoteClass == "UnreliableRemoteEvent" then
			remoteEvent.OnServerEvent:Connect(function(player, ...)
				const args = { ... }
				const req, res = executeMiddleware(channelData, remoteData, player, args)

				--- Middleware cancelled the request.
				if res.cancelled then
					return
				end

				remoteData._signal:Fire(player, table.unpack(req.args))
			end)
		elseif remoteClass == "RemoteFunction" then
			remoteEvent.OnServerInvoke = function(player, ...)
				const args = { ... }
				const req, res = executeMiddleware(channelData, remoteData, player, args)

				--- Middleware cancelled the request.
				if res.cancelled then
					return select(2, unpack(res.result))
				end

				const result = table.pack(remoteData.OnServerInvoke(player, ...))
				return table.unpack(result, 1, result.n)
			end
		end

		--- Cache it to avoid duplicates.
		channelData._events[lookupClass][remoteName] = remoteData
	end

	return remoteData
end

--------------------------------------------------------------------------------

function Network:use(...)
	insertMiddlewares(getChannelData(self), ...)
	return self
end

function Network:OnServerInvoke(remoteName: string, ...)
	const channelData = getChannelData(self)
	const event = findEvent(channelData._channel, remoteName, "RemoteFunction")
	insertMiddlewares(event, ...)
	event.OnServerInvoke = nil
	return setmetatable(event, {
		__newindex = function(self, key, fn)
			if key == "OnInvoke" then
				if self.OnServerInvoke ~= nil then
					error(("OnServerInvoke is already set for %*/%*"):format(self._channel, key))
				end

				rawset(self, "OnServerInvoke", fn)
			else
				error(("Channel missing key %*"):format(key))
			end
		end,
	}) :: any
end

function Network.InvokeClient(self, remoteName: string, player: Player, ...: any?)
	print(`Unsafe invocation | Channel:InvokeClient({remoteName})`)
	const channelData = getChannelData(self)
	const event = findEvent(channelData._channel, remoteName, "RemoteFunction")

	if isPipeline(self) and not self:IsInPipeline(player) then
		return false
	end

	if not await(player, event._channel, event._class, event._name) then
		return
	end

	return event._remote:InvokeClient(player, ...)
end

function Network:OnServerEvent(remoteName: string, ...)
	const channelData = getChannelData(self)
	const event = findEvent(channelData._channel, remoteName, "RemoteEvent")
	insertMiddlewares(event, ...)
	return event._signal
end

function Network:OnServerEventUnreliable(remoteName: string, ...)
	const channelData = getChannelData(self)
	const event = findEvent(channelData._channel, remoteName, "UnreliableRemoteEvent")
	insertMiddlewares(event, ...)
	return event._signal
end

--[=[
	!!!
	Pay attention that the first remote fire might be delayed by a few frames.
	This happens because instance replication from server to client can take time.
	To handle that securely, we track each player's loaded remotes and wait for
	the player to report replication status.
	!!!
--]=]
function Network._FireClient(self, remoteClass: remote_class, remoteName: string, player: Player, ...)
	task.spawn(function(...)
		const channelData = getChannelData(self)
		const event = findEvent(channelData._channel, remoteName, remoteClass)
		const remoteKey = (`RemoteEvent/%*`):format(remoteName)

		assert(player, "Expected player. got nil")
		assert(typeof(player) == "Instance" and player:IsA("Player"), "Expected player. got other type")

		if isPipeline(self) and not self:IsInPipeline(player) then
			return
		end

		if not await(player, event._channel, event._class, event._name) then
			return
		end

		if channelData._poolDelta and channelData._poolDelta > 0 then
			channelData:_AddToPool(remoteKey, player, ...)

			if not channelData:_GetLastWritten(remoteKey, player) then
				channelData:_SetLastWritten(remoteKey, player, os.clock())

				task.delay(channelData._poolDelta, function()
					const pool = channelData:_PopPool(remoteKey, player)
					event._remote:FireClient(player, pool)
				end)
			end
			return
		end

		event._remote:FireClient(player, ...)
	end, ...)
end

function Network._FireAllClients(self, remoteClass: remote_class, remoteName: string, ...)
	for i, player in getFirePlayers(self) do
		task.spawn(function(...)
			self:_FireClient(remoteClass, remoteName, player, ...)
		end, ...)
	end
end

function Network._FireAllClientsBut(self, remoteClass: remote_class, remoteName: string, exception: Player, ...: any?)
	assert(exception, "Expected player. got nil")
	assert(typeof(exception) == "Instance" and exception:IsA("Player"), "Expected player. got other type")

	for i, player in getFirePlayers(self) do
		if player == exception then
			continue
		end

		task.spawn(function(...)
			self:_FireClient(remoteClass, remoteName, player, ...)
		end, ...)
	end
end

function Network.FireClient(self, remoteName: string, player: Player, ...)
	self:_FireClient("RemoteEvent", remoteName, player, ...)
end

function Network.FireAllClients(self, remoteName: string, ...)
	self:_FireAllClients("RemoteEvent", remoteName, ...)
end

function Network.FireAllClientsBut(self, remoteName: string, exception: Player, ...: any?)
	self:_FireAllClientsBut("RemoteEvent", remoteName, exception, ...)
end

function Network.FireClientUnreliable(self, remoteName: string, player: Player, ...)
	self:_FireClient("UnreliableRemoteEvent", remoteName, player, ...)
end

function Network.FireAllClientsUnreliable(self, remoteName: string, ...)
	self:_FireAllClients("UnreliableRemoteEvent", remoteName, ...)
end

function Network.FireAllClientsButUnreliable(self, remoteName: string, exception: Player, ...: any?)
	self:_FireAllClientsBut("UnreliableRemoteEvent", remoteName, exception, ...)
end

function Network:MakePool(delta: number)
	const channelData = getChannelData(self)
	channelData._poolDelta = delta
	channelData._pool = {}
	channelData._lastWritten = {}
end

function Network:_PopPool(remote: string, player: Player)
	if not self._pool[remote] then

		return
	end

	if not self._pool[remote][player] then
		return
	end

	const pool = self._pool[remote][player]
	self._pool[remote][player] = nil
	self._lastWritten[remote][player] = nil
	return pool
end

function Network:_GetLastWritten(remote: string, player: Player)
	if not self._lastWritten[remote] then
		return
	end

	if not self._lastWritten[remote][player] then
		return
	end

	return self._lastWritten[remote][player]
end

function Network:_SetLastWritten(remote: string, player: Player, time: number)
	if not self._lastWritten[remote] then
		self._lastWritten[remote] = {}
	end

	self._lastWritten[remote][player] = time
end

function Network:_AddToPool(remote: string, player: Player, ...)
	if not self._pool[remote] then
		self._pool[remote] = {}
	end

	if not self._pool[remote][player] then
		self._pool[remote][player] = {}
	end

	table.insert(self._pool[remote][player], {...})
end

--- PIPELINE

const Pipeline = {}
Pipeline.__index = function(_, key)
	return Pipeline[key] or Network[key]
end

function Network:CreatePipeline()
	local pipeline = setmetatable({

		--[[  Fields  ]]--
		_channelData = getChannelData(self),
		_pipeline    = {},

		--[[  Signals  ]]--
		Added   = Signal.new(function(player: Player)  end),
		Removed = Signal.new(function(player: Player)  end),

	}, Pipeline)

	pipeline._pipelineObserver = Observe.observePlayer(function(player: Player)
		return function()
			pipeline:RemoveFromPipeline(player)
		end
	end)

	--
	return pipeline
end

function Pipeline:IsInPipeline(player: Player)
	return self._pipeline[player] == true
end

function Pipeline:GetPlayersInPipeline()
	return keys(self._pipeline)
end

function Pipeline:AddToPipeline(player: Player)
	if self._pipeline[player] then
		return
	end

	self._pipeline[player] = true
	self.Added:Fire(player)
end

function Pipeline:RemoveFromPipeline(player: Player)
	if not self._pipeline[player] then
		return
	end

	self._pipeline[player] = nil
	self.Removed:Fire(player)
end

function Pipeline:ClearPipeline()
	for player in pairs(self._pipeline) do
		self:RemoveFromPipeline(player)
	end
end

function Pipeline:DestroyPipeline()
	self:ClearPipeline()
	self._channelData = nil

	if self._pipelineObserver then
		self._pipelineObserver()
		self._pipelineObserver = nil
	end
end

--------------------------------------------------------------------------------

--[=[
	Create a channel
--]=]
function Network.Channel(a1: any?, channelId: any?)
	--- Swap arguments.
	if not channelId and a1 then
		channelId = a1
		a1 = nil :: any
	end

	const channelName = channelId

	if Remotes[channelName] then
		return Remotes[channelName]
	end

	const channel = findChannel(channelName, not a1 and Network._middlewares or nil)

	--- These functions are called with . instead of :, so self will not be
	--- defined. Use refs to preserve the channel.
	const onServerEvent_Ref = channel.OnServerEvent
	const onServerEventUnreliable_Ref = channel.OnServerEventUnreliable
	const channel_Ref = channel.Channel
	const invoked_Ref = channel.OnServerInvoke
	const use_Ref = channel.use

	channel.OnServerEvent = function(...)
		return onServerEvent_Ref(channel, ...)
	end

	channel.OnServerEventUnreliable = function(...)
		return onServerEventUnreliable_Ref(channel, ...)
	end

	channel.Channel = function(...)
		return channel_Ref(channel, ...)
	end

	channel.OnServerInvoke = function(...)
		return invoked_Ref(channel, ...)
	end

	channel.use = function(...)
		return use_Ref(channel, ...)
	end

	--
	return channel :: any
end

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------

return Network.Channel("Global")
