# bex.vim

A simple ID-tracked file browser engine for Vim. The name **bex** stands for **Better Explorer**.

`bex.vim` loads a directory listing into a standard text buffer where each line is prefixed with a visible tracking ID (`ID:00000000 `). You can modify, delete, or create lines using native Vim commands. Saving the buffer with `:w` commits those changes to disk.

## Installation

### Via [vim-plug](https://github.com/junegunn/vim-plug)

```vim
Plug 'YOUR_GITHUB_USERNAME/bex.vim'
