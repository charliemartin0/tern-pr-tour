--!strict
-- Resolves `gh` and `omp` to absolute paths: the configured path when set,
-- otherwise `command -v <tool>` through a login shell (the daemon's PATH is
-- often thinner than the user's), otherwise the bare name. Results are cached
-- per (tool, configured path) for the life of the VM.

local M = {}

local cache: { [string]: string } = {}

local function resolve_one(tool: string, cfg_path: string, done: (path: string) -> ())
	if cfg_path ~= "" then
		done(cfg_path)
		return
	end
	local key = tool
	local hit = cache[key]
	if hit then
		done(hit)
		return
	end
	local shell = tern.getenv("SHELL") or "/bin/sh"
	tern.process.run({ shell, "-lc", "command -v " .. tool }, { timeout_ms = 5000 }, function(result: ProcessResult, _cx)
		local found = tool
		if result.status == 0 then
			-- A login shell may print banners first: take the last absolute-path line.
			for line in string.gmatch(result.stdout, "[^\r\n]+") do
				if string.sub(line, 1, 1) == "/" then
					found = line
				end
			end
		end
		cache[key] = found
		done(found)
	end)
end

function M.resolve(cfg: { gh_path: string, omp_path: string }, done: (gh: string, omp: string) -> ())
	resolve_one("gh", cfg.gh_path, function(gh: string)
		resolve_one("omp", cfg.omp_path, function(omp: string)
			done(gh, omp)
		end)
	end)
end

return M
