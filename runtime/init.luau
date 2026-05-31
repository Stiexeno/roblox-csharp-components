-- Components runtime entry point.
--
-- Used to auto-scan Definitions/ and wire CollectionService listeners
-- itself; that responsibility moved to ComponentsService once the
-- system became DI-driven. The user's installer tail (auto-emitted by
-- the compiler) binds ComponentsService AsSingle and calls Register
-- per discovered Component subclass — there is nothing left for this
-- module to do at boot time.
--
-- We keep the file as a thin re-export so direct `require` of
-- `Plugins.Components` still resolves to a useful module shape, and
-- so the plugin folder layout matches the other plugins (Maid,
-- DependencyInjection) where init.luau is the canonical entry.

return {
	Component = require(script.Component),
	ComponentsService = require(script.ComponentsService),
}
