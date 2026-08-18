# bex.vim

A simple ID-tracked file browser for Vim. The name **Bex** stands for **Better Explorer**.

`bex.vim` loads a directory listing into a standard text buffer where each line is prefixed with a visible tracking ID (`/xxxx `). You can modify, delete, or create lines using native Vim commands. Saving the buffer with `:w` commits those changes to disk.

![bex.vim demo](images/demo.png)

## Features

* Support for rendering images with chafa. (Works well with true color)

## Usage

* Open explorer

```
:Bex [OPTION]... [PATH]
```

* Options

```
-r
    reload buffers
```

## Configuration

Moving Bex header to top/bottom can be set with:

```vim
let g:bex_header_at_bottom = 1
```

Disable netrw:
```vim
let g:bex_disable_netrw = 1
```

To change highlight groups you simply apply a valid token, you can find token list here [Color Tokens](#color-tokens)

```vim
let g:bex_hi_BexHeader          = 'br_yellow'
let g:bex_hi_BexInfo            = 'br_black'
let g:bex_hi_BexDir             = 'br_yellow'
let g:bex_hi_BexFile            = 'br_white'
let g:bex_hi_BexHiddenDir       = 'yellow'
let g:bex_hi_BexHiddenFile      = 'white'
let g:bex_hi_BexVisible         = 'br_green'
let g:bex_hi_BexHidden          = 'br_red'
let g:bex_hi_BexID              = 'br_black'
let g:bex_hi_BexHiddenID        = 'br_black'
let g:bex_hi_BexExec            = 'br_green'
let g:bex_hi_BexSymlink         = 'br_blue'

let g:bex_hi_BexChangesDir      = 'br_yellow'
let g:bex_hi_BexChangesDel      = 'br_red'
let g:bex_hi_BexChangesAdd      = 'br_green'
let g:bex_hi_BexChangesRename   = 'br_cyan'
let g:bex_hi_BexChangesMoveFrom = 'br_black'
let g:bex_hi_BexChangesMoveTo   = 'br_magenta'
let g:bex_hi_BexChangesCopy     = 'br_blue'
let g:bex_hi_BexDotfilesOn      = 'br_green'
let g:bex_hi_BexDotfilesOff     = 'br_red'
let g:bex_hi_BexModified        = 'br_blue'
```

You can change gui colors here for example let g:bex_gui_black = '#000000':

```vim
let g:bex_gui_black      = 'Black'
let g:bex_gui_red        = 'Red'
let g:bex_gui_green      = 'Green'
let g:bex_gui_yellow     = 'Yellow'
let g:bex_gui_blue       = 'Blue'
let g:bex_gui_magenta    = 'Magenta'
let g:bex_gui_cyan       = 'Cyan'
let g:bex_gui_white      = 'LightGray'
let g:bex_gui_br_black   = 'DarkGray'
let g:bex_gui_br_red     = 'LightRed'
let g:bex_gui_br_green   = 'LightGreen'
let g:bex_gui_br_yellow  = 'LightYellow'
let g:bex_gui_br_blue    = 'LightBlue'
let g:bex_gui_br_magenta = 'LightMagenta'
let g:bex_gui_br_cyan    = 'LightCyan'
let g:bex_gui_br_white   = 'White'
```

Navigation binds:

```vim
let g:bex_key_open     = '<CR>'
let g:bex_key_up       = '-'
let g:bex_key_changes  = '<Tab>'
let g:bex_key_hidden   = '.'
let g:bex_key_extract  = 'e'
let g:bex_key_goto_def = 'gd'
```

## Color Tokens

```
0   black
1   red
2   green
3   yellow
4   blue
5   magenta
6   cyan
7   white
8   br_black
9   br_red
10  br_green
11  br_yellow
12  br_blue
13  br_magenta
14  br_cyan
15  br_white
```

## Binds

```
RETURN
    Navigate into file/directory.

-
    Navigate to sub directory.

TAB
    Toggle between viewing file system modifications and current directory.
    Inside interface RETURN to revert modifications and E to extract deleted files to current directory.

.
    Toggle visibility of dotfiles.

g+d
    Goto definition with symlinks.
```

## Installation

### Via [vim-plug](https://github.com/junegunn/vim-plug)

```vim
Plug 'stqqrm/bex.vim'
```

## Todo

* Add support for reading/writing archived directories, .zip, .rar, .7z and .tar. (Features will enable if binaries are found in $PATH)
