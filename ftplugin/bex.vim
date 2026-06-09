" ftplugin/bex.vim
if exists('b:did_ftplugin') | finish | endif
let b:did_ftplugin = 1

" Local file browser keymaps
nnoremap <buffer> <silent> <CR> :call bex#OnSelect()<CR>
nnoremap <buffer> <silent> -    :call bex#GoUp()<CR>
