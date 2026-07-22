" plugin/bex.vim
augroup bex_plugin
    autocmd!
    autocmd ColorScheme * call s:rerender_if_bex()
    autocmd SourcePost  * call s:rerender_if_bex()
augroup END

function! s:rerender_if_bex()
    if mode() !~# '^n' | return | endif
    call bex#RedefineHighlights()
    try
        for l:buf in range(1, bufnr('$'))
            if getbufvar(l:buf, '&filetype') ==# 'bex' && bufwinnr(l:buf) != -1
                let l:win = bufwinnr(l:buf)
                let l:cur = winnr()
                execute l:win . 'wincmd w'
                call bex#SafeRerender()
                execute l:cur . 'wincmd w'
                return
            endif
        endfor
    catch
    endtry
endfunction

function! bex#RedefineHighlights() abort
    highlight! BexHeader          ctermfg=Yellow cterm=bold gui=bold
    highlight! BexInfo            ctermfg=DarkGrey
    highlight! BexID              ctermfg=DarkGrey
    highlight! BexDir             ctermfg=Yellow cterm=bold
    highlight! BexHiddenID        ctermfg=DarkGrey
    highlight! BexHiddenDir       ctermfg=Yellow cterm=bold
    highlight! BexHiddenFile      ctermfg=White
    highlight! BexVisible         ctermfg=Green cterm=bold gui=bold
    highlight! BexHidden          ctermfg=Red cterm=bold gui=bold
    highlight! BexChangesDir      ctermfg=Yellow cterm=bold gui=bold
    highlight! BexChangesDel      ctermfg=Red cterm=bold gui=bold
    highlight! BexChangesAdd      ctermfg=Green
    highlight! BexChangesRename   ctermfg=Cyan cterm=bold gui=bold
    highlight! BexChangesMoveFrom ctermfg=DarkGrey
    highlight! BexChangesMoveTo   ctermfg=Magenta cterm=bold gui=bold
    highlight! BexChangesCopy     ctermfg=Blue
    highlight! BexDotfilesOn      ctermfg=Green cterm=bold gui=bold
    highlight! BexDotfilesOff     ctermfg=Red cterm=bold gui=bold
endfunction
call bex#RedefineHighlights()

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
