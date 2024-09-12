local M = {}

-- Store the current environment
M.current_env = nil

-- Require the necessary modules
local Path = require("plenary.path")
local scan = require("plenary.scandir")

-- Store the collection paths
M.collection_paths = {}

-- Function to get all valid Bruno collections
local function get_valid_collections()
  local collections = {}
  for _, collectionInfo in ipairs(M.collection_paths) do
    local collectionPath = collectionInfo.path
    if Path:new(collectionPath):exists() then
      local collection = { name = collectionInfo.name, path = collectionPath }
      table.insert(collections, collection)
    end
  end
  return collections
end

-- Function to create or get a buffer and open it in a new vertical split
local function create_or_get_buffer(name)
  local bufnr = vim.fn.bufnr(name)
  if bufnr == -1 then
    bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(bufnr, name)
  end

  -- Open the buffer in a new vertical split
  vim.cmd('vsplit')
  vim.api.nvim_set_current_buf(bufnr)

  -- Clear the buffer content
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})

  -- Set the buffer filetype to JSON for syntax highlighting
  vim.api.nvim_buf_set_option(bufnr, 'filetype', 'json')

  return bufnr
end

local function bruno_search()
  local collections = get_valid_collections()
  if #collections == 0 then
    print("No valid Bruno collections found.")
    return
  end

  local telescope = require("telescope.builtin")
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  telescope.find_files({
    prompt_title = "Search Bruno Files",
    search_dirs = vim.tbl_map(function(collection) return collection.path end, collections),
    find_command = { "rg", "--files", "--glob", "*.bru" },
    attach_mappings = function(prompt_bufnr, map)
      actions.select_default:replace(function()
        actions.close(prompt_bufnr)
        local selection = action_state.get_selected_entry()
        vim.cmd("edit " .. selection.path)
      end)
      return true
    end,
  })
end

-- Function to find the root of a Bruno collection
local function find_collection_root(file_path)
  for _, collectionInfo in ipairs(M.collection_paths) do
    local collection_path = Path:new(collectionInfo.path)
    if file_path:sub(1, #collectionInfo.path) == collectionInfo.path then
      return collection_path:absolute()
    end
  end
  return nil
end

-- Function to run the current .bru file
local function run_bruno()
  local current_file = vim.fn.expand('%:p')
  if vim.fn.fnamemodify(current_file, ':e') ~= 'bru' then
    print("Current file is not a .bru file")
    return
  end

  -- Find the root of the Bruno collection by looking for bruno.json
  local root_dir = vim.fn.findfile('bruno.json', vim.fn.expand('%:p:h') .. ';')
  if root_dir == '' then
    print("Bruno collection root not found. Please ensure you are in a Bruno collection.")
    return
  end

  -- Extract the directory path from the found bruno.json file
  root_dir = vim.fn.fnamemodify(root_dir, ":p:h")

  -- Change to the Bruno collection root directory
  vim.fn.chdir(root_dir)

  -- Create a temporary file
  local temp_file = vim.fn.system('mktemp'):gsub('\n', '')

  local cmd = string.format("bru run %s -o %s", vim.fn.shellescape(current_file), vim.fn.shellescape(temp_file))
  if M.current_env then
    cmd = cmd .. " --env " .. vim.fn.shellescape(M.current_env)
  end

  local bufnr = create_or_get_buffer("Bruno Output")

  -- Accumulate stdout and stderr output
  local output_lines = {}

  local function on_stdout(_, data, _)
    if data then
      for _, line in ipairs(data) do
        if line ~= "" then
          table.insert(output_lines, line)
        end
      end
    end
  end

  local function on_stderr(_, data, _)
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
        -- Write the captured output directly to the buffer on failure
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "Bruno run failed with the following output:" })
        vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, output_lines)
      else
        -- Read the content of the temporary file and write it to the buffer
        local output = vim.fn.system('cat ' .. vim.fn.shellescape(temp_file))
        local lines = vim.split(output, '\n')
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
      end

      -- Delete the temporary file
      vim.fn.system('rm ' .. vim.fn.shellescape(temp_file))
    end)
  end

  vim.fn.jobstart(cmd, {
    on_stdout = on_stdout,
    on_stderr = on_stderr,
    on_exit = on_exit,
    stdout_buffered = true,
    stderr_buffered = true,
  })
end

-- Function to set the environment using Telescope
local function set_env_telescope()
  local actions = require('telescope.actions')
  local action_state = require('telescope.actions.state')
  local pickers = require('telescope.pickers')
  local finders = require('telescope.finders')
  local conf = require('telescope.config').values

  -- Find the environments directory
  local env_dir = vim.fn.finddir('environments', vim.fn.getcwd() .. ';')
  if env_dir == '' then
    print("Environments directory not found. Please make sure you have an 'environments' directory in your project.")
    return
  end

  -- Get all .bru files in the environments directory
  local env_files = vim.fn.glob(env_dir .. '/*.bru', false, true)
  if #env_files == 0 then
    print("No .env files found in the environments directory.")
    return
  end

  local env_names = vim.tbl_map(function(file)
    return vim.fn.fnamemodify(file, ':t:r')
  end, env_files)

  pickers.new({}, {
    prompt_title = 'Select Bruno Environment',
    finder = finders.new_table {
      results = env_names
    },
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
  }):find()
end

-- Setup function to be called from init.lua
function M.setup(opts)
  opts = opts or {}
  M.collection_paths = opts.collection_paths or {}

  vim.api.nvim_create_user_command('BrunoRun', run_bruno, {})
  vim.api.nvim_create_user_command('BrunoEnv', set_env_telescope, {})
  vim.api.nvim_create_user_command('BrunoSearch', bruno_search, {})
end

return M
