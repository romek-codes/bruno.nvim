# Installation
### lazy.nvim
```lua
{
  'romek-codes/bruno.nvim',
  dependencies = { 'nvim-lua/plenary.nvim', 'nvim-telescope/telescope.nvim' },
  config = function()
    require('bruno').setup({
      collection_paths = {
        { name = "Main", path = "/path/to/folder/containing/collections/Documents/Bruno" },
      }
    })
  end
}
```

# Usage:

### Run currently opened .bru file
:BrunoRun
### Search through bruno environments
:BrunoEnv
### Search for .bru files
:BrunoSearch

