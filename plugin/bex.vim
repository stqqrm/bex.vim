" plugin/bex.vim
if exists('g:loaded_bex') | finish | endif
let g:loaded_bex = 1

nnoremap <silent> <leader>e :call bex#Toggle()<CR>

command! -nargs=? -complete=dir Bex call s:bex_cmd(<q-args>)

function! s:bex_cmd(args) abort
    let l:args = trim(a:args)
    if l:args ==# '-r' || l:args =~# '^-r\s'
        let l:path = trim(substitute(l:args, '^-r', '', ''))
        call bex#Reload(l:path)
        return
    endif

    " If a bex buffer already exists, navigate to the new path
    for l:buf in range(1, bufnr('$'))
        if getbufvar(l:buf, '&filetype') ==# 'bex' && bufexists(l:buf)
            call setbufvar(l:buf, '&modified', 0)
            execute 'buffer ' . l:buf
            if !empty(l:args)
                call bex#Navigate(l:args)
            endif
            return
        endif
    endfor

    call bex#Open(l:args)
endfunction
