--!strict
--[=[
	Written by Max. Discord @614437551498854431
    https://github.com/Vertovy

	------ | ABOUT | ------
	Client-side wrapper around RemoteEvents and RemoteFunctions
	replicated by the server Network module.

	Use channels to group remotes by feature while keeping simple remote
	names such as "Get", "Update", and "Buy" reusable in every channel.

	This module does not create remotes on its own. It observes replicated
	channels/remotes, caches them as they appear, and reconnects them to
	client-side Signals.

	This module returns the Global channel, so you can either use
	`Network.Channel("Inventory")` for feature-specific traffic or call
	remote methods directly on `Network` for shared global remotes.

	If `Channel.OnClientEvent("RemoteName")` is called before that remote
	has replicated, the module creates a placeholder signal and swaps the
	real remote into it once replication finishes.

	Unreliable remote events are observed through the same client
	event path as normal `RemoteEvent`s after they are replicated.
	=======================
	Code sample:
	```luau
		local Network = ...
		local Channel = Network.Channel("Example")

		Channel.OnClientEvent("Update"):Connect(function(...)
		end)

		Channel:FireServer("Buy", 12345)
		local data = Channel:InvokeServer("Get", 67890)
	```
	=======================
	\\\ Create a network channel (optional, Network itself is a Global channel)
	```luau
		Network.Channel(channelId: string) -> Channel
	```

	\\\ Subsititute for RemoteEvent.OnClientEvent
	```luau
		Channel.OnClientEvent(event: string) -> Subsititute for RbxSignal
	```

	\\\ Substitute for RemoteFunction.OnClientInvoke
	```luau
		Channel.OnClientInvoke(event: string) -> { OnInvoke: invokeFn }
	```

	\\\ Subsititute for RemoteEvent:FireServer
	```luau
		Channel:FireServer(event: string, ...: any) -> ()
	```

	\\\ Subsititute for RemoteFunction:InvokeServer
	```luau
		Channel:InvokeServer(event: string, ...: any) -> ...any
	```
--]=]

const Network = {}

--- Modules
const ReplicatedStorage = game:GetService("ReplicatedStorage")
const CollectionService = game:GetService("CollectionService")
const NetworkUtils = require(ReplicatedStorage:WaitForChild("NetworkUtils"))

const Observe = NetworkUtils.Observe
const Signal = NetworkUtils.Signal

--- Variables
const RunService = game:GetService("RunService")

const Folder = ReplicatedStorage:WaitForChild("Remotes", 999) :: Folder
const ClientBeggar = Folder:WaitForChild("Init", 999) :: RemoteEvent

const Remotes = {} :: { [string]: any }

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------

function getRemoteLookupClass(remoteClass: string): string
	if remoteClass == "UnreliableRemoteEvent" then
		return "RemoteEvent"
	end

	return remoteClass
end

function _findRemote(self, remoteName: string, remoteClass: string): RemoteEvent | RemoteFunction | UnreliableRemoteEvent
	const lookup = getRemoteLookupClass(remoteClass)
	local data = self.list[lookup][remoteName]

	if data == nil then
		local _begin = os.clock()
		while data == nil and os.clock() - _begin < 2 do
			task.wait()
			data = self.list[lookup][remoteName]
		end

		if data == nil or data._remote == nil then
			error(("remote '%*' not found in channel '%*'"):format(remoteName, self._id))
		end
	end

	--
	return data
end

--------------------------------------------------------------------------------

function Network.OnClientEvent(self, remoteName: string)
	local remote = self.list.RemoteEvent[remoteName] :: any

	if not remote then
		remote = {
			_signal = Signal.new(),
			_remote = nil,
		}
	end

	self.list.RemoteEvent[remoteName] = remote

	return remote._signal
end

function Network.OnClientInvoke(self, remoteName: string)
	local remote = self.list.RemoteFunction[remoteName] :: any
	local _channel = self._id

	if not remote then
		remote = {
			_remote = nil,
			OnClientInvoke = nil,
		}
	end

	self.list.RemoteFunction[remoteName] = remote
	remote.OnClientInvoke = nil

	return setmetatable(remote, {
		__newindex = function(self, key, fn)
			if key == "OnInvoke" then
				if self.OnClientInvoke ~= nil then
					error(("OnClientInvoke is already set for %*/%*"):format(_channel, remoteName))
				end

				rawset(self, "OnClientInvoke", fn)
			else
				error(("Channel missing key %*"):format(key))
			end
		end,
	}) :: any
end

function Network.FireServer(self, remoteName: string, ...: any?)
	const data = _findRemote(self, remoteName, "RemoteEvent")
	return data._remote:FireServer(...)
end

function Network.InvokeServer(self, remoteName: string, ...: any?)
	const data = _findRemote(self, remoteName, "RemoteFunction")
	return data._remote:InvokeServer(...)
end

function Network:Channel(channelId: string)
	assert(typeof(channelId) == "string", "Expected string")

	--- Try indexing the channel first
	if Remotes[channelId] then
		return Remotes[channelId]
	end

	--- Create a new channel
	const channel = setmetatable({
		_id = channelId,

		list = {
			RemoteEvent = {},
			RemoteFunction = {},
		},
	}, { __index = Network })

	Remotes[channelId] = channel

	--- IT WORKS just like I want it to be!
	const onClientEvent_Ref = channel.OnClientEvent
	const onClientInvoke_Ref = channel.OnClientInvoke
	const channel_Ref = channel.Channel

	channel.OnClientEvent = function(...)
		return onClientEvent_Ref(channel, ...)
	end

	channel.OnClientInvoke = function(...)
		return onClientInvoke_Ref(channel, ...)
	end

	channel.Channel = function(...)
		return channel_Ref(channel, ...)
	end

	--
	return channel
end

--------------------------------------------------------------------------------

Observe.observeTag("NetworkingChannel", function(folder: Folder)
	const channelName = folder.Name :: string

	--- Create channel
	Remotes[channelName] = Network:Channel(channelName)

	--- Channel folder is no longer needed!  Get rid of it!
	if not RunService:IsStudio() then
		folder:RemoveTag("NetworkingChannel")
		folder:Destroy()
	end

	Observe.observeTag(channelName, function(remote: Instance & RemoteEvent & RemoteFunction)
		const remoteClass = remote.ClassName
		const lookupClass = getRemoteLookupClass(remoteClass)
		const remoteName = remote.Name
		local _signal = Signal.new()
		local onClientInvoke: any = nil

		--- remove Tag n clear name
		remote:RemoveTag(channelName)
		remote.Name = ""

		const channel = Remotes[channelName]
		const oldData = channel.list[lookupClass][remoteName]

		if oldData then
			_signal = oldData._signal
			onClientInvoke = oldData.OnClientInvoke
		end

		Remotes[channelName].list[lookupClass][remoteName] = {
			_channel = channelName,
			_name = remoteName,
			_remote = remote,
			_signal = _signal,
			OnClientInvoke = onClientInvoke,
		}

		--- Wire up
		if remoteClass == "RemoteEvent" or remoteClass == "UnreliableRemoteEvent" then
			remote.OnClientEvent:Connect(function(...)
				_signal:Fire(...)
			end)
		elseif remoteClass == "RemoteFunction" then
			remote.OnClientInvoke = function(...)
				return Remotes[channelName].list.RemoteFunction[remoteName].OnClientInvoke(...)
			end
		end

		--- Let server know that we got the remote!
		ClientBeggar:FireServer(channelName, remoteClass, remoteName)
	end)
end)

--------------------------------------------------------------------------------
--------------------------------------------------------------------------------

return Network:Channel("Global")
