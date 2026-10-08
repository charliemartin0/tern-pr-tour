--!strict
-- The window half only has a dev hook: PR_TOUR_AUTOOPEN="<owner/repo> <number>"
-- opens the tour block at window start, so a headless window can be tested
-- (test/e2e.sh). Normal use opens the block from graphite's Diff button or
-- with `pr-tour.tour <owner/repo> <number>`.

tern.on("window_start", function(cx: WindowCx)
	local auto = tern.getenv("PR_TOUR_AUTOOPEN")
	if auto == nil or auto == "" then
		return
	end
	local nwo, number = string.match(auto, "^(%S+)%s+(%d+)$")
	if nwo == nil or number == nil then
		tern.log.warn("pr-tour: PR_TOUR_AUTOOPEN must be '<owner/repo> <number>', got", auto)
		return
	end
	if cx:new_block("pr-tour.tour", { nwo, number, "", "" }, "tab") == nil then
		tern.log.warn("pr-tour: new_block returned nil (block not available on this window's host?)")
	end
end)
