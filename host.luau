--!strict
-- The `tour` block: a pull request's diff as a guided tour. `gh` fetches the
-- diff and PR text, `omp` groups the hunks into steps with what/why, and the
-- result is cached per PR head so reopening never calls the model again. If
-- generation fails the block shows the plain diff by file instead.
-- Keys: n next step, p previous step, r regenerate, o open the PR on GitHub.
-- Launch: pr-tour.tour <owner/repo> <number> [sha] [title]

local tour = require("./tour")
local config = require("./config")
local bins = require("./bins")
local ui = tern.ui

type Phase = "loading" | "generating" | "ready" | "failed"

type State = {
	cx: BlockCx,
	args: { string },
	nwo: string,
	number: string,
	sha: string,
	title: string,
	cfg: config.Config,
	cfg_error: string?,
	phase: Phase,
	error: string?,
	body: string,
	toured: { tour.File },
	not_toured: { tour.Skipped },
	capped: boolean,
	total_files: number,
	steps: { tour.Step },
	source: string,
	step: number,
	by_id: { [string]: tour.HunkRef },
	gen: number, -- bumped on every (re)start; stale callbacks compare and bail
}

local USAGE = "usage: pr-tour.tour <owner/repo> <number> [sha] [title]"
local GH_TIMEOUT_MS = 60 * 1000

local running: { [number]: State } = {}

local function alive(state: State): boolean
	if running[state.cx.pane] ~= state then
		return false
	end
	for _, p in tern.pane.list() do
		if p.pane == state.cx.pane then
			return true
		end
	end
	running[state.cx.pane] = nil
	return false
end

local function first_line(text: string): string
	for line in string.gmatch(text, "[^\r\n]+") do
		if string.match(line, "%S") then
			return line
		end
	end
	return ""
end

local function cache_dir(): string
	local base = tern.getenv("XDG_CACHE_HOME")
	if base == nil or base == "" then
		base = (tern.getenv("HOME") or "/tmp") .. "/.cache"
	end
	return (base :: string) .. "/tern-pr-tour"
end

local function fail(state: State, message: string)
	state.phase = "failed"
	state.error = message
	state.steps = tour.plain_steps(state.toured)
	state.source = "plain diff"
	state.step = 1
	state.cx:render()
end

-- ---------- loading ----------

local function finish_ready(state: State, steps: { tour.Step }, source: string)
	state.steps = steps
	state.source = source
	state.phase = "ready"
	state.step = 1
	state.cx:render()
end

local function generate(state: State, omp: string, meta: tour.Meta, ids: { string }, dir: string, key: string, gen: number)
	state.phase = "generating"
	state.steps = tour.plain_steps(state.toured)
	state.source = "plain diff"
	state.cx:render()
	-- Unique per pane and run: a stale run must never delete a newer run's prompt.
	local prompt_path = dir .. "/prompt-" .. state.cx.pane .. "-" .. gen .. "-" .. key .. ".md"
	local ok, werr = pcall(tern.fs.write, prompt_path, tour.build_prompt(meta, state.toured))
	if not ok then
		fail(state, "could not write prompt: " .. tostring(werr))
		return
	end
	local argv = { omp, "-p", "--no-tools", "--no-session", "--mode", "text", "--model", state.cfg.model, "@" .. prompt_path }
	-- A spawn failure (bad omp_path, no omp) raises instead of calling back.
	local spawned, spawn_err = pcall(tern.process.run, argv, { timeout_ms = math.floor(state.cfg.timeout_s * 1000) }, function(result: ProcessResult, _cx)
		pcall(tern.fs.remove, prompt_path)
		if state.gen ~= gen or not alive(state) then return end
		if result.timed_out then
			fail(state, "tour generation timed out after " .. tostring(state.cfg.timeout_s) .. "s")
			return
		end
		if result.status ~= 0 then
			local why = first_line(result.stderr)
			fail(state, "omp failed: " .. (if why ~= "" then why else "exit " .. tostring(result.status)))
			return
		end
		local steps, err = tour.validate(result.stdout, ids)
		if steps == nil then
			fail(state, err or "model returned invalid JSON")
			return
		end
		local wrote, cerr = pcall(tern.fs.write, dir .. "/" .. key, tern.json.encode({
			model = state.cfg.model,
			steps = steps,
			generated_at = os.time(),
		}))
		if not wrote then
			tern.log.warn("pr-tour: could not write cache:", tostring(cerr))
		end
		finish_ready(state, steps, state.cfg.model)
	end)
	if not spawned then
		pcall(tern.fs.remove, prompt_path)
		fail(state, "omp failed: " .. tostring(spawn_err))
	end
