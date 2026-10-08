--!strict
-- Pure logic for pr-tour: diff parsing, file filtering, the model prompt and
-- validation of the model's answer. Touches `tern` only through `M.decode`,
-- so it is unit-testable with a JSON shim (test/test.luau).

local M = {}

export type Hunk = { id: string, header: string, lines: { string }, old_start: number, new_start: number }
export type File = { path: string, old_path: string?, binary: boolean, hunks: { Hunk }, header: { string } }
export type Step = { title: string, what: string, why: string, hunks: { string }, other: boolean?, plain: boolean? }
export type Meta = { nwo: string, number: string, title: string, body: string, commits: { string } }
export type Problems = { unknown: { string }, duplicates: { string }, missing: { string } }
export type Skipped = { path: string, reason: string }

M.NO_WHY = "why: not stated in the PR"

-- JSON decoder; a field so unit tests can run without `tern` (Luau CLI).
M.decode = function(text: string): any
	return tern.json.decode(text)
end

-- ---------- diff parsing ----------

local ESCAPES: { [string]: string } = { n = "\n", t = "\t", r = "\r", ['"'] = '"', ["\\"] = "\\" }

-- Decodes git's C-style quoting: \303\251 octal bytes and \n \t \" \\.
local function unescape(s: string): string
	local out: { string } = {}
	local i, n = 1, #s
	while i <= n do
		local c = string.sub(s, i, i)
		if c == "\\" and i < n then
			local oct = string.match(s, "^[0-3][0-7][0-7]", i + 1)
			if oct then
				table.insert(out, string.char(tonumber(oct, 8) or 63))
				i += 4
			else
				local e = string.sub(s, i + 1, i + 1)
				table.insert(out, ESCAPES[e] or e)
				i += 2
			end
		else
			table.insert(out, c)
			i += 1
		end
	end
	return table.concat(out)
end

-- Paths of a `diff --git` line. Git quotes names with non-ASCII bytes, quotes
-- or tabs: `diff --git "a/caf\303\251" "b/caf\303\251"`.
local function git_header(line: string): (string?, string?)
	local a, b = string.match(line, '^diff %-%-git "?a/(.-)"? "?b/(.-)"?$')
	if a and b and string.find(line, '"', 1, true) then
		return unescape(a), unescape(b)
	end
	return a, b
end

-- Path of a `--- ` / `+++ ` line: "a/x" or "b/x", possibly quoted, with a
-- trailing TAB when the path contains a space. nil for /dev/null.
local function marker_path(line: string): string?
	local rest = string.sub(line, 5)
	rest = string.gsub(rest, "\t.*$", "")
	if rest == "/dev/null" then
		return nil
	end
	if string.sub(rest, 1, 1) == '"' and string.sub(rest, -1) == '"' then
		rest = unescape(string.sub(rest, 2, -2))
	end
	return string.match(rest, "^[ab]/(.+)$")
end

-- Parses `git diff` / `gh pr diff` output. Hunk ids are "f<file>h<hunk>",
-- 1-based in diff order, so the same diff always yields the same ids.
function M.parse_diff(text: string): { File }
	local files: { File } = {}
	local cur: File? = nil
	local hunk: Hunk? = nil
	local lines = string.split(text, "\n")
	if #lines > 0 and lines[#lines] == "" then
		table.remove(lines)
	end
	for _, line in lines do
		local a, b = git_header(line)
		if a and b then
			cur = { path = b, old_path = if a ~= b then a else nil, binary = false, hunks = {}, header = { line } }
			table.insert(files, cur :: File)
			hunk = nil
		elseif cur then
			local f = cur :: File
			local os_, ns = string.match(line, "^@@ %-(%d+),?%d* %+(%d+),?%d* @@")
			if os_ and ns then
				local h: Hunk = {
					id = "f" .. #files .. "h" .. (#f.hunks + 1),
					header = line,
					lines = {},
					old_start = tonumber(os_) or 0,
					new_start = tonumber(ns) or 0,
				}
				table.insert(f.hunks, h)
				hunk = h
			elseif hunk and #f.hunks > 0 then
				-- Inside a hunk every line is content, including "--- x" deletions.
				table.insert((hunk :: Hunk).lines, line)
			else
				table.insert(f.header, line)
				if string.match(line, "^Binary files .* differ$") or line == "GIT binary patch" then
					f.binary = true
				elseif string.sub(line, 1, 4) == "+++ " then
					local p = marker_path(line)
					if p then f.path = p end
				elseif string.sub(line, 1, 4) == "--- " then
					local p = marker_path(line)
					if p and p ~= f.path then f.old_path = p end
				end
			end
		end
	end
	return files
