" ============================================================================
" File: autoload/bex.vim
" Description: Cleaned, State-Driven ID-Tracked File Browser Engine
" ============================================================================

" --- Global State Initializations ---
let g:bex_id_counter       = get(g:, 'bex_id_counter', 0)
let g:bex_cache            = get(g:, 'bex_cache', {})
let g:bex_path_ids         = get(g:, 'bex_path_ids', {})
let g:bex_snapshots        = get(g:, 'bex_snapshots', {})
let g:bex_show_hidden      = get(g:, 'bex_show_hidden', 0)
let g:bex_toggling         = get(g:, 'bex_toggling', 0)
let g:bex_changes_show_ids = get(g:, 'bex_changes_show_ids', 0)
let g:bex_cursor_pos       = get(g:, 'bex_cursor_pos', {})
let g:bex_changes_bufnr    = get(g:, 'bex_changes_bufnr', -1)

" --- Highlights ---
highlight default BexHeader          ctermfg=Blue cterm=bold gui=bold
highlight default BexInfo            guifg=#555555 ctermfg=239
highlight default BexID              guifg=#555555 ctermfg=239
highlight default BexDir             ctermfg=Blue cterm=bold
highlight default BexHiddenDir       ctermfg=Blue cterm=bold
highlight default BexHiddenFile      ctermfg=White
highlight default BexVisible         ctermfg=Green cterm=bold gui=bold
highlight default BexHidden          ctermfg=Red cterm=bold gui=bold
highlight default BexChangesHeader   ctermfg=Blue  cterm=bold gui=bold
highlight default BexChangesDel      ctermfg=Red   cterm=bold gui=bold
highlight default BexChangesAdd      ctermfg=Green
highlight default BexChangesRename   ctermfg=Yellow cterm=bold gui=bold
highlight default BexChangesMoveFrom ctermfg=DarkGrey
highlight default BexChangesMoveTo   ctermfg=Cyan  cterm=bold gui=bold
highlight default BexChangesCopy     ctermfg=Blue
highlight default BexDotfilesOn      ctermfg=Green guifg=#00ff00 cterm=bold gui=bold
highlight default BexDotfilesOff     ctermfg=Red   guifg=#ff0000 cterm=bold gui=bold

" ============================================================================
" Public API
" ============================================================================

function! bex#Open(path) abort
    let l:dir = empty(a:path) ? (empty(expand('%:p:h')) ? getcwd() : expand('%:p:h')) : fnamemodify(a:path, ':p')
    let l:dir = len(l:dir) > 1 ? substitute(l:dir, '[/\\]$', '', '') : l:dir
    if !isdirectory(l:dir) | echoerr 'bex: Directory not found: ' . l:dir | return | endif

    execute (&modified ? 'split ' : 'edit ') . fnameescape('bex://' . l:dir)
    setlocal buftype=acwrite bufhidden=wipe noswapfile nobuflisted
    setlocal filetype=bex nonumber norelativenumber nowrap
    let b:bex_dir = l:dir

    call matchadd('BexDotfilesOn',  '\cdotfiles\s*[=:]\s*on')
    call matchadd('BexDotfilesOff', '\cdotfiles\s*[=:]\s*off')

    nnoremap <buffer> <silent> . :call bex#ToggleHidden()<CR>
    nnoremap <buffer> <silent> p p:call <SID>ensure_empty_line()<CR>
    nnoremap <buffer> <silent> P P:call <SID>ensure_empty_line()<CR>

    call s:render()
    call cursor(2, 1)
    call s:ParseBuffer()

    augroup bex_events
        autocmd! * <buffer>
        autocmd VimResized        <buffer> call bex#UpdateVirtualDirectory(b:bex_dir) | call s:render() | call s:reapply_props() | call s:ParseBuffer()
        autocmd BufWriteCmd       <buffer> call s:on_write()
        autocmd BufLeave          <buffer> call bex#UpdateVirtualDirectory(b:bex_dir) | setlocal nomodified
        autocmd BufUnload         <buffer> call s:on_unload()
        autocmd QuitPre           <buffer> call s:on_quit()
        autocmd TextChanged,TextChangedI  <buffer> call bex#UpdateVirtualDirectory(b:bex_dir) | call s:reapply_props()
        autocmd CursorMoved,CursorMovedI  <buffer> call s:handle_bounds()
    augroup END
