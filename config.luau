--!strict
-- User-editable config for the pr-tour plugin. Read from
-- `tern.plugin.data .. "/config.json"` whenever a tour is (re)started. A
-- missing file is created from defaults; invalid JSON falls back to defaults
-- with an error surfaced in the block header.

local M = {}

export type Config = {
	model: string,
	timeout_s: number,
	max_diff_lines: number,
	skip_globs: { string },
	gh_path: string,
	omp_path: string,
}

local function default_globs(): { string }
	return {
		"*.lock", "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "go.sum",
		"*.min.js", "*.min.css", "*.map", "*.snap", "**/generated/**",
		"*.g.cs", "*.Designer.cs", "*.pb.go", "dist/**",
	}
end

function M.defaults(): Config
	return {
		model = "@smol",
		timeout_s = 90,
		max_diff_lines = 3000,
		skip_globs = default_globs(),
		gh_path = "",
		omp_path = "",
	}
end

local function str_or(data: any, key: string, default: string): string
	local v = data[key]
	return if type(v) == "string" then v else default
end

local function pos_num_or(data: any, key: string, default: number): number
	local v = data[key]
	if type(v) ~= "number" or v ~= v or v <= 0 then
		return default
	end
	return v
end

-- A list key is used only when it is a JSON array whose every item is a string.
local function list_or(data: any, key: string, default: { string }): { string }
	local v = data[key]
	if type(v) ~= "table" then
		return { table.unpack(default) }
	end
	local out: { string } = {}
	local n = #v
	for k, item in v do
		if type(k) ~= "number" or k % 1 ~= 0 or k < 1 or k > n or type(item) ~= "string" then
			return { table.unpack(default) }
		end
		out[k] = item
	end
	return out
end

-- Pure part of load: from a decoded JSON value to a Config. Per-key fallback.
function M.from_data(data: any): Config
	local d = M.defaults()
	return {
		model = (function(): string
			local m = str_or(data, "model", d.model)
			return if m == "" then d.model else m
		end)(),
		timeout_s = pos_num_or(data, "timeout_s", d.timeout_s),
		max_diff_lines = pos_num_or(data, "max_diff_lines", d.max_diff_lines),
		skip_globs = list_or(data, "skip_globs", d.skip_globs),
		gh_path = str_or(data, "gh_path", d.gh_path),
		omp_path = str_or(data, "omp_path", d.omp_path),
	}
end

-- Returns (config, error?). A missing file is written from defaults (no error).
-- Invalid JSON returns defaults plus "config.json: <reason>".
function M.load(): (Config, string?)
	local path = tern.plugin.data .. "/config.json"
	if not tern.fs.exists(path) then
		pcall(tern.fs.write, path, tern.json.encode(M.defaults(), true))
		return M.defaults(), nil
	end
	local ok, text = pcall(tern.fs.read, path, 1048576)
	if not ok or not text then
		return M.defaults(), "config.json: " .. tostring(text)
	end
	local ok2, data = pcall(tern.json.decode, text)
	if not ok2 then
		return M.defaults(), "config.json: " .. tostring(data)
	end
	if type(data) ~= "table" then
		return M.defaults(), "config.json: not a JSON object"
	end
	return M.from_data(data), nil
end

return M
