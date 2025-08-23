local M = {}

-- Require the necessary modules
local Path = require("plenary.path")
local telescope = require("telescope.builtin")
local actions = require("telescope.actions")
local action_state = require("telescope.actions.state")
local pickers = require("telescope.pickers")
local finders = require("telescope.finders")
local conf = require("telescope.config").values

-- Configuration
M.current_env = nil
vim.g.last_bru_file = nil
M.last_raw_output = nil

M.show_formatted_output = true
M.suppress_formatting_errors = false
M.picker = "telescope"

local search_pickers = {
	["fzf-lua"] = function(search_dirs, prompt)
		local fzf = require("fzf-lua")
		fzf.live_grep({
			prompt = prompt .. ": ",
			search_paths = search_dirs,
			rg_opts = "--column --line-number --no-heading --color=always --smart-case --glob=*.bru",
			actions = {
				["default"] = function(selected)
					local raw = selected[1]
					-- Remove nerd font icon and any whitespace from the beginning
					local line = raw:gsub("^[^~/]*", "")
					local file = line:match("^([^:]+)")
					local expanded_path = vim.fs.normalize(vim.fn.expand(file))
					vim.cmd("edit " .. vim.fn.fnameescape(expanded_path))
				end,
			},
		})
	end,

	["snacks"] = function(search_dirs, prompt)
		local snacks = require("snacks")
		snacks.picker.grep({
			prompt = prompt .. ": ",
			glob = "*.bru",
			dirs = search_dirs,
			on_select = function(item)
				vim.cmd("edit " .. item.file)
			end,
		})
	end,

	["telescope"] = function(search_dirs, prompt)
		telescope.live_grep({
			prompt_title = prompt,
			search_dirs = search_dirs,
			glob_pattern = "*.bru",
			attach_mappings = function(prompt_bufnr, map)
				actions.select_default:replace(function()
					actions.close(prompt_bufnr)
					local selection = action_state.get_selected_entry()
					vim.cmd("edit " .. selection.filename)
				end)
				return true
			end,
		})
	end,
}

local env_pickers = {
	["fzf-lua"] = function(env_names, prompt)
		local fzf = require("fzf-lua")
		fzf.fzf_exec(env_names, {
			prompt = prompt .. ": ",
			actions = {
				["default"] = function(selected)
					if selected and selected[1] then
						M.current_env = selected[1]
						print("Bruno environment set to: " .. M.current_env)
					end
				end,
			},
		})
	end,

	["snacks"] = function(env_names, prompt)
		local snacks = require("snacks")

		snacks.picker.select(env_names, {
			prompt = prompt .. ": ",
		}, function(selected_item, idx)
			if selected_item then
				M.current_env = selected_item
				print("Bruno environment set to: " .. M.current_env)
			end
		end)
	end,

	["telescope"] = function(env_names, prompt)
		pickers
			.new({}, {
				prompt_title = prompt,
				finder = finders.new_table({ results = env_names }),
				sorter = conf.generic_sorter({}),
				attach_mappings = function(prompt_bufnr, map)
					actions.select_default:replace(function()
						actions.close(prompt_bufnr)
						local selection = action_state.get_selected_entry()
						M.current_env = selection[1]
						print("Bruno environment set to: " .. M.current_env)
					end)
					return true
				end,
			})
			:find()
	end,
}

-- Helper Functions
local function get_valid_collections()
	return vim.tbl_filter(function(collectionInfo)
		return Path:new(collectionInfo.path):exists()
	end, M.collection_paths)
end

local function is_not_nil(value)
	return value ~= nil and value ~= vim.NIL
end

local function set_buffer_properties(bufnr, name)
	vim.api.nvim_buf_set_name(bufnr, name)
	vim.api.nvim_buf_set_option(bufnr, "buftype", "nofile")
end

local function create_or_get_sidebar()
	local sidebar_name = "Bruno Output"
	local existing_bufnr = vim.fn.bufnr(sidebar_name)

	-- Check if sidebar already exists and is visible
	for _, winid in ipairs(vim.api.nvim_list_wins()) do
		local bufnr = vim.api.nvim_win_get_buf(winid)
		if vim.api.nvim_buf_get_name(bufnr):match(sidebar_name .. "$") then
			vim.api.nvim_set_current_win(winid)
			vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})
			return bufnr
		end
	end

	-- Create new sidebar
	vim.cmd("botright vsplit")
	vim.cmd("vertical resize 80")

	local bufnr
	if existing_bufnr ~= -1 then
		bufnr = existing_bufnr
		vim.api.nvim_set_current_buf(bufnr)
	else
		bufnr = vim.api.nvim_create_buf(false, true)
		set_buffer_properties(bufnr, sidebar_name)
		vim.api.nvim_set_current_buf(bufnr)
	end

	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})
	return bufnr