endfunction

function! bex#Navigate(path) abort
    let l:dir = fnamemodify(a:path, ':p')
    let l:dir = len(l:dir) > 1 ? substitute(l:dir, '[/\\]$', '', '') : l:dir
    if !isdirectory(l:dir) | echoerr 'bex: Directory not found: ' . l:dir | return | endif

    let g:bex_cursor_pos[b:bex_dir] = getcurpos()
    call bex#UpdateVirtualDirectory(b:bex_dir)

    setlocal nomodified
    let b:bex_dir = l:dir
    execute 'silent file ' . fnameescape('bex://' . l:dir)
    call s:render()

    if has_key(g:bex_cursor_pos, l:dir)
        call setpos('.', g:bex_cursor_pos[l:dir])
    else
        call cursor(0, 1)
    endif
endfunction

function! bex#ToggleHidden() abort
    let g:bex_toggling = 1
    " Cache before toggle wipes buffer
    let l:plan = s:QueryBuffer()
    let l:has_changes = !empty(l:plan.delete) || !empty(l:plan.rename)
        \ || !empty(l:plan.entries) || !empty(l:plan.move_to)
    if l:has_changes
        let g:bex_cache[b:bex_dir] = l:plan
    endif
    let g:bex_show_hidden = !g:bex_show_hidden
    call s:render()
    let g:bex_toggling = 0
    call bex#UpdateVirtualDirectory(b:bex_dir)
endfunction

function! bex#GoUp() abort
    let l:parent = fnamemodify(b:bex_dir, ':h')
    if l:parent ==# b:bex_dir | echo 'bex: Already at root directory' | return | endif
    let l:prev_name = fnamemodify(b:bex_dir, ':t') . '/'
    call bex#Navigate(l:parent)
    for l:lnum in range(2, line('$'))
        if getline(l:lnum) =~# '\s' . escape(l:prev_name, ' /.\*[]^$~') . '\ze\(\s\|$\)'
            call cursor(l:lnum, 1) | break
        endif
    endfor
endfunction

function! bex#OnSelect() abort
    let l:match = matchlist(getline('.'), '^\(\/[0-9a-fA-F]\+\)\s\+\(.*\)$')
    if empty(l:match) || !has_key(b:bex_snapshot, l:match[1]) | return | endif
    let l:item = b:bex_snapshot[l:match[1]]

    if l:item.is_dir
        call bex#Navigate(l:item.path)
    else
        call bex#UpdateVirtualDirectory(b:bex_dir)
        setlocal nomodified
        execute 'edit ' . fnameescape(l:item.path)
    endif
endfunction

function! bex#UpdateVirtualDirectory(path) abort
    if g:bex_toggling | return | endif
    if mode() =~# '^[vV]' || mode() ==# "\<C-v>" | return | endif

    let l:state = s:QueryBuffer()
    let l:has_changes = !empty(l:state.delete) || !empty(l:state.rename)
        \ || !empty(l:state.entries) || !empty(l:state.move_to)

    if l:has_changes
        let g:bex_cache[a:path] = l:state
        setlocal modified
    else
        if has_key(g:bex_cache, a:path)
            call remove(g:bex_cache, a:path)
        endif
        setlocal nomodified
    endif

    call s:ParseBuffer()
endfunction

" ============================================================================
" Buffer Query & State
" ============================================================================