end

-- ---------- filtering ----------

local function glob_to_pattern(glob: string): string
	local out = { "^" }
	local i = 1
	local n = #glob
	while i <= n do
		local c = string.sub(glob, i, i)
		if c == "*" then
			if string.sub(glob, i + 1, i + 1) == "*" then
				table.insert(out, ".*")
				i += 1
			else
				table.insert(out, "[^/]*")
			end
		elseif c == "?" then
			table.insert(out, "[^/]")
		elseif string.find(c, "^[%^%$%(%)%%%.%[%]%+%-]$") then
			table.insert(out, "%" .. c)
		else
			table.insert(out, c)
		end
		i += 1
	end
	table.insert(out, "$")
	return table.concat(out)
end

-- Anchored glob match against the full path or the basename. `**/x` also
-- matches a top-level `x`.
function M.glob_match(glob: string, path: string): boolean
	local pat = glob_to_pattern(glob)
	if string.find(path, pat) ~= nil then
		return true
	end
	local base = string.match(path, "([^/]+)$") or path
	if base ~= path and string.find(base, pat) ~= nil then
		return true
	end
	if string.sub(glob, 1, 3) == "**/" then
		return M.glob_match(string.sub(glob, 4), path)
	end
	return false
end

-- Why a file is left out of the tour, or nil to tour it.
function M.skip_reason(file: File, globs: { string }): string?
	if file.binary then
		return "binary"
	end
	for _, g in globs do
		if M.glob_match(g, file.path) then
			return "lockfile/generated (glob " .. g .. ")"
		end
	end
	local first = file.hunks[1]
	if first == nil then
		return "no textual changes"
	end
	for _, l in first.lines do
		if string.sub(l, 1, 1) == "+" and (string.find(l, "@generated", 1, true) or string.find(l, "<auto-generated", 1, true)) then
			return "generated"
		end
	end
	return nil
end

local function file_lines(f: File): number
	local n = 0
	for _, h in f.hunks do
		n += 1 + #h.lines
	end
	return n
end

-- Splits files into toured / not toured. Files are added in diff order while
-- the running line total stays within `max_lines`; the first touring file is
-- always included even if it alone is over.
function M.select_toured(files: { File }, globs: { string }, max_lines: number): ({ File }, { Skipped }, boolean)
	local toured: { File } = {}
	local not_toured: { Skipped } = {}
	local capped = false
	local total = 0
	for _, f in files do
		local reason = M.skip_reason(f, globs)
		if reason then
			table.insert(not_toured, { path = f.path, reason = reason })
		else
			local n = file_lines(f)
			if #toured == 0 or total + n <= max_lines then
				total += n
				table.insert(toured, f)
			else
				capped = true
				table.insert(not_toured, { path = f.path, reason = "over max_diff_lines" })
			end
		end
	end
	return toured, not_toured, capped
end

-- ---------- cache ----------

function M.cache_key(nwo: string, number: string, sha: string): string
	local k = string.gsub(nwo .. "__" .. number .. "__" .. sha, "[^%w%-_.]", "_")
	return k .. ".json"
end

-- ---------- hunk helpers ----------

export type HunkRef = { file: File, hunk: Hunk }

function M.hunk_index(toured: { File }): ({ [string]: HunkRef }, { string })
	local by_id: { [string]: HunkRef } = {}
	local ids: { string } = {}
	for _, f in toured do
		for _, h in f.hunks do
			by_id[h.id] = { file = f, hunk = h }
			table.insert(ids, h.id)
		end
	end
	return by_id, ids
end

-- ---------- prompt ----------

-- Formats `gh pr view --json commits` entries as "headline\nbody" strings.
function M.commit_messages(commits: any): { string }
	local out: { string } = {}
	if type(commits) ~= "table" then
		return out
	end
	for _, c in commits do
		if type(c) == "table" then
			local head = if type(c.messageHeadline) == "string" then c.messageHeadline else ""
			local body = if type(c.messageBody) == "string" then c.messageBody else ""
			local msg = if body ~= "" then head .. "\n" .. body else head
			if msg ~= "" then
				table.insert(out, msg)
			end
		end
	end
	return out
end

