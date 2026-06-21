--!strict

export type CleanupFn = () -> ()
export type CallbackFn = (child: Instance) -> CleanupFn?

const function observeChild(parent: Instance, callback: CallbackFn): () -> ()
	const cleanups: { [Instance]: CleanupFn } = {}

	const function onAdded(child: Instance)
		-- Dispose any previous cleanup for this child (defensive)
		const prev = cleanups[child]
		if prev then
			task.spawn(prev)
			cleanups[child] = nil
		end

		const clean = callback(child)
		if typeof(clean) == "function" then
			cleanups[child] = clean :: CleanupFn
		end
	end

	const function onRemoved(child: Instance)
		const clean = cleanups[child]
		if clean then
			task.spawn(clean)
			cleanups[child] = nil
		end
	end

	local addedConn
	local removedConn
	local disconnected = false

	-- Also run for any existing children (after connections are live)
	task.defer(function()
		-- If disconnected before defer runs, bail
		if disconnected then
			return
		end

		for _, child in ipairs(parent:GetChildren()) do
			onAdded(child)
		end

		addedConn = parent.ChildAdded:Connect(onAdded)
		removedConn = parent.ChildRemoved:Connect(onRemoved)	
	end)

	-- stop/cleanup
	return function()
		disconnected = true

		if addedConn and addedConn.Connected then
			addedConn:Disconnect()
		end
		if removedConn and removedConn.Connected then
			removedConn:Disconnect()
		end
		for child, clean in cleanups do
			task.spawn(clean)
			cleanups[child] = nil
		end
	end
end

return observeChild
