# Network

Network is a Roblox Luau wrapper around `RemoteEvent`, `UnreliableRemoteEvent`, and `RemoteFunction`. It gives remotes a channel-based API, supports middleware, waits for client replication before server sends, and includes scoped delivery tools for feature streams.

The module is split into server and client implementations:

- `Network/Server @ Network.luau` creates and owns the Roblox remote instances.
- `Network/Client @ Network.luau` observes the replicated instances and exposes the same channel-shaped API on the client.

Both modules return the `Global` channel. You can call methods directly on `Network` for shared global remotes, or create feature channels with `Network.Channel("Inventory")`, `Network.Channel("Shop")`, and so on.

## Core Idea

Channels group remotes by feature while letting each feature reuse simple remote names.

For example, both `Inventory` and `Shop` can have a `"Get"` remote without colliding:

```luau
local Network = require(ReplicatedStorage:WaitForChild("Network"))

local Inventory = Network.Channel("Inventory")
local Shop = Network.Channel("Shop")

Inventory.OnServerInvoke("Get").OnInvoke = function(player)
	return {}
end

Shop.OnServerInvoke("Get").OnInvoke = function(player)
	return {}
end
```

Internally, the server creates a `ReplicatedStorage.Remotes` folder, creates remotes as they are requested, tags them with their channel name, and keeps channel data in memory. The client observes those tags, caches each remote under the matching channel, and wires it into local signals or invoke handlers.

## Replication Handshake

The server includes an internal `Init` remote inside `ReplicatedStorage.Remotes`. When the client sees a replicated remote, it reports the channel, remote class, and remote name back to the server.

Server-to-client sends wait until that player has reported the target remote as loaded. This means the first `FireClient`, `FireAllClients`, or `InvokeClient` for a remote may wait a few frames, but it avoids sending to a client before the remote exists there.

Client-to-server calls can also be made before a remote has replicated. The client waits briefly for the remote to appear and then sends or invokes it.

## Server Usage

Create a channel and register event or function handlers:

```luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Network = require(ReplicatedStorage:WaitForChild("Network"))

local Inventory = Network.Channel("Inventory")

Inventory.OnServerEvent("Equip"):Connect(function(player, itemId)
	print(player.Name, "equipped", itemId)
end)

Inventory.OnServerInvoke("GetItems").OnInvoke = function(player)
	return { "Sword", "Potion" }
end
```

Send data back to clients:

```luau
Inventory:FireClient("Updated", player, itemId)
Inventory:FireAllClients("Broadcast", "inventory changed")
Inventory:FireAllClientsBut("Broadcast", player, "everyone except this player")
```

Use unreliable events for high-frequency, lossy updates:

```luau
Inventory.OnServerEventUnreliable("Aim"):Connect(function(player, direction)
	-- Handle frequent client updates.
end)

Inventory:FireClientUnreliable("Position", player, position)
Inventory:FireAllClientsUnreliable("Position", position)
Inventory:FireAllClientsButUnreliable("Position", player, position)
```

## Client Usage

Create the same channel name on the client and listen for server messages:

```luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Network = require(ReplicatedStorage:WaitForChild("Network"))

local Inventory = Network.Channel("Inventory")

Inventory.OnClientEvent("Updated"):Connect(function(itemId)
	print("Inventory updated:", itemId)
end)

Inventory:FireServer("Equip", "Sword")

local items = Inventory:InvokeServer("GetItems")
```

Expose a client callback for server invokes:

```luau
Inventory.OnClientInvoke("GetSelectedSlot").OnInvoke = function()
	return 1
end
```

## Middleware

Middleware runs before a client request reaches its final server handler. It runs in this order:

1. Global `Network` middleware
2. Channel middleware
3. Remote middleware

Middleware receives the player, a response object, and the original remote arguments. It must return `true` to continue to the next middleware or handler.

```luau
local function requireAlive(player, response, ...)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")

	if not humanoid or humanoid.Health <= 0 then
		response.send(false, "Player is not alive")
		return false
	end

	return true
end

Network:use(requireAlive)
Inventory:use(function(player, response, ...)
	return true
end)

Inventory.OnServerEvent("Equip", function(player, response, itemId)
	return true
end):Connect(function(player, itemId)
	-- Runs only when all middleware allowed the request.
end)
```