end

-- Main Functions
local function bruno_search()
	local collections = get_valid_collections()
	if #collections == 0 then
		print("No valid Bruno collections found.")
		return
	end

	local search_dirs = vim.tbl_map(function(collection)
		return collection.path
	end, collections)

	local picker_fn = search_pickers[M.picker] or search_pickers["telescope"]
	picker_fn(search_dirs, "Bruno Files")
end

local function pretty_json_str(s, indent)
	indent = indent or "  "
	local out, level, in_str, esc = {}, 0, false, false
	for i = 1, #s do
		local ch = s:sub(i, i)
		if in_str then
			out[#out + 1] = ch
			if esc then
				esc = false
			elseif ch == "\\" then
				esc = true
			elseif ch == '"' then
				in_str = false
			end
		else
			if ch == '"' then
				in_str = true
				out[#out + 1] = ch
			elseif ch == "{" or ch == "[" then
				out[#out + 1] = ch .. "\n" .. string.rep(indent, level + 1)
				level = level + 1
			elseif ch == "}" or ch == "]" then
				level = level - 1
				out[#out + 1] = "\n" .. string.rep(indent, level) .. ch
			elseif ch == "," then
				out[#out + 1] = ch .. "\n" .. string.rep(indent, level)
			elseif ch == ":" then
				out[#out + 1] = ": "
			elseif not ch:match("%s") then
				out[#out + 1] = ch
			end
		end
	end
	return table.concat(out)
end

local function format_bruno_output(raw_output)
	local ok, data = pcall(vim.json.decode, raw_output)
	if not ok or not data.results or #data.results == 0 then
		return vim.split(raw_output, "\n")
	end

	local formatted = {}
	local result = data.results[1]

	table.insert(formatted, "REQUEST DETAILS:")
	table.insert(formatted, string.format("  Method: %s", result.request.method))
	table.insert(formatted, string.format("  URL: %s", result.request.url))
	table.insert(formatted, "")

	table.insert(formatted, "RESPONSE:")
	if is_not_nil(result.error) then
		table.insert(formatted, string.format("  Error: %s", result.error))
	end

	local status_text = is_not_nil(result.response.statusText) and " " .. tostring(result.response.statusText) or ""

	table.insert(
		formatted,
		string.format("  Status: %s%s", tostring(result.response.status or "(no status)"), status_text)
	)

	table.insert(formatted, string.format("  Response Time: %dms", result.response.responseTime))
	table.insert(formatted, "")

	if is_not_nil(result.response.data) then
		table.insert(formatted, "RESPONSE DATA:")
		table.insert(formatted, "```json")

		local data_content = result.response.data == null and "null"
			or pretty_json_str(vim.json.encode(result.response.data))

		for _, line in ipairs(vim.split(data_content, "\n", { trimempty = true })) do
			table.insert(formatted, line)
		end

		table.insert(formatted, "```")
	end

	return formatted
end

local function get_current_bru_file()
	local current_file = vim.fn.expand("%:p")
	if vim.fn.fnamemodify(current_file, ":e") == "bru" then
		vim.g.last_bru_file = current_file
		return current_file
	end

	local last_bru = vim.g.last_bru_file
	if last_bru and vim.fn.filereadable(last_bru) == 1 then
		return last_bru
	end

	print("Current file is not a .bru file and no valid last .bru file found")
	return nil
end

local function run_bruno()
	local current_file = get_current_bru_file()
	if not current_file then
		return
	end

	local root_dir = vim.fn.findfile("bruno.json", vim.fn.fnamemodify(current_file, ":p:h") .. ";")
	if root_dir == "" then
		print("Bruno collection root not found. Please ensure the .bru file is in a Bruno collection.")
		return
	end

	root_dir = vim.fn.fnamemodify(root_dir, ":p:h")
	local temp_file = vim.fn.system("mktemp"):gsub("\n", "")
	local cmd = string.format(
		"cd %s && bru run %s -o %s",
		vim.fn.shellescape(root_dir),
		vim.fn.shellescape(current_file),
		vim.fn.shellescape(temp_file)
	)

	if M.current_env then
		cmd = cmd .. " --env " .. vim.fn.shellescape(M.current_env)
	end

	local bufnr = create_or_get_sidebar()
	vim.api.nvim_buf_set_option(bufnr, "filetype", "text")
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "Running Bruno request..." })
	local output_lines = {}

	local function append_output(_, data, _)
		if data then
			for _, line in ipairs(data) do
				if line ~= "" then
					table.insert(output_lines, line)
				end
			end
		end
	end

	local function on_exit(_, exit_code)
		vim.schedule(function()
			if exit_code ~= 0 and exit_code ~= 1 then
				vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "Bruno run failed with the following output:" })
				vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, output_lines)
			else
				local output = vim.fn.system("cat " .. vim.fn.shellescape(temp_file))
				M.last_raw_output = output
				local lines

				if M.show_formatted_output then
					vim.api.nvim_buf_set_option(bufnr, "filetype", "text")
					local ok, result = pcall(format_bruno_output, output)
					if ok then
						lines = result
					else
						lines = vim.split(output, "\n")
						if not M.suppress_formatting_errors then
							vim.notify(
								string.format(
									"Failed to format output (%s), falling back to default formatting",
									result or "unknown error"
								),
								vim.log.levels.WARN,
								{ title = "Output Formatting" }
							)
						end
					end
				else
					vim.api.nvim_buf_set_option(bufnr, "filetype", "json")
					lines = vim.split(output, "\n")
				end

				vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
			end
			vim.fn.system("rm " .. vim.fn.shellescape(temp_file))
		end)
	end

	vim.fn.jobstart(cmd, {
		on_stdout = append_output,
		on_stderr = append_output,
		on_exit = on_exit,
		stdout_buffered = true,
		stderr_buffered = true,
	})
end

local function toggle_output_format()
	M.show_formatted_output = not M.show_formatted_output
	-- Seems unnecessary
	-- print("Bruno formatted output: " .. (M.show_formatted_output and "enabled" or "disabled"))

	if M.last_raw_output then
		local bufnr = vim.fn.bufnr("Bruno Output")
		if bufnr ~= -1 then
			local lines
			if M.show_formatted_output then
				vim.api.nvim_buf_set_option(bufnr, "filetype", "text")
				local ok, result = pcall(format_bruno_output, M.last_raw_output)
				lines = ok and result or vim.split(M.last_raw_output, "\n")
			else
				vim.api.nvim_buf_set_option(bufnr, "filetype", "json")
				lines = vim.split(M.last_raw_output, "\n")
			end
			vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
		end
	end
end

local function find_environments_dir()
	local search_dir = vim.fn.expand("%:p:h")
	local env_dir = vim.fn.finddir("environments", search_dir .. ";")

	if env_dir == "" and vim.g.last_bru_file then
		search_dir = vim.fn.fnamemodify(vim.g.last_bru_file, ":p:h")
		env_dir = vim.fn.finddir("environments", search_dir .. ";")
	end

	return env_dir
end

local function set_env_picker()
	local env_dir = find_environments_dir()
	if env_dir == "" then
		print(
			"Environments directory not found. You need to run BrunoRun on a .bru file first, or have the current buffer be a .bru file."
		)
		return
	end

	local env_files = vim.fn.glob(env_dir .. "/*.bru", false, true)
	if #env_files == 0 then
		print("No .bru files found in the environments directory.")
		return
	end

	local env_names = vim.tbl_map(function(file)
		return vim.fn.fnamemodify(file, ":t:r")
	end, env_files)

	local picker_fn = env_pickers[M.picker] or env_pickers["telescope"]
	picker_fn(env_names, "Bruno Environments")
end

function M.setup(opts)
	opts = opts or {}
	M.collection_paths = opts.collection_paths or {}

	if opts.show_formatted_output ~= nil then
		M.show_formatted_output = opts.show_formatted_output
	end

	if opts.suppress_formatting_errors ~= nil then
		M.suppress_formatting_errors = opts.suppress_formatting_errors
	end

	if opts.picker ~= nil then
		M.picker = opts.picker
	end

	vim.api.nvim_create_user_command("BrunoRun", run_bruno, {})
	vim.api.nvim_create_user_command("BrunoEnv", set_env_picker, {})
	vim.api.nvim_create_user_command("BrunoSearch", bruno_search, {})
	vim.api.nvim_create_user_command("BrunoToggleFormat", toggle_output_format, {})
end

return M
