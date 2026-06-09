" plugin/bex.vim
if exists('g:loaded_bex') | finish | endif
let g:loaded_bex = 1

" Fullscreen command: Switches the active window directly into the file browser
command! -nargs=? -complete=dir Bex call bex#Open(<q-args>)
