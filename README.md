# bex.vim

A simple ID-tracked file browser for Vim. The name **bex** stands for **Better Explorer**.

`bex.vim` loads a directory listing into a standard text buffer where each line is prefixed with a visible tracking ID (`/00000000 `). You can modify, delete, or create lines using native Vim commands. Saving the buffer with `:w` commits those changes to disk.

## Usage

* Test 
```
Hello World
```
## Installation

### Via [vim-plug](https://github.com/junegunn/vim-plug)

```vim
Plug 'stqqrm/bex.vim'