end

local function on_fetched(state: State, omp: string, diff_text: string, view_text: string, force: boolean, gen: number)
	local okv, view = pcall(tern.json.decode, view_text)
	if not okv or type(view) ~= "table" then
		fail(state, "gh: could not read PR details")
		return
	end
	if type(view.headRefOid) == "string" and view.headRefOid ~= "" then
		state.sha = view.headRefOid
	end
	if type(view.title) == "string" and view.title ~= "" then
		state.title = view.title
	end
	state.body = if type(view.body) == "string" then view.body else ""
	local files = tour.parse_diff(diff_text)
	state.total_files = #files
	state.toured, state.not_toured, state.capped = tour.select_toured(files, state.cfg.skip_globs, state.cfg.max_diff_lines)
	local by_id, ids = tour.hunk_index(state.toured)
	state.by_id = by_id
	if #files == 0 then
		fail(state, "this PR has no diff")
		return
	end
	if #ids == 0 then
		state.steps = {}
		state.source = "nothing to tour"
		state.phase = "ready"
		state.cx:render()
		return
	end

	local dir = cache_dir()
	pcall(tern.fs.mkdir, dir)
	local key = tour.cache_key(state.nwo, state.number, state.sha)
	local cache_path = dir .. "/" .. key
	if not force and tern.fs.exists(cache_path) then
		local okc, text = pcall(tern.fs.read, cache_path, 8 * 1024 * 1024)
		if okc then
			-- Re-validate: a changed skip_globs/max_diff_lines changes the hunk set.
			local steps = tour.validate(text, ids)
			if steps ~= nil then
				finish_ready(state, steps, "cached")
				return
			end
		end
	end
	local meta: tour.Meta = {
		nwo = state.nwo,
		number = state.number,
		title = state.title,
		body = state.body,
		commits = tour.commit_messages(view.commits),
	}
	generate(state, omp, meta, ids, dir, key, gen)
end

-- (Re)starts the whole pipeline. Generation happens only from here, which is
-- only called by init and the regenerate action.
local function start(state: State, force: boolean)
	state.gen += 1
	local gen = state.gen
	state.cfg, state.cfg_error = config.load()
	state.toured, state.not_toured, state.capped, state.total_files = {}, {}, false, 0
	state.steps, state.by_id, state.step, state.source = {}, {}, 1, ""
	-- The args come from launch args or a link; never hand an unchecked value to gh.
	if not string.match(state.nwo, "^[%w%-_.]+/[%w%-_.]+$") or not string.match(state.number, "^%d+$") then
		state.phase = "failed"
		state.error = USAGE
		state.cx:render()
		return
	end
	state.phase = "loading"
	state.error = nil
	state.cx:render()
	bins.resolve(state.cfg, function(gh: string, omp: string)
		if state.gen ~= gen or not alive(state) then return end
		local pending = 2
		local diff_res: ProcessResult? = nil
		local view_res: ProcessResult? = nil
		local function both_done()
			pending -= 1
			if pending > 0 then return end
			if state.gen ~= gen or not alive(state) then return end
			for _, r in { diff_res :: ProcessResult, view_res :: ProcessResult } do
				if r.status ~= 0 then
					local why = first_line(r.stderr)
					fail(state, "gh: " .. (if why ~= "" then why else if r.timed_out then "timed out" else "exit " .. tostring(r.status)))
					return
				end
			end
			on_fetched(state, omp, (diff_res :: ProcessResult).stdout, (view_res :: ProcessResult).stdout, force, gen)
		end
		-- A spawn failure (bad gh_path, no gh) raises instead of calling back.
		local function spawn(argv: { string }, store: (r: ProcessResult) -> ()): boolean
			local ok, err = pcall(tern.process.run, argv, { timeout_ms = GH_TIMEOUT_MS }, function(r: ProcessResult, _cx)
				store(r)
				both_done()
			end)
			if not ok then
				state.gen += 1 -- the other gh call's callback is now stale
				fail(state, "gh: " .. tostring(err))
			end
			return ok
		end
		if spawn({ gh, "pr", "diff", state.number, "--repo", state.nwo, "--color=never" }, function(r: ProcessResult) diff_res = r end) then
			spawn({ gh, "pr", "view", state.number, "--repo", state.nwo, "--json", "title,body,commits,headRefOid" }, function(r: ProcessResult) view_res = r end)
		end
	end)