function! s:QueryBuffer() abort
    let l:state = {
        \ 'error': '',
        \ 'snapshot': copy(get(b:, 'bex_snapshot', {})),
        \ 'delete': [],
        \ 'rename': [],
        \ 'entries': [],
        \ 'move_to': []
        \ }

    let l:lines = []
    for l:line in getline(2, line('$'))
        if !empty(trim(l:line)) | call add(l:lines, l:line) | endif
    endfor

    let l:current_ids = {}
    let l:sep = (b:bex_dir ==# '/' || b:bex_dir ==# '\') ? '' : '/'

    for l:line in l:lines
        let l:id = matchstr(l:line, '^\/[0-9a-fA-F]\+')
        let l:name = substitute(l:line, '^\/[0-9a-fA-F]\+\s\+', '', '')

        if !empty(l:id)
            let l:current_ids[l:id] = l:name
            if has_key(b:bex_snapshot, l:id)
                let l:old_name = b:bex_snapshot[l:id].name . (b:bex_snapshot[l:id].is_dir ? '/' : '')
                if l:old_name !=# l:name
                    call add(l:state.rename, {'id': l:id, 'old': l:old_name, 'new': l:name})
                endif
            else
                let l:clean_name = substitute(l:name, '/$', '', '')
                if filereadable(b:bex_dir . l:sep . l:clean_name) || isdirectory(b:bex_dir . l:sep . l:clean_name)
                    let l:state.error = 'bex: Already exists: ' . l:clean_name
                endif
                call add(l:state.move_to, {'id': l:id, 'name': l:name})
            endif
        else
            let l:clean_name = substitute(l:name, '/$', '', '')
            if filereadable(b:bex_dir . l:sep . l:clean_name) || isdirectory(b:bex_dir . l:sep . l:clean_name)
                let l:state.error = 'bex: Already exists: ' . l:clean_name
            endif
            call add(l:state.entries, l:name)
        endif
    endfor

    for l:id in keys(b:bex_snapshot)
        if !has_key(l:current_ids, l:id)
            call add(l:state.delete, {'id': l:id, 'name': b:bex_snapshot[l:id].name})
        endif
    endfor

    return l:state
endfunction

" ============================================================================
" File System Application
" ============================================================================

function! s:on_write() abort
    call bex#UpdateVirtualDirectory(b:bex_dir)
    if empty(g:bex_cache) | setlocal nomodified | return | endif

    for [l:dir, l:state] in items(g:bex_cache)
        if !empty(l:state.error)
            echohl ErrorMsg | echoerr l:state.error | echohl None
            return
        endif
    endfor

    let l:all_dels = []
    for [l:dir, l:state] in items(g:bex_cache)
        for l:del in l:state.delete
            let l:is_moved = 0
            for [l:tdir, l:tstate] in items(g:bex_cache)
                for l:mov in l:tstate.move_to
                    if l:mov.id ==# l:del.id | let l:is_moved = 1 | break | endif
                endfor
            endfor
            if !l:is_moved
                call add(l:all_dels, l:dir . '/' . l:del.name)
            endif
        endfor
    endfor

    if !empty(l:all_dels)
        echo 'bex: Files to delete:'
        for l:path in l:all_dels | echo '  ' . l:path | endfor
        let l:ans = input('bex: Confirm deletion? [y/N]: ')
        echo ''
        if l:ans !=# 'y' && l:ans !=# 'Y' | setlocal nomodified | return | endif
    endif

    call s:apply_all()
endfunction

function! s:apply_all() abort
    " Pass 1: Renames
    for [l:dir, l:state] in items(g:bex_cache)
        let l:tmps = []
        for l:ren in l:state.rename
            if !has_key(l:state.snapshot, l:ren.id) | continue | endif
            let l:old_p = l:state.snapshot[l:ren.id].path
            let l:tmp_p = fnamemodify(l:old_p, ':h') . '/__tmp__.' . fnamemodify(l:old_p, ':t')
            call rename(l:old_p, l:tmp_p)
            call add(l:tmps, {'tmp': l:tmp_p, 'dest': fnamemodify(l:old_p, ':h') . '/' . substitute(l:ren.new, '/$', '', '')})
        endfor
        for l:t in l:tmps | call rename(l:t.tmp, l:t.dest) | endfor
    endfor

    " Pass 2: Moves, copies, creates, deletes
    for [l:dir, l:state] in items(g:bex_cache)
        let l:sep = (l:dir ==# '/' || l:dir ==# '\') ? '' : '/'

        for l:mov in l:state.move_to
            let l:src = ''
            " Check if renamed in pass 1
            for [l:cdir, l:cstate] in items(g:bex_cache)
                for l:ren in l:cstate.rename
                    if l:ren.id ==# l:mov.id
                        for [l:sdir, l:ssnap] in items(g:bex_snapshots)
                            if has_key(l:ssnap, l:mov.id)
                                let l:src_dir = fnamemodify(l:ssnap[l:mov.id].path, ':h')
                                let l:src = l:src_dir . '/' . substitute(l:ren.new, '/$', '', '')
                                break
                            endif
                        endfor
                    endif
                endfor
                if !empty(l:src) | break | endif
            endfor
            " Fall back to snapshot
            if empty(l:src)
                for [l:sdir, l:ssnap] in items(g:bex_snapshots)
                    if has_key(l:ssnap, l:mov.id)
                        let l:src = l:ssnap[l:mov.id].path
                        break
                    endif
                endfor
            endif
            if empty(l:src) | continue | endif

            let l:dst = l:dir . l:sep . substitute(l:mov.name, '/$', '', '')
            let l:is_copy = 1
            for [l:ddir, l:dstate] in items(g:bex_cache)
                for l:d in l:dstate.delete
                    if l:d.id ==# l:mov.id | let l:is_copy = 0 | break | endif
                endfor
            endfor

            if l:is_copy
                if has('win32') || has('win64')
                    let l:cmd = isdirectory(l:src) ? 'xcopy /E /I /Y ' : 'copy /Y '
                else
                    let l:cmd = isdirectory(l:src) ? 'cp -r ' : 'cp '
                endif
                call system(l:cmd . shellescape(l:src) . ' ' . shellescape(l:dst))
            else
                call rename(l:src, l:dst)
                let g:bex_path_ids[l:dst] = str2nr(matchstr(l:mov.id, '[0-9a-fA-F]\+$'), 16)
                if has_key(g:bex_path_ids, l:src) | call remove(g:bex_path_ids, l:src) | endif
            endif
        endfor

        for l:ent in l:state.entries
            let l:path = l:dir . l:sep . substitute(l:ent, '/$', '', '')
            if l:ent =~# '/$' | call mkdir(l:path, 'p') | else | call writefile([], l:path) | endif
        endfor

        for l:del in l:state.delete
            let l:still_exists = 0
            for [l:tdir, l:tstate] in items(g:bex_cache)
                for l:m in l:tstate.move_to
                    if l:m.id ==# l:del.id | let l:still_exists = 1 | break | endif
                endfor
            endfor
            if !l:still_exists && has_key(l:state.snapshot, l:del.id)
                let l:p = l:state.snapshot[l:del.id].path
                call delete(l:p, isdirectory(l:p) ? 'rf' : '')
            endif
        endfor
    endfor

    let g:bex_cache = {}
    let g:bex_snapshots = {}
    let g:bex_id_counter = 0
    let g:bex_path_ids = {}
    let g:bex_cursor_pos = {}

    setlocal nomodified

    if g:bex_changes_bufnr != -1 && bufwinnr(g:bex_changes_bufnr) != -1
        execute bufwinnr(g:bex_changes_bufnr) . 'close'
    endif

    call s:render()
endfunction

function! s:on_unload() abort
    let l:dir = get(b:, 'bex_dir', '')
    if !empty(l:dir) && has_key(g:bex_cache, l:dir)
        call remove(g:bex_cache, l:dir)
    endif
    call s:ParseBuffer()
endfunction

function! s:on_quit() abort
    let l:buf = bufnr('%')

    " Always close changes panel
    if g:bex_changes_bufnr != -1 && bufwinnr(g:bex_changes_bufnr) != -1
        execute bufwinnr(g:bex_changes_bufnr) . 'close'
    endif

    if histget('cmd', -1) =~# '!\s*$'
        call setbufvar(l:buf, '&modified', 0)
        return
    endif

    if empty(g:bex_cache)
        call setbufvar(l:buf, '&modified', 0)
        return
    endif

    let l:ans = input('bex: Unsaved changes, apply? [y/N]: ')
    echo ''
    if l:ans ==# 'y' || l:ans ==# 'Y'
        call s:apply_all()
    elseif l:ans ==# 'n' || l:ans ==# 'N'
        let g:bex_cache = {}
    else
        echo 'Quit aborted.'
    endif
    call setbufvar(l:buf, '&modified', 0)
endfunction

" ============================================================================
" Rendering
" ============================================================================

function! s:render() abort
    let l:sep = (b:bex_dir ==# '/' || b:bex_dir ==# '\') ? '' : '/'
    let l:all = glob(b:bex_dir . l:sep . '*', 0, 1)
    if g:bex_show_hidden | let l:all += glob(b:bex_dir . l:sep . '.[^.]*', 0, 1) | endif

    let b:bex_snapshot = {}
    let l:lines = []

    for l:p in l:all
        let l:name = fnamemodify(l:p, ':t')
        if l:name ==# '.' || l:name ==# '..' || empty(l:name) | continue | endif

        let g:bex_path_ids[l:p] = get(g:bex_path_ids, l:p, g:bex_id_counter)
        if g:bex_path_ids[l:p] == g:bex_id_counter | let g:bex_id_counter += 1 | endif

        let l:id = printf('/%08x', g:bex_path_ids[l:p])
        call add(l:lines, l:id . ' ' . l:name . (isdirectory(l:p) ? '/' : ''))
        let b:bex_snapshot[l:id] = {'name': l:name, 'is_dir': isdirectory(l:p), 'path': l:p}
    endfor

    let g:bex_snapshots[b:bex_dir] = copy(b:bex_snapshot)

    silent %delete _
    call setline(1, [''] + l:lines)
    if empty(l:lines) | call append(1, '') | endif
    setlocal nomodified

    call s:reapply_props()
    call s:restore_cached_buffer()
endfunction

function! s:revert_change_under_cursor() abort
    let l:save_lnum = line('.')
    let l:line = getline('.')
    let l:id = matchstr(l:line, '\/[0-9a-fA-F]\+')
    if empty(l:id) | return | endif

    for [l:dir, l:state] in items(g:bex_cache)
        let l:state.delete   = filter(copy(l:state.delete),   {_, v -> v.id !=# l:id})
        let l:state.rename   = filter(copy(l:state.rename),   {_, v -> v.id !=# l:id})
        let l:state.move_to  = filter(copy(l:state.move_to),  {_, v -> v.id !=# l:id})
        let g:bex_cache[l:dir] = l:state
        if empty(l:state.delete) && empty(l:state.rename)
            \ && empty(l:state.entries) && empty(l:state.move_to)
            call remove(g:bex_cache, l:dir)
        endif
    endfor

    call s:ParseBuffer()

    for l:buf in range(1, bufnr('$'))
        if getbufvar(l:buf, '&filetype') ==# 'bex'
            let l:bex_win = bufwinnr(l:buf)
            if l:bex_win != -1
                let l:cur_win = winnr()
                execute l:bex_win . 'wincmd w'
                call s:render()
                execute l:cur_win . 'wincmd w'
            endif
        endif
    endfor

    " If the line no longer exists or is empty, move up
    let l:new_last = line('$')
    if l:save_lnum > l:new_last || empty(trim(getline(l:save_lnum)))
        call cursor(max([1, l:save_lnum - 1]), 1)
    else
        call cursor(l:save_lnum, 1)
    endif
endfunction

function! s:restore_cached_buffer() abort
    if !has_key(g:bex_cache, b:bex_dir) | return | endif
    let l:state = g:bex_cache[b:bex_dir]

    for l:del in l:state.delete
        for l:lnum in range(line('$'), 2, -1)
            if stridx(getline(l:lnum), l:del.id) == 0 | silent execute l:lnum . 'd _' | break | endif
        endfor
    endfor

    for l:ren in l:state.rename
        for l:lnum in range(2, line('$'))
            if stridx(getline(l:lnum), l:ren.id) == 0
                call setline(l:lnum, l:ren.id . ' ' . l:ren.new) | break
            endif
        endfor
    endfor

    for l:mov in l:state.move_to
        let l:found = 0
        for l:lnum in range(2, line('$')) | if stridx(getline(l:lnum), l:mov.id) == 0 | let l:found = 1 | break | endif | endfor
        if !l:found
            let l:last = line('$')
            if l:last > 1 && empty(trim(getline(l:last)))
                call append(l:last - 1, l:mov.id . ' ' . l:mov.name)
            else
                call append(l:last, l:mov.id . ' ' . l:mov.name)
            endif
        endif
    endfor

    for l:ent in l:state.entries
        let l:found = 0
        for l:lnum in range(2, line('$')) | if getline(l:lnum) ==# l:ent | let l:found = 1 | break | endif | endfor
        if !l:found
            let l:last = line('$')
            if l:last > 1 && empty(trim(getline(l:last)))
                call append(l:last - 1, l:ent)
            else
                call append(l:last, l:ent)
            endif
        endif
    endfor

    " Ensure exactly one trailing empty line and preserve line 1 header space
    while line('$') > 2 && empty(trim(getline(line('$')))) && empty(trim(getline(line('$') - 1)))
        silent execute line('$') . 'd _'
    endwhile
    if line('$') < 2
        call append(line('$'), '')
    elseif !empty(trim(getline(line('$'))))
        call append(line('$'), '')
    endif

    setlocal nomodified
endfunction

function! s:reapply_props() abort
    if !empty(prop_type_get('bex_status'))
        call prop_type_delete('bex_status')
    endif
    call prop_type_add('bex_status', {'highlight': g:bex_show_hidden ? 'BexVisible' : 'BexHidden'})
    if empty(prop_type_get('bex_header')) | call prop_type_add('bex_header', {'highlight': 'BexHeader'}) | endif
    if empty(prop_type_get('bex_info'))   | call prop_type_add('bex_info',   {'highlight': 'BexInfo'})   | endif

    call prop_clear(1, line('$'))
    let l:home = expand('$HOME')
    let l:left = stridx(b:bex_dir, l:home) == 0 ? '~/' . b:bex_dir[len(l:home)+1:] : b:bex_dir
    call prop_add(1, 0, {'type': 'bex_header', 'text': l:left})
    call prop_add(1, 0, {'type': 'bex_status', 'text': g:bex_show_hidden ? 'dotfiles=on' : 'dotfiles=off', 'text_align': 'right'})

    for l:lnum in range(2, line('$'))
        let l:id = matchstr(getline(l:lnum), '^\/[0-9a-fA-F]\{8}')
        if empty(l:id) || !has_key(b:bex_snapshot, l:id) | continue | endif
        let l:p = b:bex_snapshot[l:id].path
        let l:info = printf('%-10s %8s %10s', getfperm(l:p), s:human_size(getfsize(l:p)), s:relative_time(getftime(l:p)))
        call prop_add(l:lnum, 0, {'type': 'bex_info', 'text': l:info, 'text_align': 'right'})
    endfor

    syntax clear
    syntax match BexID /^\/[0-9a-fA-F]\+\ze\s/
	syntax match BexDir        /\%(\/[0-9a-fA-F]\+\s\+\|\s*\)\zs[^/].\+\/$/
    syntax match BexDir        /\zs\S\+\/$/
    syntax match BexHiddenDir  /\zs\.[^/]*\/$/
    syntax match BexHiddenFile /\%(^\s*\|\s\)\zs\.[^/]\+$/
endfunction

" ============================================================================
" Changes Panel
" ============================================================================

function! s:ParseBuffer() abort
    let l:current_win_id = win_getid()
    let l:has_changes = !empty(g:bex_cache)
    let l:cbuf = g:bex_changes_bufnr

    if !l:has_changes
        if l:cbuf != -1 && bufwinnr(l:cbuf) != -1
            execute bufwinnr(l:cbuf) . 'close'
        endif
        call win_gotoid(l:current_win_id)
        return
    endif

    if l:cbuf == -1 || !bufexists(l:cbuf)
        noautocmd rightbelow vertical 30vnew
        let g:bex_changes_bufnr = bufnr('%')
        let l:cbuf = g:bex_changes_bufnr
        setlocal buftype=nofile bufhidden=wipe noswapfile nobuflisted
        setlocal nonumber norelativenumber nowrap
        setlocal filetype=bex_changes
        setlocal statusline=\ changes
        augroup bex_changes_events
            autocmd! * <buffer>
            autocmd BufEnter   <buffer> let g:bex_changes_show_ids = 1 | call s:ParseBuffer()
            autocmd BufLeave   <buffer> let g:bex_changes_show_ids = 0 | call s:ParseBuffer()
            autocmd BufWipeout <buffer> let g:bex_changes_bufnr = -1
        augroup END
        nnoremap <buffer> <silent> <CR> :call <SID>revert_change_under_cursor()<CR>
		call win_gotoid(l:current_win_id)
    elseif bufwinnr(l:cbuf) == -1
        noautocmd rightbelow vertical 30vnew
        execute 'noautocmd buffer ' . l:cbuf
        call win_gotoid(l:current_win_id)
    endif

    let l:cwin = bufwinnr(l:cbuf)
    if l:cwin == -1 | call win_gotoid(l:current_win_id) | return | endif

    let l:global_deletions = {}
    for [l:dir, l:state] in items(g:bex_cache)
        for l:item in get(l:state, 'delete', [])
            let l:global_deletions[l:item.id] = 1
        endfor
    endfor

    let l:global_placements = {}
    for [l:dir, l:state] in items(g:bex_cache)
        for l:item in get(l:state, 'move_to', [])
            let l:global_placements[l:item.id] = 1
        endfor
    endfor

    let l:home = expand('$HOME')
    let l:lines = []
    let l:highlights = []
    let l:lnum = 1

    for [l:dir, l:state] in items(g:bex_cache)
        let l:path_header = stridx(l:dir, l:home) == 0 ? '~/' . l:dir[len(l:home)+1:] : l:dir
        call add(l:lines, l:path_header)
        call add(l:highlights, {'lnum': l:lnum, 'hl': 'BexChangesHeader'})
        let l:lnum += 1

        for l:del in get(l:state, 'delete', [])
            let l:id_prefix = g:bex_changes_show_ids ? l:del.id . ' ' : ''
            call add(l:lines, '  - ' . l:id_prefix . l:del.name)
            call add(l:highlights, {'lnum': l:lnum, 'hl': has_key(l:global_placements, l:del.id) ? 'BexChangesMoveFrom' : 'BexChangesDel'})
            let l:lnum += 1
        endfor

        for l:ren in get(l:state, 'rename', [])
            let l:id_prefix = g:bex_changes_show_ids ? l:ren.id . ' ' : ''
            call add(l:lines, '  ~ ' . l:id_prefix . l:ren.old . ' -> ' . l:ren.new)
            call add(l:highlights, {'lnum': l:lnum, 'hl': 'BexChangesRename'})
            let l:lnum += 1
        endfor

        for l:mov in get(l:state, 'move_to', [])
            let l:id_prefix = g:bex_changes_show_ids ? l:mov.id . ' ' : ''
            if has_key(l:global_deletions, l:mov.id)
                call add(l:lines, '  + ' . l:id_prefix . l:mov.name)
                call add(l:highlights, {'lnum': l:lnum, 'hl': 'BexChangesMoveTo'})
            else
                call add(l:lines, '  * ' . l:id_prefix . l:mov.name)
                call add(l:highlights, {'lnum': l:lnum, 'hl': 'BexChangesCopy'})
            endif
            let l:lnum += 1
        endfor

        for l:ent in get(l:state, 'entries', [])
            let l:id_prefix = g:bex_changes_show_ids ? '(new) ' : ''
            call add(l:lines, '  + ' . l:id_prefix . l:ent)
            call add(l:highlights, {'lnum': l:lnum, 'hl': 'BexChangesAdd'})
            let l:lnum += 1
        endfor

        call add(l:lines, '')
        let l:lnum += 1
    endfor

    execute l:cwin . 'wincmd w'
    setlocal modifiable
    silent %delete _
    call setline(1, l:lines)

    call prop_clear(1, line('$'), {'bufnr': l:cbuf})
    for l:item in l:highlights
        if empty(prop_type_get(l:item.hl, {'bufnr': l:cbuf}))
            call prop_type_add(l:item.hl, {'highlight': l:item.hl, 'bufnr': l:cbuf})
        endif
        call prop_add(l:item.lnum, 1, {
            \ 'end_col': len(getline(l:item.lnum)) + 1,
            \ 'type': l:item.hl,
            \ 'bufnr': l:cbuf
            \ })
    endfor

    setlocal nomodifiable

    let l:max_w = 25
    for l:n in range(1, line('$'))
        let l:max_w = max([l:max_w, strdisplaywidth(getline(l:n)) + 3])
    endfor
    execute 'vertical resize ' . l:max_w

    call win_gotoid(l:current_win_id)
endfunction

" ============================================================================
" Helpers
" ============================================================================

function! s:handle_bounds() abort
    if line('.') == 1
        if line('$') == 1 | call append(1, '') | endif
        call cursor(2, col('.'))
    endif
    call bex#UpdateVirtualDirectory(b:bex_dir)
endfunction

function! s:ensure_empty_line() abort
    if !empty(trim(getline(line('$')))) | call append(line('$'), '') | endif
endfunction

function! s:relative_time(ftime) abort
    let l:d = localtime() - a:ftime
    return l:d < 60 ? l:d.'s ago' : l:d < 3600 ? (l:d/60).'m ago' : l:d < 86400 ? (l:d/3600).'h ago' : (l:d/86400).'d ago'
endfunction

function! s:human_size(size) abort
    return a:size < 1024 ? a:size.'B' : a:size < 1048576 ? (a:size/1024).'KB' : (a:size/1048576).'MB'
endfunction