function M.build_prompt(meta: Meta, toured: { File }): string
	local p: { string } = {
		"You are writing a guided tour of a pull request's diff for a reviewer.",
		"",
		"Requirements:",
		"- Group related hunks, across files, into logical steps in reading order: the core change first, then callers, then tests and config.",
		"- Each step has a `title`, a `what` and a `why`. `what` and `why` are one or two sentences each.",
		"- `what` says what the step changes. `why` says the intent, and ONLY from the PR title, body, commit messages or the code itself. Never invent intent. If the reason is not stated, `why` must be exactly: \"" .. M.NO_WHY .. "\"",
		"- Every hunk id below must appear in exactly one step, exactly once.",
		"- Output ONLY JSON, no prose and no code fences, in this shape:",
		"  {\"steps\":[{\"title\":string,\"what\":string,\"why\":string,\"hunks\":[hunk_id,...]}]}",
		"",
		"## Pull request " .. meta.nwo .. "#" .. meta.number,
		"Title: " .. meta.title,
		"",
		"Body:",
		if meta.body ~= "" then meta.body else "(empty)",
		"",
		"Commit messages:",
	}
	if #meta.commits == 0 then
		table.insert(p, "(none)")
	end
	for _, c in meta.commits do
		table.insert(p, "- " .. string.gsub(c, "\n", "\n  "))
	end
	table.insert(p, "")
	table.insert(p, "## Hunks")
	for _, f in toured do
		for _, h in f.hunks do
			table.insert(p, "### " .. h.id .. " " .. f.path)
			table.insert(p, h.header)
			for _, l in h.lines do
				table.insert(p, l)
			end
			table.insert(p, "")
		end
	end
	return table.concat(p, "\n")
end

-- ---------- validation ----------

-- Parses and repairs the model's answer so that every toured hunk id appears
-- exactly once. Unknown ids are dropped, repeats keep their first step, and
-- ids the model forgot land in a final "Other changes" step. Returns
-- (steps, nil, problems) or (nil, error, problems) when there is no usable JSON
-- or no step with a known hunk id.
function M.validate(raw: string, toured_ids: { string }): ({ Step }?, string?, Problems)
	local problems: Problems = { unknown = {}, duplicates = {}, missing = {} }
	local first = string.find(raw, "{", 1, true)
	local last: any = string.match(raw, "^.*()}") -- a position, which the string.match typing misses
	if first == nil or last == nil or last < first then
		return nil, "model returned invalid JSON: no JSON object found", problems
	end
	local ok, data = pcall(M.decode, string.sub(raw, first, last))
	if not ok then
		return nil, "model returned invalid JSON: " .. tostring(data), problems
	end
	if type(data) ~= "table" or type(data.steps) ~= "table" then
		return nil, "model returned invalid JSON: missing `steps` array", problems
	end
	local known: { [string]: boolean } = {}
	for _, id in toured_ids do known[id] = true end
	local used: { [string]: boolean } = {}
	local steps: { Step } = {}
	for _, s in data.steps do
		if type(s) == "table" and type(s.title) == "string" and s.title ~= "" then
			local ids: { string } = {}
			if type(s.hunks) == "table" then
				for _, id in s.hunks do
					if type(id) == "string" then
						if not known[id] then
							table.insert(problems.unknown, id)
						elseif used[id] then
							table.insert(problems.duplicates, id)
						else
							used[id] = true
							table.insert(ids, id)
						end
					end
				end
			end
			if #ids > 0 then
				-- `other` marks a synthetic "Other changes" step coming back from the cache.
				local is_other = s.other == true
				local why = if type(s.why) == "string" and s.why ~= "" then s.why elseif is_other then "" else M.NO_WHY
				table.insert(steps, {
					title = s.title,
					what = if type(s.what) == "string" then s.what else "",
					why = why,
					hunks = ids,
					other = if is_other then true else nil,
				})
			end
		end
	end
	for _, id in toured_ids do
		if not used[id] then table.insert(problems.missing, id) end
	end
	if #steps == 0 then
		-- Every hunk would land in "Other changes": that is a plain diff
		-- dressed up as a tour, so report it as a failure instead.
		return nil, "model returned no usable steps (no known hunk ids)", problems
	end
	if #problems.missing > 0 then
		local tail = steps[#steps]
		if tail and tail.other then
			for _, id in problems.missing do table.insert(tail.hunks, id) end
		else
			table.insert(steps, { title = "Other changes", what = "", why = "", hunks = { table.unpack(problems.missing) }, other = true })
		end
	end
	return steps, nil, problems
end

-- Fallback when there is no tour: one step per file, no what/why.
function M.plain_steps(toured: { File }): { Step }
	local steps: { Step } = {}
	for _, f in toured do
		local ids: { string } = {}
		for _, h in f.hunks do table.insert(ids, h.id) end
		table.insert(steps, { title = f.path, what = "", why = "", hunks = ids, plain = true })
	end
	return steps
end

function M.short_sha(sha: string): string
	return string.sub(sha, 1, 7)
end

return M
