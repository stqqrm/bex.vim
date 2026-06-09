" plugin/bex.vim

if exists('g:loaded_bex') | finish | endif
let g:loaded_bex = 1

" Define the command to pass the file's current directory if no argument is given
command! -nargs=? -complete=dir Bex call bex#Open(<q-args>)