Middleware can be attached globally with `Network:use`, to a channel with `Channel:use`, or to a specific remote by passing middleware functions into `OnServerEvent`, `OnServerEventUnreliable`, or `OnServerInvoke`.

If middleware stops the request, remaining middleware and the final handler do not run. For functions, the cancellation response is returned to the invoking client.

## Pipelines

A pipeline is a scoped view of a channel with its own player allow-list. It uses the same channel remotes and pooling state, but server-to-client fire methods only reach players in that pipeline.

```luau
local Customers = Network.Channel("Customers")
local BusinessStream = Customers:CreatePipeline()

BusinessStream:AddToPipeline(player)

BusinessStream:FireClient("Updated", player, customerData)
BusinessStream:FireAllClients("Updated", customerData)
BusinessStream:FireAllClientsBut("Updated", player, customerData)
```

Pipeline membership can be managed with:

```luau
BusinessStream:IsInPipeline(player)
BusinessStream:GetPlayersInPipeline()
BusinessStream:AddToPipeline(player)
BusinessStream:RemoveFromPipeline(player)
BusinessStream:ClearPipeline()
BusinessStream:DestroyPipeline()
```

Players are automatically removed from pipelines when they leave the server.

## Pooling

Pooling batches repeated server-to-client fires for a channel during a short time window. When the window flushes, the client receives an array of packets. Each packet is the argument list from one fire.

```luau
local Updates = Network.Channel("Updates")
Updates:MakePool(0.1)

Updates:FireClient("Batch", player, "a", 1)
Updates:FireClient("Batch", player, "b", 2)
```

The client receives:

```luau
Updates.OnClientEvent("Batch"):Connect(function(packets)
	for _, packet in packets do
		print(table.unpack(packet))
	end
end)
```

Pooling applies to the reliable `FireClient` family on that channel, including pipeline sends that use the channel.

## API Summary

Shared:

```luau
Network.Channel(channelId: string) -> Channel
```

Server:

```luau
Network:use(middleware) -> Channel
Channel:use(middleware) -> Channel

Channel.OnServerEvent(remoteName: string, ...middleware) -> Signal
Channel.OnServerEventUnreliable(remoteName: string, ...middleware) -> Signal
Channel.OnServerInvoke(remoteName: string, ...middleware) -> { OnInvoke: callback }

Channel:FireClient(remoteName: string, player: Player, ...any)
Channel:FireAllClients(remoteName: string, ...any)
Channel:FireAllClientsBut(remoteName: string, exception: Player, ...any)

Channel:FireClientUnreliable(remoteName: string, player: Player, ...any)
Channel:FireAllClientsUnreliable(remoteName: string, ...any)
Channel:FireAllClientsButUnreliable(remoteName: string, exception: Player, ...any)

Channel:InvokeClient(remoteName: string, player: Player, ...any) -> ...any
Channel:MakePool(delta: number)
Channel:CreatePipeline() -> Pipeline
```

Client:

```luau
Channel.OnClientEvent(remoteName: string) -> Signal
Channel.OnClientInvoke(remoteName: string) -> { OnInvoke: callback }

Channel:FireServer(remoteName: string, ...any)
Channel:InvokeServer(remoteName: string, ...any) -> ...any
```

Pipeline:

```luau
Pipeline:IsInPipeline(player: Player) -> boolean
Pipeline:GetPlayersInPipeline() -> { Player }
Pipeline:AddToPipeline(player: Player)
Pipeline:RemoveFromPipeline(player: Player)
Pipeline:ClearPipeline()
Pipeline:DestroyPipeline()

Pipeline:FireClient(remoteName: string, player: Player, ...any)
Pipeline:FireAllClients(remoteName: string, ...any)
Pipeline:FireAllClientsBut(remoteName: string, exception: Player, ...any)
```

## Dependencies

The modules expect `ReplicatedStorage.NetworkUtils` to provide:

- `Observe`, used for observing tagged instances and players
- `Signal`, used for local event dispatch

Place the server implementation where server scripts require `Network`, and the client implementation where client scripts require the same module name.