end

-- ---------- view ----------

local function badge(label: string, act: string, tone: string): Node
	local n = ui.badge(label, tone)
	local p: { [string]: any } = n.p or {}
	p.actions = { click = act }
	n.p = p
	return n
end

local function header(state: State): Node
	local spans: { Span | string } = {
		ui.span(state.title ~= "" and state.title or ("PR #" .. state.number), "strong"),
		ui.span("  #" .. state.number, "accent"),
		ui.span("  " .. state.nwo, "muted"),
	}
	if state.sha ~= "" then
		table.insert(spans, ui.span("  " .. tour.short_sha(state.sha), "dim"))
	end
	if state.source == "cached" then
		table.insert(spans, ui.span("  · cached", "muted"))
	elseif state.phase == "ready" and state.source ~= "" and state.source ~= "plain diff" and state.source ~= "nothing to tour" then
		table.insert(spans, ui.span("  · model: " .. state.source, "muted"))
	end
	return ui.text(spans)
end

local function note_lines(state: State): { Node }
	local out: { Node } = {}
	if state.capped then
		local n = #state.toured
		table.insert(out, ui.text({ ui.span(
			"Toured " .. n .. " of " .. (n + #state.not_toured) .. " files (diff over max_diff_lines=" .. tostring(state.cfg.max_diff_lines) .. ")",
			"warning"
		) }))
	end
	if state.cfg_error then
		table.insert(out, ui.text({ ui.span(state.cfg_error, "error") }))
	end
	if state.error then
		table.insert(out, ui.text({ ui.span(state.error, "error") }))
	end
	return out
end

-- `with_path`: false in plain mode, where the card title is already the file path.
local function hunk_nodes(state: State, ids: { string }, with_path: boolean): { Node }
	local out: { Node } = {}
	for _, id in ids do
		local ref = state.by_id[id]
		if ref then
			if with_path then
				table.insert(out, ui.text({ ui.span(ref.file.path, "accent") }))
			end
			table.insert(out, ui.diff(ref.hunk.header .. "\n" .. table.concat(ref.hunk.lines, "\n"), ref.file.path))
		end
	end
	return out
end

local function step_card(state: State, i: number, step: tour.Step): Node
	local children: { Node } = {}
	if step.what ~= "" then
		table.insert(children, ui.text({ ui.span(step.what) }))
	end
	if step.why ~= "" then
		table.insert(children, ui.text({ ui.span(step.why, "muted") }))
	end
	for _, n in hunk_nodes(state, step.hunks, not step.plain) do
		table.insert(children, n)
	end
	local title = if step.plain then step.title else tostring(i) .. ". " .. step.title
	return ui.card({ ui.span(title, "accent") }, children)
end

local function not_toured_section(state: State): Node?
	if #state.not_toured == 0 then
		return nil
	end
	local rows: { Node } = {}
	for _, s in state.not_toured do
		table.insert(rows, ui.text({ ui.span(s.path, "default"), ui.span(" — " .. s.reason, "muted") }))
	end
	return ui.section({ ui.span("Not toured (" .. #state.not_toured .. ")") }, rows)
end

local function main_view(state: State): Node
	local parts: { Node } = { header(state) }
	for _, n in note_lines(state) do table.insert(parts, n) end
	if state.phase == "loading" then
		table.insert(parts, ui.progress(nil, "Fetching the diff with gh…"))
	else
		if state.phase == "generating" then
			table.insert(parts, ui.progress(nil, "Generating tour with " .. state.cfg.model .. "…"))
		end
		local plain = state.phase ~= "ready"
		if plain or (state.steps[1] and state.steps[1].plain) then
			for i, step in state.steps do
				table.insert(parts, step_card(state, i, step))
			end
		elseif #state.steps > 0 then
			local index: { Node } = {}
			for i, step in state.steps do
				local current = i == state.step
				table.insert(index, ui.text({ ui.span((if current then "▸ " else "  ") .. i .. ". " .. step.title, if current then "accent" else "muted") }))
			end
			table.insert(parts, ui.lines(index))
			local cur = state.steps[state.step]
			if cur then
				table.insert(parts, step_card(state, state.step, cur))
			end
		end
		local skipped = not_toured_section(state)
		if skipped then table.insert(parts, skipped) end
	end
	-- A new id per phase/step: the scroll offset of the previous content otherwise
	-- survives into the next step and leaves the view mid-card.
	local node = ui.col(parts)
	local p: { [string]: any } = node.p or {}
	p.id = "tour-" .. state.gen .. "-" .. state.phase .. "-" .. state.step
	node.p = p
	return node
end

local function dock_view(state: State): Node
	local status: { Span | string } = {}
	if state.phase == "ready" and #state.steps > 0 and not state.steps[1].plain then
		table.insert(status, ui.span("step " .. state.step .. " of " .. #state.steps, "strong"))
		table.insert(status, ui.span("   "))
	end
	table.insert(status, ui.span("n next   p prev   r regenerate   o open PR", "dim"))
	return ui.col({
		ui.text(status),
		ui.row({
			badge("Prev", "prev", "muted"),
			badge("Next", "next", "accent"),
			badge("Regenerate", "regen", "muted"),
			badge("Open PR", "open", "muted"),
		}),
	})
end

-- ---------- actions ----------

local function move(state: State, delta: number): boolean
	local target = math.max(1, math.min(#state.steps, state.step + delta))
	if #state.steps == 0 or state.steps[1].plain or target == state.step then
		return false
	end
	state.step = target
	return true
end

local function act(state: State, name: string): boolean
	if name == "next" then
		return move(state, 1)
	elseif name == "prev" then
		return move(state, -1)
	elseif name == "regen" then
		if state.phase == "loading" or state.phase == "generating" then
			return true
		end
		start(state, true)
		return true
	elseif name == "open" then
		state.cx:open("https://github.com/" .. state.nwo .. "/pull/" .. state.number)
		return true
	end
	return false
end

-- ---------- block ----------

tern.block.define("tour", {
	init = function(cx: BlockCx, args: { string }, saved: any): State
		local a = args
		if #a == 0 and type(saved) == "table" then
			a = saved :: { string }
		end
		local nwo = a[1] or ""
		local number = a[2] or ""
		local cfg, cfg_error = config.load()
		local state: State = {
			cx = cx, args = a, nwo = nwo, number = number, sha = a[3] or "", title = a[4] or "",
			cfg = cfg, cfg_error = cfg_error, phase = "loading", error = nil, body = "",
			toured = {}, not_toured = {}, capped = false, total_files = 0, steps = {}, source = "",
			step = 1, by_id = {}, gen = 0,
		}
		running[cx.pane] = state
		start(state, false)
		return state
	end,

	title = function(state: State): string?
		return "tour #" .. state.number
	end,

	view = function(state: State, _cx: BlockCx): BlockView
		return { main = main_view(state), dock = dock_view(state) }
	end,

	key = function(state: State, key: Key, _cx: BlockCx): boolean?
		if key.ctrl or key.alt or key.meta then
			return false
		end
		local k = key.text or key.name
		if k == "n" then
			return act(state, "next")
		elseif k == "p" then
			return act(state, "prev")
		elseif k == "r" then
			return act(state, "regen")
		elseif k == "o" then
			return act(state, "open")
		end
		return false
	end,

	event = function(state: State, ev: UiEvent, cx: BlockCx)
		if ev.ev ~= "action" then
			return
		end
		if act(state, ev.act or "") then
			cx:render()
		end
	end,

	save = function(state: State): any
		return state.args
	end,
})

return nil
