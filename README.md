# bex.vim

A simple ID-tracked file browser for Vim. The name **bex** stands for **Better Explorer**.

`bex.vim` loads a directory listing into a standard text buffer where each line is prefixed with a visible tracking ID (`/xxxx `). You can modify, delete, or create lines using native Vim commands. Saving the buffer with `:w` commits those changes to disk.

![bex.vim demo](images/demo.png)

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

```
let g:bex_header_at_bottom = 1
```

## Installation

### Via [vim-plug](https://github.com/junegunn/vim-plug)

```vim
Plug 'stqqrm/bex.vim'
```

## Todo

* Add support for unpacking/packing .zip, .rar, .7z and .tar. (Optional, only enabled if dependencies are already installed)
