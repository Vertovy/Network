--!strict

export type CleanupFn = () -> ()
export type CallbackFn = (descendant: Instance) -> CleanupFn?

const function observeDescendant(root: Instance, callback: CallbackFn): () -> ()
	const cleanups: { [Instance]: CleanupFn } = {}

	const function onAdded(desc: Instance)
		-- Defensive: if a cleanup already exists for this instance, run it first
		const prev = cleanups[desc]
		if prev then
			task.spawn(prev)
			cleanups[desc] = nil
		end

		const clean = callback(desc)
		if typeof(clean) == "function" then
			cleanups[desc] = clean :: CleanupFn
		end
	end

	const function onRemoving(desc: Instance)
		const clean = cleanups[desc]
		if clean then
			task.spawn(clean)
			cleanups[desc] = nil
		end
	end

	const addedConn = root.DescendantAdded:Connect(onAdded)
	const removingConn = root.DescendantRemoving:Connect(onRemoving)

	-- Run for existing descendants after connections are live
	task.defer(function()
		-- If disconnected before defer runs, bail
		if (not addedConn.Connected) or not removingConn.Connected then
			return
		end
		for _, desc in ipairs(root:GetDescendants()) do
			-- call the same handler so behavior is identical to runtime adds
			onAdded(desc)
		end
	end)

	-- stop/cleanup
	return function()
		if addedConn.Connected then
			addedConn:Disconnect()
		end
		if removingConn.Connected then
			removingConn:Disconnect()
		end
		for desc, clean in cleanups do
			task.spawn(clean)
			cleanups[desc] = nil
		end
	end
end

return observeDescendant
