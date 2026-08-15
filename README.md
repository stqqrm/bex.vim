# bex.vim

A simple ID-tracked file browser for Vim. The name **bex** stands for **Better Explorer**.

`bex.vim` loads a directory listing into a standard text buffer where each line is prefixed with a visible tracking ID (`/xxxx `). You can modify, delete, or create lines using native Vim commands. Saving the buffer with `:w` commits those changes to disk.

![bex.vim demo](images/demo.png)

## Features

* Support for rendering images with chafa.

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

* Configuration

```vim
let g:bex_header_at_bottom = 1
```
You can also change theme if termguicolors is enabled.
```vim
let g:bex_gui_black      = '#000000'
let g:bex_gui_red        = '#AA0000'
let g:bex_gui_green      = '#00AA00'
let g:bex_gui_yellow     = '#AA5500'
let g:bex_gui_blue       = '#0000AA'
let g:bex_gui_magenta    = '#AA00AA'
let g:bex_gui_cyan       = '#00AAAA'
let g:bex_gui_white      = '#AAAAAA'

let g:bex_gui_br_black   = '#555555'
let g:bex_gui_br_red     = '#FF5555'
let g:bex_gui_br_green   = '#55FF55'
let g:bex_gui_br_yellow  = '#FFFF55'
let g:bex_gui_br_blue    = '#5555FF'
let g:bex_gui_br_magenta = '#FF55FF'
let g:bex_gui_br_cyan    = '#55FFFF'
let g:bex_gui_br_white   = '#FFFFFF'
```

## Binds

```
RETURN
    Navigate into file/directory.

-
    Navigate to previous directory.

TAB
    Toggle between viewing changes and current directory.

.
    Toggle visibility of dotfiles.
```

## Installation

### Via [vim-plug](https://github.com/junegunn/vim-plug)

```vim
Plug 'stqqrm/bex.vim'
```

## Todo

* Add support for unpacking/packing .zip, .rar, .7z and .tar. (Optional, only enabled if dependencies are already installed)
