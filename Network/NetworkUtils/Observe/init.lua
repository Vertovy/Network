--!strict

--[=[
	@class Observers

	A collection of observer utility functions.
]=]

return {
	observeTag = require(script.observeTag),
	observeChild = require(script.observeChild),
	observeAttribute = require(script.observeAttribute),
	observeProperty = require(script.observeProperty),
	observePlayer = require(script.observePlayer),
	observeCharacter = require(script.observeCharacter),
	observeDescendant = require(script.observeDescendant),
}
