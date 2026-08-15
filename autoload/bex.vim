" File: autoload/bex.vim
" Description: ID-Tracked File Browser Engine

" --- Global State Initializations ---
let g:bex_id_counter        = get(g:, 'bex_id_counter', 0)
let g:bex_cache             = get(g:, 'bex_cache', {})
let g:bex_path_ids          = get(g:, 'bex_path_ids', {})
let g:bex_snapshots         = get(g:, 'bex_snapshots', {})
let g:bex_show_hidden       = get(g:, 'bex_show_hidden', 0)
let g:bex_toggling          = get(g:, 'bex_toggling', 0)
let g:bex_cursor_pos        = get(g:, 'bex_cursor_pos', {})
let g:bex_header_at_bottom  = get(g:, 'bex_header_at_bottom', 0)

" Registry of every bex-owned popup id -> the buffer it was created for.
" See s:bex_gc_popups() for what this is for.
let g:bex_popup_registry     = get(g:, 'bex_popup_registry', {})

" Image preview: entering (<CR>) a file whose extension is in this list
" renders it in-place with chafa/ImageMagick instead of :edit. Set
" g:bex_image_preview = 0 to disable and always fall back to :edit.
let g:bex_image_extensions  = get(g:, 'bex_image_extensions',
    \ ['png', 'jpg', 'jpeg', 'gif', 'bmp', 'webp', 'tiff', 'tif', 'ico'])
let g:bex_image_preview     = get(g:, 'bex_image_preview', 1)
let g:bex_image_chafa_args  = get(g:, 'bex_image_chafa_args', [])
let g:bex_image_magick_args = get(g:, 'bex_image_magick_args',
    \ ['-geometry', '1024x768>', '-colorspace', 'sRGB',
    \  '-dither', 'FloydSteinberg', '-colors', '256'])

" Scoped to bex.vim's own path (not a <buffer>-local autocmd) so it only
" fires when this file itself is resourced, not every script sourced
" while a bex buffer happens to be active.
let s:bex_script_path = expand('<sfile>:p')

function! s:on_bex_resourced() abort
    let l:orig_win = win_getid()
    for l:buf in range(1, bufnr('$'))
        if bufexists(l:buf) && getbufvar(l:buf, '&filetype') ==# 'bex'
            let l:win = bufwinnr(l:buf)
            if l:win != -1
                execute l:win . 'wincmd w'
                call bex#SafeRerender()
                call s:position_header_popup()
            endif
        endif
    endfor
    call win_gotoid(l:orig_win)
endfunction

augroup bex_reload_events
    autocmd!
    execute 'autocmd SourcePost ' . fnameescape(s:bex_script_path) . ' call s:on_bex_resourced()'
augroup END

" Public API

function! bex#Open(path) abort
    let l:dir = empty(a:path) ? (empty(expand('%:p:h')) ? getcwd() : expand('%:p:h')) : fnamemodify(a:path, ':p')
    let l:dir = len(l:dir) > 1 ? substitute(l:dir, '[/\\]$', '', '') : l:dir
    if !isdirectory(l:dir) | echoerr 'bex: Directory not found: ' . l:dir | return | endif

    execute (&modified ? 'split ' : 'edit ') . fnameescape('bex://' . l:dir)
    setlocal buftype=acwrite bufhidden=hide noswapfile nobuflisted
    setlocal filetype=bex nonumber norelativenumber nowrap noeol nofixeol
    let b:bex_dir = l:dir
    let b:bex_header_popup = -1
    let b:bex_changes_view = 0
    let b:bex_history = [l:dir]
    let b:bex_hist_idx = 0

    " Opt bex out of coc.nvim's document-sync/diagnostics machinery: its
    " CursorHold-triggered housekeeping was silently resetting the cursor
    " mid-navigation. Standard flags other file explorers set for the same
    " reason; no-op if coc.nvim isn't installed.
    let b:coc_enabled = 0
    let b:coc_suggest_disable = 1

    nnoremap <buffer> <silent> . :call bex#ToggleHidden()<CR>
    nnoremap <buffer> <silent> <CR> :call bex#OnSelect()<CR>
    nnoremap <buffer> <silent> <Tab> :call bex#ToggleChangesView()<CR>
    nnoremap <buffer> <silent> e :call bex#ExtractUnderCursor()<CR>
    nnoremap <buffer> <silent> gd :call bex#GotoDefinition()<CR>
    nnoremap <buffer> <silent> <C-o> :call bex#HistoryBack()<CR>
    nnoremap <buffer> <silent> <C-i> :call bex#HistoryForward()<CR>

    call s:render()

    augroup bex_events
        autocmd! * <buffer>
        autocmd VimResized                <buffer> call s:reapply_props() | call s:position_header_popup()
        autocmd BufWriteCmd               <buffer> call s:on_write()
        autocmd BufEnter                  <buffer> call s:reapply_props() | call s:position_header_popup()
        autocmd BufLeave                  <buffer> call bex#UpdateVirtualDirectory(b:bex_dir)
        autocmd BufWinLeave               <buffer> call s:close_header_popup()
        autocmd BufUnload                 <buffer> call s:on_unload() | call s:close_header_popup()
        autocmd QuitPre                   <buffer> call s:on_quit() | call s:close_header_popup()
        autocmd TextChanged,TextChangedI  <buffer> call s:enforce_spacer() | call s:lock_cursor() | call bex#UpdateVirtualDirectory(b:bex_dir) | call s:reapply_props() | call s:position_header_popup()
        autocmd CursorMoved,CursorMovedI  <buffer> call s:handle_bounds()
        autocmd ColorScheme               <buffer> call s:reapply_props() | call s:position_header_popup()
        autocmd WinScrolled               <buffer> call s:position_header_popup()
        autocmd WinEnter                  <buffer> call s:position_header_popup()
    augroup END

    call s:position_header_popup()
endfunction

function! bex#Toggle() abort
    for l:buf in range(1, bufnr('$'))
        if getbufvar(l:buf, '&filetype') ==# 'bex' && bufexists(l:buf)
            call setbufvar(l:buf, '&modified', 0)
            execute 'buffer ' . l:buf
            return
        endif
    endfor
    call bex#Open('')
endfunction

function! bex#Reload(...) abort
    let l:path = get(a:, 1, '')

    call s:close_all_bex_popups()

    let g:bex_cache      = {}
    let g:bex_snapshots  = {}
    let g:bex_id_counter = 0
    let g:bex_path_ids   = {}
    let g:bex_cursor_pos = {}

    let l:dir = ''
    for l:buf in range(1, bufnr('$'))
        if getbufvar(l:buf, '&filetype') ==# 'bex' && bufexists(l:buf)
            let l:dir = getbufvar(l:buf, 'bex_dir', '')
            call setbufvar(l:buf, '&modified', 0)
            execute 'bwipeout! ' . l:buf
            break
        endif
    endfor

    let l:open = !empty(l:path) ? l:path : (!empty(l:dir) ? l:dir : '')
    call bex#Open(l:open)
endfunction

function! bex#Navigate(path, ...) abort
    " a:1 = allow_virtual (1 to navigate into a directory that doesn't
    " exist on disk yet, e.g. a freshly typed entry about to be created).
    let l:allow_virtual = get(a:, 1, 0)
    let l:skip_history = get(a:, 2, 0)

    let l:dir = fnamemodify(a:path, ':p')
    let l:dir = len(l:dir) > 1 ? substitute(l:dir, '[/\\]$', '', '') : l:dir
    if !isdirectory(l:dir) && !l:allow_virtual
        echoerr 'bex: Directory not found: ' . l:dir
        return
    endif

    if !l:skip_history
        if !exists('b:bex_history')
            let b:bex_history = []
            let b:bex_hist_idx = -1
        endif
        if empty(b:bex_history) || b:bex_history[b:bex_hist_idx] !=# l:dir
            if b:bex_hist_idx < len(b:bex_history) - 1
                let b:bex_history = b:bex_history[0 : b:bex_hist_idx]
            endif
            call add(b:bex_history, l:dir)
            let b:bex_hist_idx = len(b:bex_history) - 1
        endif
    endif

    " Leave the changes view first and actually re-render (not just flip
    " the flag) -- the next line queries buffer text for pending edits,
    " and stale changes-view text would make every tracked file look deleted.
    if get(b:, 'bex_changes_view', 0)
        let b:bex_changes_view = 0
        setlocal modifiable
        call s:render()
    endif

    let g:bex_cursor_pos[b:bex_dir] = getcurpos()
    call bex#UpdateVirtualDirectory(b:bex_dir)

    setlocal nomodified
    let b:bex_dir = l:dir
    execute 'silent file ' . fnameescape('bex://' . l:dir)
    call s:render()

    if has_key(g:bex_cursor_pos, l:dir)
        call setpos('.', g:bex_cursor_pos[l:dir])
    endif
endfunction

function! bex#HistoryBack() abort
    if !exists('b:bex_history') || b:bex_hist_idx <= 0
        echo 'bex: no earlier location'
        return
    endif
    let b:bex_hist_idx -= 1
    let l:target = b:bex_history[b:bex_hist_idx]
    call bex#Navigate(l:target, !isdirectory(l:target), 1)
endfunction

function! bex#HistoryForward() abort
    if !exists('b:bex_history') || b:bex_hist_idx >= len(b:bex_history) - 1
        echo 'bex: no later location'
        return
    endif
    let b:bex_hist_idx += 1
    let l:target = b:bex_history[b:bex_hist_idx]
    call bex#Navigate(l:target, !isdirectory(l:target), 1)
endfunction

function! bex#ToggleHidden() abort
    " In the changes view there's no listing to toggle -- just flip the
    " flag and refresh the header's on/off indicator. Deliberately does
    " NOT call s:render() here: render() rebuilds b:bex_snapshot to the
    " new listing before rewriting buffer text, and a stray diff during
    " that window previously flagged every tracked file as deleted.
    if get(b:, 'bex_changes_view', 0)
        let g:bex_show_hidden = !g:bex_show_hidden
        call s:position_header_popup()
        return
    endif

    " g:bex_toggling makes bex#UpdateVirtualDirectory() a no-op during the
    " render() below, for the same "stale buffer vs. new snapshot" reason.
    let g:bex_toggling = 1

    let l:cursor_line = line('.')
    let l:cursor_id = matchstr(getline('.'), '^\/[0-9a-zA-Z]\+')

    let l:plan = s:merge_hidden_pending(b:bex_dir, s:QueryBuffer())
    let l:has_changes = !empty(l:plan.delete) || !empty(l:plan.rename)
        \ || !empty(l:plan.entries) || !empty(l:plan.move_to)
    if l:has_changes
        let g:bex_cache[b:bex_dir] = l:plan
    endif
    let g:bex_show_hidden = !g:bex_show_hidden
    call s:render()

    " IDs stay stable across a toggle (only render() ran) -- find the same
    " item's line again rather than leaving the cursor wherever render()
    " defaults to.
    let l:found = 0
    if !empty(l:cursor_id)
        for l:lnum in range(s:content_start(), s:content_end())
            if stridx(getline(l:lnum), l:cursor_id) == 0
                call cursor(l:lnum, 1)
                let l:found = 1
                break
            endif
        endfor
    endif
    if !l:found
        call cursor(min([l:cursor_line, line('$')]), 1)
    endif
    call s:lock_cursor()

    let g:bex_toggling = 0
    call bex#UpdateVirtualDirectory(b:bex_dir)
endfunction

function! bex#GoUp() abort
    let l:parent = fnamemodify(b:bex_dir, ':h')
    if l:parent ==# b:bex_dir | echo 'bex: Already at root directory' | return | endif
    let l:prev_name = fnamemodify(b:bex_dir, ':t') . '/'
    call bex#Navigate(l:parent, !isdirectory(l:parent))
    for l:lnum in range(s:content_start(), s:content_end())
        if getline(l:lnum) =~# '\s' . escape(l:prev_name, ' /.\*[]^$~') . '\ze\(\s\|$\)'
            call cursor(l:lnum, 1) | break
        endif
    endfor
endfunction

" Stages the item under the cursor in the changes view to land in the
" directory that was open when <Tab> was pressed. apply_all() already
" treats a move_to as a real move whenever a matching delete exists
" elsewhere in g:bex_cache -- exactly the state a cut leaves things in --
" so nothing else needs to change on the source side.
function! bex#ExtractUnderCursor() abort
    if !get(b:, 'bex_changes_view', 0)
        echo 'bex: e only works from the changes view (<Tab>)'
        return
    endif

    let l:id = matchstr(getline('.'), '\/[0-9a-zA-Z]\+')
    if empty(l:id)
        echo 'bex: nothing to extract on this line'
        return
    endif

    let l:owner_dir = s:changes_view_owner_dir(line('.'))
    if empty(l:owner_dir)
        echo 'bex: nothing to extract on this line'
        return
    endif

    if l:owner_dir ==# b:bex_dir
        echo 'bex: already staged in the current directory'
        return
    endif

    let l:info = {}
    if has_key(g:bex_cache, l:owner_dir) && has_key(g:bex_cache[l:owner_dir].snapshot, l:id)
        let l:info = g:bex_cache[l:owner_dir].snapshot[l:id]
    elseif has_key(g:bex_snapshots, l:owner_dir) && has_key(g:bex_snapshots[l:owner_dir], l:id)
        let l:info = g:bex_snapshots[l:owner_dir][l:id]
    endif
    if empty(l:info)
        echo 'bex: could not resolve item for extraction'
        return
    endif
    let l:display = l:info.name . (l:info.is_dir ? '/' : '')

    let l:state = has_key(g:bex_cache, b:bex_dir) ? g:bex_cache[b:bex_dir]
        \ : {'snapshot': copy(b:bex_snapshot), 'delete': [], 'rename': [], 'entries': [], 'move_to': []}

    for l:mov in l:state.move_to
        if l:mov.id ==# l:id
            echo 'bex: already staged to land here'
            return
        endif
    endfor

    call add(l:state.move_to, {'id': l:id, 'name': l:display})
    let g:bex_cache[b:bex_dir] = l:state

    call s:normalize_cache()
    call s:show_changes_in_buffer()
    echo 'bex: staged ' . l:display . ' to land in ' . b:bex_dir
endfunction

" Mapped to gd: follow the symlink under the cursor to where it actually
" points, rather than the symlink entry itself.
function! bex#GotoDefinition() abort
    if get(b:, 'bex_changes_view', 0) | return | endif

    let l:match = matchlist(getline('.'), '^\(\/[0-9a-zA-Z]\+\)\s\+\(.*\)$')
    if empty(l:match) || !has_key(b:bex_snapshot, l:match[1])
        echo 'bex: nothing under the cursor'
        return
    endif

    let l:item = b:bex_snapshot[l:match[1]]
    if !get(l:item, 'is_link', 0)
        echo 'bex: not a symlink'
        return
    endif

    let l:target = resolve(l:item.path)
    if !isdirectory(l:target) && !filereadable(l:target)
        echo 'bex: broken symlink -> ' . l:target
        return
    endif

    if isdirectory(l:target)
        call bex#Navigate(l:target)
        return
    endif

    call bex#Navigate(fnamemodify(l:target, ':h'))
    let l:tname = fnamemodify(l:target, ':t')
    for l:lnum in range(s:content_start(), s:content_end())
        if getline(l:lnum) =~# '\s' . escape(l:tname, ' /.\*[]^$~') . '\ze\(\s\|$\)'
            call cursor(l:lnum, 1) | break
        endif
    endfor
endfunction

" Extension-based check, same convention bex uses elsewhere for
" filetype-ish decisions -- cheap to call on every <CR>.
function! s:is_image(path) abort
    let l:ext = tolower(fnamemodify(a:path, ':e'))
    return !empty(l:ext) && index(g:bex_image_extensions, l:ext) >= 0
endfunction

function! s:image_backend_available() abort
    return executable('chafa') || executable('magick') || executable('convert')
endfunction

" Character-cell size to render into: the window's size minus one row for
" the header popup. Only ever fed to chafa's own '--size' below, never to
" term_start()'s term_rows/term_cols, so it never resizes the real window.
function! s:image_target_size() abort
    let l:winid = win_getid()
    return [max([winwidth(l:winid), 1]), max([winheight(l:winid) - 1, 1])]
endfunction

" chafa is preferred; ImageMagick's sixel output is a best-effort fallback,
" since Vim's builtin :terminal (libvterm) can't actually render sixel --
" installing chafa is the real fix if only this fallback is ever used.
function! s:image_backend(path, cols, lines) abort
    if executable('chafa')
        let l:has_colors = !empty(filter(copy(g:bex_image_chafa_args), 'v:val =~# "^--colors="'))
        let l:colors = l:has_colors ? []
            \ : [(exists('&termguicolors') && &termguicolors) ? '--colors=full' : '--colors=256']
        return ['chafa', '--size', a:cols . 'x' . a:lines] + l:colors + g:bex_image_chafa_args + [a:path]
    elseif executable('magick') || executable('convert')
        return [executable('magick') ? 'magick' : 'convert', a:path] + g:bex_image_magick_args + ['sixel:-']
    endif
    return []
endfunction

" (Re)draws a:path into the current window as a fresh terminal job,
" replacing whatever bex terminal buffer was previously showing it.
function! s:start_image_terminal(path) abort
    let l:old_buf = (get(b:, 'bex_image_src', '') ==# a:path) ? bufnr('%') : -1

    let [l:cols, l:lines] = s:image_target_size()
    let l:cmd = s:image_backend(a:path, l:cols, l:lines)
    if empty(l:cmd)
        execute 'edit ' . fnameescape(a:path)
        return
    endif

    " No term_rows/term_cols: those resize the *window* (and every other
    " window's statusline) to match. Sizing comes from '--size' above.
    call term_start(l:cmd, {'curwin': 1, 'term_name': '[image] ' . fnamemodify(a:path, ':t')})
    let b:bex_image_src = a:path

    " Closed imperatively rather than relying on the old buffer's own
    " BufUnload: this can run nested inside a VimResized handler, where
    " Vim suppresses nested autocmds and that cleanup path never fires.
    if l:old_buf > 0 && bufexists(l:old_buf)
        let l:old_popup = getbufvar(l:old_buf, 'bex_image_popup', -1)
        if l:old_popup > 0 && exists('*popup_close')
            call popup_close(l:old_popup)
            call setbufvar(l:old_buf, 'bex_image_popup', -1)
        endif
        if l:old_buf != bufnr('%')
            execute 'bwipeout! ' . l:old_buf
        endif
    endif

    setlocal nomodified nobuflisted nonumber norelativenumber
    setlocal signcolumn=no nowrap nolist

    nnoremap <buffer> <silent> - :call bex#ReturnFromImage()<CR>

    augroup bex_image_header
        autocmd! * <buffer>
        autocmd VimResized,WinScrolled,WinEnter <buffer> call s:reposition_image_header()
        autocmd VimResized                      <buffer> call s:redraw_image()
        autocmd BufWinLeave,BufUnload    nested  <buffer> call s:close_image_header()
    augroup END

    call s:show_image_header(a:path)
endfunction

" Reruns the backend at the window's new size; the one-shot render job has
" already exited by the time a resize happens, so it won't reflow on its own.
function! s:redraw_image() abort
    if !exists('b:bex_image_src') || &buftype !=# 'terminal' | return | endif
    call s:start_image_terminal(b:bex_image_src)
endfunction

" Bound to '-': switch back to browsing and clean up the terminal buffer.
function! bex#ReturnFromImage() abort
    if &buftype !=# 'terminal' || !exists('b:bex_image_src')
        return
    endif
    let l:img_buf = bufnr('%')
    call bex#Toggle()
    if bufexists(l:img_buf) && l:img_buf != bufnr('%')
        execute 'bwipeout! ' . l:img_buf
    endif
endfunction

function! s:open_file_or_image(path) abort
    if g:bex_image_preview && s:is_image(a:path) && exists('*term_start') && s:image_backend_available()
        call s:start_image_terminal(a:path)
        return
    endif
    execute 'edit ' . fnameescape(a:path)
endfunction

function! bex#OnSelect() abort
    if get(b:, 'bex_changes_view', 0)
        call s:revert_change_under_cursor()
        return
    endif

    let l:line = getline('.')
    let l:match = matchlist(l:line, '^\(\/[0-9a-zA-Z]\+\)\s\+\(.*\)$')

    if !empty(l:match) && has_key(b:bex_snapshot, l:match[1])
        let l:item = b:bex_snapshot[l:match[1]]

        if l:item.is_dir
            call bex#Navigate(l:item.path)
        else
            let l:bex_buf = bufnr('%')
            let l:path = l:item.path
            if winnr('$') == 1
                leftabove vsplit
                wincmd p
            endif
            setlocal nomodified
            wincmd p

            " Close the leftover bex-window split BEFORE opening the
            " target: an image preview captures the window's size the
            " instant the job launches, and closing a window is an
            " internal layout change that VimResized doesn't fire for --
            " so the split must already be gone before anything renders.
            let l:bex_win = bufwinnr(l:bex_buf)
            if l:bex_win != -1
                execute l:bex_win . 'close'
            endif
            call s:open_file_or_image(l:path)

            " By buffer number, not b:: the vsplit above briefly reopens
            " the bex buffer (recreating the popup via WinEnter), and by
            " now the current buffer is the opened file, not bex.
            let l:popup = getbufvar(l:bex_buf, 'bex_header_popup', -1)
            if l:popup > 0 && exists('*popup_close')
                call popup_close(l:popup)
            endif
            call setbufvar(l:bex_buf, 'bex_header_popup', -1)
            redraw
        endif
        return
    endif

    " No tracked ID: if it's a freshly typed directory entry that doesn't
    " exist on disk yet, enter it as a virtual directory. Lines with a
    " stale/foreign ID are left untouched.
    let l:name = trim(l:line)
    if empty(l:name) || l:name !~# '/$' || l:name =~# '^\/[0-9a-zA-Z]\+'
        return
    endif

    let l:clean = substitute(l:name, '/\+$', '', '')
    if empty(l:clean) | return | endif

    let l:sep = (b:bex_dir ==# '/' || b:bex_dir ==# '\') ? '' : '/'
    let l:target = b:bex_dir . l:sep . l:clean

    call bex#Navigate(l:target, !isdirectory(l:target))
endfunction

function! bex#UpdateVirtualDirectory(path) abort
    if g:bex_toggling | return | endif
    if get(b:, 'bex_changes_view', 0) | return | endif
    if mode() =~# '^[vV]' || mode() ==# "\<C-v>" | return | endif

    let l:state = s:merge_hidden_pending(a:path, s:QueryBuffer())
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

    call s:normalize_cache()
endfunction

function! bex#RevertChangeUnderCursor() abort
    call s:revert_change_under_cursor()
endfunction

" Toggle between the editable listing and a read-only summary of
" everything staged in g:bex_cache, rendered into the same buffer.
function! bex#ToggleChangesView() abort
    if get(b:, 'bex_changes_view', 0)
        let b:bex_changes_view = 0
        setlocal modifiable
        call s:render()

        if exists('b:bex_pre_changes_cursor')
            let l:saved = b:bex_pre_changes_cursor
            unlet b:bex_pre_changes_cursor
            let l:found = 0
            if !empty(l:saved.id)
                for l:lnum in range(s:content_start(), s:content_end())
                    if stridx(getline(l:lnum), l:saved.id) == 0
                        call cursor(l:lnum, 1)
                        let l:found = 1
                        break
                    endif
                endfor
            endif
            if !l:found
                call cursor(min([l:saved.line, line('$')]), 1)
            endif
            call s:lock_cursor()
        endif
        return
    endif

    if empty(g:bex_cache)
        echo 'bex: no pending changes'
        return
    endif

    let b:bex_pre_changes_cursor = {
        \ 'line': line('.'),
        \ 'id': matchstr(getline('.'), '^\/[0-9a-zA-Z]\+')
        \ }
    let b:bex_changes_view = 1
    call s:show_changes_in_buffer()
endfunction

" Buffer Query & State

function! s:QueryBuffer() abort
    let l:state = {
        \ 'snapshot': copy(get(b:, 'bex_snapshot', {})),
        \ 'delete': [],
        \ 'rename': [],
        \ 'entries': [],
        \ 'move_to': []
        \ }

    let l:lines = []
    for l:line in getline(s:content_start(), s:content_end())
        if !empty(trim(l:line)) | call add(l:lines, l:line) | endif
    endfor

    let l:id_counts = {}
    for l:line in l:lines
        let l:id = matchstr(l:line, '^\/[0-9a-zA-Z]\+')
        if !empty(l:id)
            let l:id_counts[l:id] = get(l:id_counts, l:id, 0) + 1
        endif
    endfor

    let l:current_ids = {}

    for l:line in l:lines
        let l:id = matchstr(l:line, '^\/[0-9a-zA-Z]\+')
        let l:name = substitute(l:line, '^\/[0-9a-zA-Z]\+\s\+', '', '')

        if !empty(l:id)
            let l:current_ids[l:id] = l:name
            if has_key(b:bex_snapshot, l:id)
                let l:old_name = b:bex_snapshot[l:id].name . (b:bex_snapshot[l:id].is_dir ? '/' : '')
                if get(l:id_counts, l:id, 0) > 1
                    if l:name !=# l:old_name
                        call add(l:state.move_to, {'id': l:id, 'name': l:name})
                    endif
                elseif l:old_name !=# l:name
                    call add(l:state.rename, {'id': l:id, 'old': l:old_name, 'new': l:name})
                endif
            else
                call add(l:state.move_to, {'id': l:id, 'name': l:name})
            endif
        else
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

" Carries forward previously staged delete/rename entries whose id isn't
" in the current buffer snapshot -- e.g. a change staged on a dotfile
" that then got hidden by toggling '.' off. Without this, callers that
" overwrite g:bex_cache with QueryBuffer()'s result would silently lose
" that pending change. entries/move_to don't need this: restore_cached_buffer()
" always re-inserts those regardless of the hidden-files setting.
function! s:merge_hidden_pending(dir, state) abort
    if !has_key(g:bex_cache, a:dir) | return a:state | endif
    let l:old = g:bex_cache[a:dir]

    for l:key in ['delete', 'rename']
        for l:item in get(l:old, l:key, [])
            if has_key(b:bex_snapshot, l:item.id) | continue | endif

            let l:seen = 0
            for l:cur in a:state[l:key]
                if l:cur.id ==# l:item.id | let l:seen = 1 | break | endif
            endfor
            if l:seen | continue | endif

            call add(a:state[l:key], l:item)
            if has_key(l:old.snapshot, l:item.id) && !has_key(a:state.snapshot, l:item.id)
                let a:state.snapshot[l:item.id] = l:old.snapshot[l:item.id]
            endif
        endfor
    endfor

    return a:state
endfunction

" File System Application

" If a directory is itself staged for deletion, descendant deletes are
" redundant -- deleting the directory already removes them recursively.
function! s:prune_redundant_deletes() abort
    let l:deleted_dirs = []
    for [l:dir, l:state] in items(g:bex_cache)
        for l:del in get(l:state, 'delete', [])
            if has_key(l:state.snapshot, l:del.id) && l:state.snapshot[l:del.id].is_dir
                call add(l:deleted_dirs, l:state.snapshot[l:del.id].path)
            endif
        endfor
    endfor

    if empty(l:deleted_dirs) | return | endif

    for l:cdir in keys(copy(g:bex_cache))
        let l:covered = 0
        for l:parent in l:deleted_dirs
            if l:cdir ==# l:parent || stridx(l:cdir, l:parent . '/') == 0
                let l:covered = 1 | break
            endif
        endfor
        if !l:covered | continue | endif

        let l:cstate = g:bex_cache[l:cdir]
        if empty(l:cstate.delete) | continue | endif
        let l:cstate.delete = []
        let g:bex_cache[l:cdir] = l:cstate

        if empty(l:cstate.rename) && empty(l:cstate.entries) && empty(l:cstate.move_to)
            call remove(g:bex_cache, l:cdir)
        endif
    endfor
endfunction

" A virtual (not-yet-on-disk) directory only stays "staged" as long as
" it's still reachable via an unbroken chain of pending creations.
function! s:virtual_dir_will_be_created(path) abort
    let l:parent = fnamemodify(a:path, ':h')
    if l:parent ==# a:path | return 0 | endif
    let l:name = fnamemodify(a:path, ':t') . '/'

    if !isdirectory(l:parent) && !s:virtual_dir_will_be_created(l:parent)
        return 0
    endif

    if !has_key(g:bex_cache, l:parent) | return 0 | endif
    let l:pstate = g:bex_cache[l:parent]

    for l:ent in get(l:pstate, 'entries', [])
        if l:ent ==# l:name | return 1 | endif
    endfor
    for l:mov in get(l:pstate, 'move_to', [])
        if l:mov.name ==# l:name | return 1 | endif
    endfor
    return 0
endfunction

function! s:prune_orphaned_virtual_dirs() abort
    let l:to_remove = []
    for l:vdir in keys(g:bex_cache)
        if !isdirectory(l:vdir) && !s:virtual_dir_will_be_created(l:vdir)
            call add(l:to_remove, l:vdir)
        endif
    endfor
    for l:vdir in l:to_remove
        call remove(g:bex_cache, l:vdir)
    endfor
endfunction

function! s:normalize_cache() abort
    call s:prune_redundant_deletes()
    call s:prune_orphaned_virtual_dirs()
endfunction

function! s:validate_all() abort
    let l:errors = []
    let l:conflicts = []

    for [l:dir, l:state] in items(g:bex_cache)
        let l:sep = (l:dir ==# '/' || l:dir ==# '\') ? '' : '/'

        for l:ren in l:state.rename
            if !has_key(l:state.snapshot, l:ren.id) | continue | endif
            let l:dest = fnamemodify(l:state.snapshot[l:ren.id].path, ':h')
                \ . '/' . substitute(l:ren.new, '/$', '', '')
            if filereadable(l:dest) || isdirectory(l:dest)
                let l:vacating = 0
                for [l:snap_id, l:snap_item] in items(l:state.snapshot)
                    if l:snap_item.path ==# l:dest && l:snap_id !=# l:ren.id
                        for l:d in get(l:state, 'delete', [])
                            if l:d.id ==# l:snap_id | let l:vacating = 1 | break | endif
                        endfor
                        if !l:vacating
                            for l:r in get(l:state, 'rename', [])
                                if l:r.id ==# l:snap_id && l:r.id !=# l:ren.id
                                    let l:vacating = 1 | break
                                endif
                            endfor
                        endif
                    endif
                endfor
                if !l:vacating
                    call add(l:errors, 'rename conflict, destination already exists: ' . l:dest)
                endif
            endif
        endfor

        for l:mov in l:state.move_to
            let l:dst = l:dir . l:sep . substitute(l:mov.name, '/$', '', '')
            let l:src = ''
            for [l:sdir, l:ssnap] in items(g:bex_snapshots)
                if has_key(l:ssnap, l:mov.id)
                    let l:src = l:ssnap[l:mov.id].path
                    break
                endif
            endfor
            if empty(l:src)
                call add(l:errors, 'move/copy: source not found for id: ' . l:mov.id)
                continue
            endif
            if !filereadable(l:src) && !isdirectory(l:src)
                call add(l:errors, 'move/copy: source missing on disk: ' . l:src)
                continue
            endif
            if (filereadable(l:dst) || isdirectory(l:dst)) && l:dst !=# l:src
                let l:vacating = 0
                let l:clean_dst = fnamemodify(l:dst, ':t')
                for [l:snap_id, l:snap_item] in items(l:state.snapshot)
                    if l:snap_item.name ==# l:clean_dst
                        for l:d in get(l:state, 'delete', [])
                            if l:d.id ==# l:snap_id | let l:vacating = 1 | break | endif
                        endfor
                        if !l:vacating
                            for l:ren in get(l:state, 'rename', [])
                                if l:ren.id ==# l:snap_id | let l:vacating = 1 | break | endif
                            endfor
                        endif
                        break
                    endif
                endfor
                if !l:vacating
                    call add(l:conflicts, {'dir': l:dir, 'ent': l:mov.name, 'path': l:dst})
                endif
            endif
        endfor

        for l:ent in l:state.entries
            let l:path = l:dir . l:sep . substitute(l:ent, '/$', '', '')
            if filereadable(l:path) || isdirectory(l:path)
                let l:vacating = 0
                let l:clean_ent = substitute(l:ent, '/$', '', '')
                for [l:snap_id, l:snap_item] in items(l:state.snapshot)
                    if l:snap_item.name ==# l:clean_ent
                        for l:d in get(l:state, 'delete', [])
                            if l:d.id ==# l:snap_id | let l:vacating = 1 | break | endif
                        endfor
                        if !l:vacating
                            for l:ren in get(l:state, 'rename', [])
                                if l:ren.id ==# l:snap_id | let l:vacating = 1 | break | endif
                            endfor
                        endif
                        break
                    endif
                endfor
                if !l:vacating
                    call add(l:conflicts, {'dir': l:dir, 'ent': l:ent, 'path': l:path})
                endif
            endif
        endfor
    endfor

    return {'errors': l:errors, 'conflicts': l:conflicts}
endfunction

function! s:on_write() abort
    if get(b:, 'bex_changes_view', 0)
        let b:bex_changes_view = 0
        setlocal modifiable
        call s:render()
    else
        call bex#UpdateVirtualDirectory(b:bex_dir)
    endif

    if empty(g:bex_cache) | setlocal nomodified | return | endif

    let l:result = s:validate_all()

    if !empty(l:result.errors)
        echohl ErrorMsg
        for l:e in l:result.errors
            echoerr 'bex: ' . l:e
        endfor
        echohl None
        return
    endif

    if !empty(l:result.conflicts)
        echo 'bex: Files already exist and would be replaced:'
        for l:c in l:result.conflicts | echo '  ' . l:c.path | endfor
        let l:ans = input('bex: Replace existing files? [y/N]: ')
        echo ''
        if l:ans !=# 'y' && l:ans !=# 'Y'
            for l:c in l:result.conflicts
                if has_key(g:bex_cache, l:c.dir)
                    let g:bex_cache[l:c.dir].entries =
                        \ filter(copy(g:bex_cache[l:c.dir].entries),
                        \        {_, v -> v !=# l:c.ent})
                endif
            endfor
            let l:any_left = 0
            for l:st in values(g:bex_cache)
                if !empty(l:st.delete) || !empty(l:st.rename)
                    \ || !empty(l:st.entries) || !empty(l:st.move_to)
                    let l:any_left = 1 | break
                endif
            endfor
            if !l:any_left | setlocal nomodified | return | endif
        endif
    endif

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
                let l:del_display = l:dir . '/' . l:del.name . (has_key(l:state.snapshot, l:del.id) && l:state.snapshot[l:del.id].is_dir ? '/' : '')
                call add(l:all_dels, l:del_display)
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

" Renames go through the OS move command (matching how copies are done
" elsewhere) rather than Vim's rename() builtin. Sets v:shell_error.
function! s:native_move(src, dst) abort
    let l:cmd = (has('win32') || has('win64')) ? 'move /Y ' : 'mv '
    call system(l:cmd . shellescape(a:src) . ' ' . shellescape(a:dst))
endfunction

function! s:apply_all() abort
    call s:normalize_cache()

    let l:cursor_line = line('.')
    let l:cursor_id = matchstr(getline('.'), '^\/[0-9a-zA-Z]\+')
    let l:cursor_path = (!empty(l:cursor_id) && has_key(b:bex_snapshot, l:cursor_id))
        \ ? b:bex_snapshot[l:cursor_id].path : ''

    for [l:dir, l:state] in items(g:bex_cache)
        let l:tmps = []
        for l:ren in l:state.rename
            if !has_key(l:state.snapshot, l:ren.id) | continue | endif
            let l:old_p = l:state.snapshot[l:ren.id].path
            " Stage through a collision-safe temp name first, so chained
            " or swapped renames (A->B, B->A) never clash mid-flight.
            let l:tmp_p = fnamemodify(l:old_p, ':h') . '/.bex-tmp-'
                \ . fnamemodify(tempname(), ':t') . '-' . fnamemodify(l:old_p, ':t')
            call s:native_move(l:old_p, l:tmp_p)
            if v:shell_error != 0
                echoerr 'bex: rename to tmp failed: ' . l:old_p
                continue
            endif
            let l:dest = fnamemodify(l:old_p, ':h') . '/' . substitute(l:ren.new, '/$', '', '')
            call add(l:tmps, {'tmp': l:tmp_p, 'dest': l:dest})
        endfor
        for l:t in l:tmps
            call s:native_move(l:t.tmp, l:t.dest)
            if v:shell_error != 0
                echoerr 'bex: rename failed: ' . l:t.tmp . ' -> ' . l:t.dest
            endif
        endfor
    endfor

    for [l:dir, l:state] in items(g:bex_cache)
        let l:sep = (l:dir ==# '/' || l:dir ==# '\') ? '' : '/'

        if !isdirectory(l:dir) && !filereadable(l:dir)
            call mkdir(l:dir, 'p')
        endif

        for l:mov in l:state.move_to
            let l:src = ''
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
                if v:shell_error != 0
                    echoerr 'bex: copy failed (exit ' . v:shell_error . '): ' . l:src . ' -> ' . l:dst
                endif
            else
                if rename(l:src, l:dst) != 0
                    echoerr 'bex: move failed: ' . l:src . ' -> ' . l:dst
                else
                    let g:bex_path_ids[l:dst] = s:decode_id(matchstr(l:mov.id, '[0-9a-zA-Z]\+$'))
                    if has_key(g:bex_path_ids, l:src) | call remove(g:bex_path_ids, l:src) | endif
                endif
            endif
        endfor

        for l:del in l:state.delete
            let l:still_exists = 0
            for [l:tdir, l:tstate] in items(g:bex_cache)
                for l:m in l:tstate.move_to
                    if l:m.id ==# l:del.id | let l:still_exists = 1 | break | endif
                endfor
            endfor
            if l:still_exists | continue | endif

            if !has_key(l:state.snapshot, l:del.id) | continue | endif
            let l:p = l:state.snapshot[l:del.id].path

            let l:renamed_onto = 0
            for [l:rdir, l:rstate] in items(g:bex_cache)
                for l:ren in l:rstate.rename
                    if l:ren.id !=# l:del.id && has_key(l:rstate.snapshot, l:ren.id)
                        let l:ren_dest = fnamemodify(l:rstate.snapshot[l:ren.id].path, ':h')
                            \ . '/' . substitute(l:ren.new, '/$', '', '')
                        if l:ren_dest ==# l:p
                            let l:renamed_onto = 1 | break
                        endif
                    endif
                endfor
                if l:renamed_onto | break | endif
            endfor
            if l:renamed_onto | continue | endif

            let l:copy_landing = 0
            for [l:tdir, l:tstate] in items(g:bex_cache)
                let l:tsep = (l:tdir ==# '/' || l:tdir ==# '\') ? '' : '/'
                for l:m in l:tstate.move_to
                    if l:m.id !=# l:del.id
                        let l:m_dst = l:tdir . l:tsep . substitute(l:m.name, '/$', '', '')
                        if l:m_dst ==# l:p
                            let l:copy_landing = 1 | break
                        endif
                    endif
                endfor
                if l:copy_landing | break | endif
            endfor
            if l:copy_landing | continue | endif

            if delete(l:p, isdirectory(l:p) ? 'rf' : '') != 0
                echoerr 'bex: delete failed: ' . l:p
            endif
        endfor

        for l:ent in l:state.entries
            let l:path = l:dir . l:sep . substitute(l:ent, '/$', '', '')
            if l:ent =~# '/$'
                if mkdir(l:path, 'p') != 1
                    echoerr 'bex: mkdir failed: ' . l:path
                endif
            else
                if writefile([], l:path) != 0
                    echoerr 'bex: create failed: ' . l:path
                endif
            endif
        endfor
    endfor

    let g:bex_cache      = {}
    let g:bex_snapshots  = {}
    let g:bex_id_counter = 0
    let g:bex_path_ids   = {}
    let g:bex_cursor_pos = {}

    setlocal nomodified

    call s:render()

    let l:target_id = ''
    if !empty(l:cursor_path)
        for [l:id, l:item] in items(b:bex_snapshot)
            if l:item.path ==# l:cursor_path
                let l:target_id = l:id
                break
            endif
        endfor
    endif

    if !empty(l:target_id)
        for l:lnum in range(s:content_start(), s:content_end())
            if stridx(getline(l:lnum), l:target_id) == 0
                call cursor(l:lnum, 1)
                break
            endif
        endfor
    else
        call cursor(min([l:cursor_line, line('$')]), 1)
    endif
    call s:lock_cursor()
endfunction

function! s:on_unload() abort
    let l:dir = get(b:, 'bex_dir', '')
    if !empty(l:dir) && has_key(g:bex_cache, l:dir)
        call remove(g:bex_cache, l:dir)
    endif
endfunction

function! s:on_quit() abort
    let l:buf = bufnr('%')

    if get(b:, 'bex_changes_view', 0)
        let b:bex_changes_view = 0
        setlocal modifiable
        call s:render()
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

" Rendering

" IDs are '/' + 4 base62 characters (62^4 ~= 14.7M values per session) so
" they read shorter on screen than the previous 8-digit hex.
let s:bex_id_alphabet = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
let s:bex_id_base = len(s:bex_id_alphabet)
let s:bex_id_len = 4

function! s:encode_id(n) abort
    let l:n = a:n
    let l:chars = []
    for l:i in range(s:bex_id_len)
        let l:chars = [s:bex_id_alphabet[l:n % s:bex_id_base]] + l:chars
        let l:n = l:n / s:bex_id_base
    endfor
    return join(l:chars, '')
endfunction

function! s:decode_id(str) abort
    let l:n = 0
    for l:c in split(a:str, '\zs')
        let l:idx = stridx(s:bex_id_alphabet, l:c)
        if l:idx < 0 | return -1 | endif
        let l:n = l:n * s:bex_id_base + l:idx
    endfor
    return l:n
endfunction

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

        let l:id = '/' . s:encode_id(g:bex_path_ids[l:p])
        let l:is_dir  = isdirectory(l:p)
        " executable() checks this exact file (l:p always has a path
        " separator, so it never falls back to a $PATH search).
        let l:is_exec = !l:is_dir && executable(l:p)
        let l:is_link = getftype(l:p) ==# 'link'
        let l:link_target = l:is_link ? resolve(l:p) : ''

        " Only '/' is baked into real buffer text -- it's load-bearing
        " (BexDir syntax match, virtual-directory check, dir renaming).
        " The exec/symlink markers are purely informational virtual text
        " instead (see s:reapply_props()), since making them real text
        " broke QueryBuffer()'s rename detection.
        let l:suffix  = l:is_dir ? '/' : ''
        let l:lines += [l:id . ' ' . l:name . l:suffix]
        let b:bex_snapshot[l:id] = {'name': l:name, 'is_dir': l:is_dir, 'is_exec': l:is_exec,
            \ 'is_link': l:is_link, 'link_target': l:link_target, 'path': l:p}
    endfor

    let g:bex_snapshots[b:bex_dir] = copy(b:bex_snapshot)

    silent %delete _
    if g:bex_header_at_bottom
        call setline(1, l:lines + [''])
        if line('$') == 1 | call append(0, '') | endif
    else
        call setline(1, [''] + l:lines)
        if line('$') == 1 | call append(1, '') | endif
    endif
    setlocal nomodified

    call s:reapply_props()
    call s:restore_cached_buffer()
    call s:position_header_popup()
    call s:lock_cursor()
endfunction

function! s:restore_cached_buffer() abort
    if !has_key(g:bex_cache, b:bex_dir) | return | endif
    let l:state = g:bex_cache[b:bex_dir]
    let l:start = s:content_start()

    for l:del in l:state.delete
        for l:lnum in range(s:content_end(), l:start, -1)
            if stridx(getline(l:lnum), l:del.id) == 0 | silent execute l:lnum . 'd _' | break | endif
        endfor
    endfor

    for l:ren in l:state.rename
        for l:lnum in range(l:start, s:content_end())
            if stridx(getline(l:lnum), l:ren.id) == 0
                call setline(l:lnum, l:ren.id . ' ' . l:ren.new) | break
            endif
        endfor
    endfor

    for l:mov in l:state.move_to
        let l:found = 0
        let l:expected = l:mov.id . ' ' . l:mov.name
        for l:lnum in range(l:start, s:content_end())
            if getline(l:lnum) ==# l:expected | let l:found = 1 | break | endif
        endfor
        if !l:found | call s:append_content(l:expected) | endif
    endfor

    for l:ent in l:state.entries
        let l:found = 0
        for l:lnum in range(l:start, s:content_end()) | if getline(l:lnum) ==# l:ent | let l:found = 1 | break | endif | endfor
        if !l:found | call s:append_content(l:ent) | endif
    endfor

    if g:bex_header_at_bottom
        while line('$') > 2 && empty(trim(getline(1)))
            silent execute '1d _'
        endwhile
        while line('$') > 2 && empty(trim(getline(line('$') - 1)))
            silent execute (line('$') - 1) . 'd _'
        endwhile
        if line('$') < 2 || !empty(trim(getline(line('$'))))
            call append(line('$'), '')
        endif
    else
        while line('$') > 2 && empty(trim(getline(2)))
            silent execute '2d _'
        endwhile
        while line('$') > 2 && empty(trim(getline(line('$'))))
            silent execute line('$') . 'd _'
        endwhile
        if line('$') == 1 | call append(1, '') | endif
    endif

    setlocal nomodified
endfunction

" First and one-past-last real content line. Top mode: line 1 is the
" reserved spacer, content is [2, line('$')]. Bottom mode: the last line
" is the spacer, content is [1, line('$')-1]. Re-evaluated on every call.
function! s:content_start() abort
    return g:bex_header_at_bottom ? 1 : 2
endfunction

function! s:content_end() abort
    return g:bex_header_at_bottom ? line('$') - 1 : line('$')
endfunction

function! s:append_content(text) abort
    if g:bex_header_at_bottom
        call append(line('$') - 1, a:text)
    else
        call append(line('$'), a:text)
    endif
endfunction

" The header lives in a popup anchored to the window's screen position, so
" it can never become stray buffer text. One end of the buffer (line 1 in
" top mode, the last line in bottom mode) is kept as a permanent blank
" spacer for it to sit over.
function! s:enforce_spacer() abort
    if !exists('b:bex_dir') | return | endif
    if get(b:, 'bex_changes_view', 0) | return | endif
    if g:bex_header_at_bottom
        if !empty(getline(line('$')))
            call append(line('$'), '')
        endif
        if line('$') < 2
            call append(0, '')
        endif
    else
        if !empty(getline(1))
            call append(0, '')
        endif
        if line('$') < 2
            call append(line('$'), '')
        endif
    endif
endfunction

function! s:close_header_popup() abort
    if exists('b:bex_header_popup') && b:bex_header_popup > 0
        call popup_close(b:bex_header_popup)
    endif
    let b:bex_header_popup = -1
endfunction

function! s:bex_register_popup(popup_id, bufnr) abort
    let g:bex_popup_registry[a:popup_id] = a:bufnr
endfunction

" Closes any registered popup that's been superseded (its buffer's current
" b:bex_header_popup/b:bex_image_popup no longer matches, or the buffer is
" gone) and repositions everything else. Buffer-local resize/scroll
" autocmds only fire for the window they're on -- a bex window sitting
" untouched in the background while a new split is opened elsewhere never
" gets one -- so this runs on broad, buffer-independent events instead and
" catches every popup, not just the active window's.
function! s:bex_gc_popups() abort
    if !exists('*popup_close') || !exists('*popup_getpos') | return | endif
    let l:orig_win = win_getid()
    for [l:id_str, l:bufnr] in items(g:bex_popup_registry)
        let l:id = str2nr(l:id_str)
        let l:current_header = bufexists(l:bufnr) ? getbufvar(l:bufnr, 'bex_header_popup', -1) : -1
        let l:current_image  = bufexists(l:bufnr) ? getbufvar(l:bufnr, 'bex_image_popup', -1)  : -1

        if l:current_header != l:id && l:current_image != l:id
            if !empty(popup_getpos(l:id))
                call popup_close(l:id)
            endif
            call remove(g:bex_popup_registry, l:id_str)
            continue
        endif

        let l:winnr = bufwinnr(l:bufnr)
        if l:winnr != -1
            execute l:winnr . 'wincmd w'
            if l:current_header == l:id
                call s:position_header_popup()
            else
                call s:reposition_image_header()
            endif
        endif
    endfor
    call win_gotoid(l:orig_win)
endfunction

augroup bex_popup_gc
    autocmd!
    autocmd VimResized,WinEnter,BufWinEnter,TabEnter,CursorHold,CursorHoldI * call s:bex_gc_popups()
augroup END
if exists('##WinClosed')
    augroup bex_popup_gc
        autocmd WinClosed * call s:bex_gc_popups()
    augroup END
endif

" Closes every b:bex_header_popup/b:bex_image_popup across ALL buffers.
" Needed by bex#Reload(): it only knows about 'bex' filetype buffers, but
" an open image preview lives in a plain terminal buffer whose own cleanup
" can race with (or be skipped by) the buffer swap Reload() does.
function! s:close_all_bex_popups() abort
    if !exists('*popup_close') | return | endif
    for l:buf in range(1, bufnr('$'))
        if !bufexists(l:buf) | continue | endif
        for l:var in ['bex_header_popup', 'bex_image_popup']
            let l:popup = getbufvar(l:buf, l:var, -1)
            if l:popup > 0
                call popup_close(l:popup)
                call setbufvar(l:buf, l:var, -1)
            endif
        endfor
    endfor
endfunction

" Mirrors the bex header popup for an open image preview. Runs its own
" small autogroup on the terminal buffer (wired up in
" s:start_image_terminal()) since bex#OnSelect() always closes the bex
" window once the image is showing, so b:bex_header_popup/bex_events no
" longer apply.
function! s:show_image_header(path) abort
    if !exists('*popup_create') | return | endif

    let l:winid = win_getid()
    let l:screenpos = win_screenpos(l:winid)
    if l:screenpos[0] == 0 | return | endif

    call s:ensure_header_highlights()

    let l:home = expand('$HOME')
    let l:text = stridx(a:path, l:home) == 0 ? '~/' . a:path[len(l:home)+1:] : a:path
    let l:content = [{'text': l:text, 'props': []}]

    let l:row = g:bex_header_at_bottom
        \ ? l:screenpos[0] + winheight(l:winid) - 1
        \ : l:screenpos[0]

    let b:bex_image_popup = popup_create(l:content, {
        \ 'line': l:row,
        \ 'col': l:screenpos[1],
        \ 'pos': 'topleft',
        \ 'minwidth': winwidth(l:winid),
        \ 'maxwidth': winwidth(l:winid),
        \ 'wrap': 0,
        \ 'highlight': 'BexHeader',
        \ 'zindex': 50,
        \ })
    call s:bex_register_popup(b:bex_image_popup, bufnr('%'))
endfunction

function! s:reposition_image_header() abort
    if !exists('b:bex_image_popup') || b:bex_image_popup <= 0 | return | endif
    let l:winid = win_getid()
    let l:screenpos = win_screenpos(l:winid)
    if l:screenpos[0] == 0 | return | endif
    let l:row = g:bex_header_at_bottom
        \ ? l:screenpos[0] + winheight(l:winid) - 1
        \ : l:screenpos[0]
    call popup_move(b:bex_image_popup, {
        \ 'line': l:row,
        \ 'col': l:screenpos[1],
        \ 'minwidth': winwidth(l:winid),
        \ 'maxwidth': winwidth(l:winid),
        \ })
endfunction

function! s:close_image_header() abort
    if exists('b:bex_image_popup') && b:bex_image_popup > 0
        call popup_close(b:bex_image_popup)
    endif
    let b:bex_image_popup = -1
endfunction

" Keeps the cursor off the reserved spacer line in any mode. In
" Visual/Visual-block mode this only moves the active end of the
" selection, so it clamps rather than cancels a selection.
function! s:lock_cursor() abort
    if get(b:, 'bex_changes_view', 0) | return | endif
    if g:bex_header_at_bottom
        if line('.') == line('$') && line('$') > 1
            call cursor(line('$') - 1, 1)
        endif
    else
        if line('.') == 1 && line('$') > 1
            call cursor(2, 1)
        endif
    endif
endfunction

function! s:ensure_header_highlights() abort
    " Must exist before prop_type_add below (which throws E970 otherwise) --
    " this used to fire on every CursorMoved and eat the user's next keypress.
    highlight default BexDotfilesOn  ctermfg=Green guifg=#98c379
    highlight default BexDotfilesOff ctermfg=Red   guifg=#e06c75

    if empty(prop_type_get('BexDotfilesOn'))
        call prop_type_add('BexDotfilesOn', {'highlight': 'BexDotfilesOn'})
    endif
    if empty(prop_type_get('BexDotfilesOff'))
        call prop_type_add('BexDotfilesOff', {'highlight': 'BexDotfilesOff'})
    endif
endfunction

" Compact single-line summary of the current directory's pending changes,
" e.g. "-old.txt ~renamed.txt +new.txt". Truncated by the caller to fit.
function! s:change_summary_text() abort
    if !has_key(g:bex_cache, b:bex_dir) | return '' | endif
    let l:state = g:bex_cache[b:bex_dir]
    let l:parts = []
    for l:d in get(l:state, 'delete', [])
        call add(l:parts, '-' . l:d.name)
    endfor
    for l:r in get(l:state, 'rename', [])
        call add(l:parts, '~' . l:r.new)
    endfor
    for l:m in get(l:state, 'move_to', [])
        call add(l:parts, '+' . l:m.name)
    endfor
    for l:e in get(l:state, 'entries', [])
        call add(l:parts, '+' . l:e)
    endfor
    return join(l:parts, ' ')
endfunction

function! s:position_header_popup() abort
    if !exists('*popup_create') | return | endif
    if !exists('b:bex_dir') || &filetype !=# 'bex' | return | endif

    let l:winid = win_getid()
    let l:screenpos = win_screenpos(l:winid)
    if l:screenpos[0] == 0 | return | endif

    call s:ensure_header_highlights()

    let l:home = expand('$HOME')
    let l:left = stridx(b:bex_dir, l:home) == 0 ? '~/' . b:bex_dir[len(l:home)+1:] : b:bex_dir
    if !isdirectory(b:bex_dir)
        let l:left .= '  [new]'
    endif
    let l:right    = g:bex_show_hidden ? 'dotfiles=on' : 'dotfiles=off'
    let l:right_hl = g:bex_show_hidden ? 'BexDotfilesOn' : 'BexDotfilesOff'

    let l:summary = s:change_summary_text()
    if !empty(l:summary)
        let l:avail = winwidth(l:winid) - strdisplaywidth(l:left) - strdisplaywidth(l:right) - 6
        if l:avail < 1
            let l:summary = ''
        elseif strdisplaywidth(l:summary) > l:avail
            let l:summary = strcharpart(l:summary, 0, max([l:avail - 3, 0])) . '...'
        endif
    endif
    let l:left_full = empty(l:summary) ? l:left : l:left . '  ' . l:summary

    let l:width = max([winwidth(l:winid), strdisplaywidth(l:left_full) + strdisplaywidth(l:right) + 1])
    let l:pad   = max([l:width - strdisplaywidth(l:left_full) - strdisplaywidth(l:right), 1])
    let l:text  = l:left_full . repeat(' ', l:pad) . l:right

    let l:right_col = len(l:left_full) + l:pad + 1
    let l:content = [{
        \ 'text': l:text,
        \ 'props': [{'col': l:right_col, 'length': len(l:right), 'type': l:right_hl}]
        \ }]

    let l:row = g:bex_header_at_bottom
        \ ? l:screenpos[0] + winheight(l:winid) - 1
        \ : l:screenpos[0]

    let l:opts = {
        \ 'line': l:row,
        \ 'col': l:screenpos[1],
        \ 'pos': 'topleft',
        \ 'minwidth': winwidth(l:winid),
        \ 'maxwidth': winwidth(l:winid),
        \ 'wrap': 0,
        \ 'highlight': 'BexHeader',
        \ 'zindex': 50,
        \ }

    if !exists('b:bex_header_popup') || b:bex_header_popup <= 0 || empty(popup_getpos(b:bex_header_popup))
        let b:bex_header_popup = popup_create(l:content, l:opts)
        call s:bex_register_popup(b:bex_header_popup, bufnr('%'))
    else
        call popup_settext(b:bex_header_popup, l:content)
        call popup_move(b:bex_header_popup, l:opts)
    endif
endfunction

function! s:reapply_props() abort
    if get(b:, 'bex_changes_view', 0) | return | endif

    if empty(prop_type_get('bex_info')) | call prop_type_add('bex_info', {'highlight': 'BexInfo'}) | endif
    if empty(prop_type_get('bex_exec_marker')) | call prop_type_add('bex_exec_marker', {'highlight': 'BexExec'}) | endif
    if empty(prop_type_get('bex_symlink_marker')) | call prop_type_add('bex_symlink_marker', {'highlight': 'BexSymlink'}) | endif

    call prop_clear(1, line('$'))

    for l:lnum in range(s:content_start(), s:content_end())
        let l:id = matchstr(getline(l:lnum), '^\/[0-9a-zA-Z]\{4}')
        if empty(l:id) || !has_key(b:bex_snapshot, l:id) | continue | endif
        let l:item = b:bex_snapshot[l:id]
        let l:p = l:item.path
        let l:size = l:item.is_dir ? '' : s:human_size(getfsize(l:p))
        let l:info = printf('%-10s %8s %10s', getfperm(l:p), l:size, s:relative_time(getftime(l:p)))
        call prop_add(l:lnum, 0, {'type': 'bex_info', 'text': l:info, 'text_align': 'right'})

        " Purely informational virtual text, same reasoning as the '/'
        " comment in s:render() -- never part of the real buffer line.
        let l:col = len(getline(l:lnum)) + 1
        if l:item.is_exec
            call prop_add(l:lnum, l:col, {'type': 'bex_exec_marker', 'text': '*'})
        endif
        if get(l:item, 'is_link', 0)
            call prop_add(l:lnum, l:col, {'type': 'bex_symlink_marker', 'text': '@ -> ' . l:item.link_target})
        endif
    endfor

    syntax clear
    syntax match BexDir        /\%(\/[0-9a-zA-Z]\+\s\+\|\s*\)\zs[^/].\+\/$/
    syntax match BexDir        /\zs\S\+\/$/
    syntax match BexHiddenDir  /\zs\.[^/]*\/$/
    syntax match BexHiddenFile /\%(^\s*\|\s\)\zs\.[^/]\+$/
    syntax match BexFile       /\%(^\s*\|\s\)\zs[^.\/[:space:]][^\/]*$/
    syntax match BexID         /^\/[0-9a-zA-Z]\+\ze\s\+[^.[:space:]]/
    syntax match BexHiddenID   /^\/[0-9a-zA-Z]\+\ze\s\+\./
endfunction

" Changes View -- toggled in-place with <Tab>. Builds a read-only
" rendering of everything staged across g:bex_cache directly into the
" current buffer; <Tab> again (or writing) returns to the editable listing.

" {lines, highlights} for every directory with pending changes in
" g:bex_cache -- the full picture, not just the current directory (that
" scoping is for the header-popup summary instead).
function! s:build_changes_content() abort
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
        call add(l:highlights, {'lnum': l:lnum, 'hl': 'BexChangesDir'})
        let l:lnum += 1

        for l:del in get(l:state, 'delete', [])
            let l:del_name = l:del.name . (has_key(l:state.snapshot, l:del.id) && l:state.snapshot[l:del.id].is_dir ? '/' : '')
            call add(l:lines, '   - ' . l:del.id . ' ' . l:del_name)
            call add(l:highlights, {'lnum': l:lnum, 'hl': has_key(l:global_placements, l:del.id) ? 'BexChangesMoveFrom' : 'BexChangesDel'})
            let l:lnum += 1
        endfor

        for l:ren in get(l:state, 'rename', [])
            call add(l:lines, '   ~ ' . l:ren.id . ' ' . l:ren.old . ' -> ' . l:ren.new)
            call add(l:highlights, {'lnum': l:lnum, 'hl': 'BexChangesRename'})
            let l:lnum += 1
        endfor

        for l:mov in get(l:state, 'move_to', [])
            if has_key(l:global_deletions, l:mov.id)
                call add(l:lines, '   + ' . l:mov.id . ' ' . l:mov.name)
                call add(l:highlights, {'lnum': l:lnum, 'hl': 'BexChangesMoveTo'})
            else
                call add(l:lines, '   * ' . l:mov.id . ' ' . l:mov.name)
                call add(l:highlights, {'lnum': l:lnum, 'hl': 'BexChangesCopy'})
            endif
            let l:lnum += 1
        endfor

        for l:ent in get(l:state, 'entries', [])
            call add(l:lines, '   + (new) ' . l:ent)
            call add(l:highlights, {'lnum': l:lnum, 'hl': 'BexChangesAdd'})
            let l:lnum += 1
        endfor

        call add(l:lines, '')
        let l:lnum += 1
    endfor

    if !empty(l:lines) && empty(l:lines[-1])
        call remove(l:lines, -1)
    endif

    return {'lines': l:lines, 'highlights': l:highlights}
endfunction

function! s:show_changes_in_buffer() abort
    let l:content = s:build_changes_content()
    let l:lines = empty(l:content.lines) ? ['(no pending changes)'] : l:content.lines
    let l:highlights = copy(l:content.highlights)

    " Reserve a blank line for the header popup, same convention as the
    " listing view.
    if g:bex_header_at_bottom
        let l:lines = l:lines + ['']
    else
        let l:lines = [''] + l:lines
        let l:highlights = map(l:highlights, {_, v -> extend(v, {'lnum': v.lnum + 1})})
    endif

    " Must exist before prop_type_add below (E970 otherwise).
    highlight default BexChangesDir      cterm=bold    gui=bold
    highlight default BexChangesDel      ctermfg=Red   guifg=#e06c75
    highlight default BexChangesMoveFrom ctermfg=Red   guifg=#e06c75 cterm=italic gui=italic
    highlight default BexChangesRename   ctermfg=Yellow guifg=#e5c07b
    highlight default BexChangesMoveTo   ctermfg=Green guifg=#98c379
    highlight default BexChangesCopy     ctermfg=Green guifg=#98c379 cterm=italic gui=italic
    highlight default BexChangesAdd      ctermfg=Green guifg=#98c379

    setlocal modifiable
    silent %delete _
    call setline(1, l:lines)
    setlocal nomodifiable nomodified

    call prop_clear(1, line('$'))
    for l:item in l:highlights
        if empty(prop_type_get(l:item.hl))
            call prop_type_add(l:item.hl, {'highlight': l:item.hl})
        endif
        call prop_add(l:item.lnum, 1, {
            \ 'end_col': len(getline(l:item.lnum)) + 1,
            \ 'type': l:item.hl
            \ })
    endfor

    call cursor(g:bex_header_at_bottom ? 1 : min([2, line('$')]), 1)
    call s:position_header_popup()
endfunction

" Which directory a changes-view line belongs to, by scanning upward for
" the nearest unindented header line (item lines are always indented).
function! s:changes_view_owner_dir(lnum) abort
    let l:owner_dir = ''
    let l:home = expand('$HOME')
    for l:ln in range(a:lnum - 1, 1, -1)
        let l:hdr = trim(getline(l:ln))
        if empty(l:hdr) | continue | endif
        if l:hdr =~# '^[+~*-]\s' | continue | endif
        let l:expanded = substitute(l:hdr, '^\~/', l:home . '/', '')
        let l:expanded = substitute(l:expanded, '[/\\]$', '', '')
        if has_key(g:bex_cache, l:expanded)
            let l:owner_dir = l:expanded
        endif
        break
    endfor
    return l:owner_dir
endfunction

function! s:revert_change_under_cursor() abort
    let l:save_lnum = line('.')
    let l:line = getline('.')
    let l:id = matchstr(l:line, '\/[0-9a-zA-Z]\+')

    if empty(l:id)
        let l:entry_name = matchstr(l:line, '^\s*[+~*-]\s\+(new)\s\+\zs.*')
        if empty(l:entry_name) | return | endif

        let l:owner_dir = s:changes_view_owner_dir(l:save_lnum)
        if empty(l:owner_dir) | return | endif
        let l:state = g:bex_cache[l:owner_dir]
        let l:state.entries = filter(copy(l:state.entries), {_, v -> v !=# l:entry_name})
        let g:bex_cache[l:owner_dir] = l:state
        if empty(l:state.delete) && empty(l:state.rename)
            \ && empty(l:state.entries) && empty(l:state.move_to)
            call remove(g:bex_cache, l:owner_dir)
        endif
    else
        " Scoped to this line's directory and this exact entry: matching
        " by id alone would wipe every move_to sharing that source id
        " (e.g. the same file pasted into several directories).
        let l:owner_dir = s:changes_view_owner_dir(l:save_lnum)
        if empty(l:owner_dir) || !has_key(g:bex_cache, l:owner_dir) | return | endif
        let l:state = g:bex_cache[l:owner_dir]

        let l:sym = matchstr(l:line, '^\s*\zs[+~*-]')

        if l:sym ==# '-'
            let l:state.delete = filter(copy(l:state.delete), {_, v -> v.id !=# l:id})
        elseif l:sym ==# '~'
            let l:state.rename = filter(copy(l:state.rename), {_, v -> v.id !=# l:id})
        else
            let l:name = matchstr(l:line, '^\s*[+*]\s\+\/[0-9a-zA-Z]\+\s\+\zs.*')
            let l:removed = 0
            let l:kept = []
            for l:m in l:state.move_to
                if !l:removed && l:m.id ==# l:id && l:m.name ==# l:name
                    let l:removed = 1
                else
                    call add(l:kept, l:m)
                endif
            endfor
            let l:state.move_to = l:kept
        endif

        let g:bex_cache[l:owner_dir] = l:state
        if empty(l:state.delete) && empty(l:state.rename)
            \ && empty(l:state.entries) && empty(l:state.move_to)
            call remove(g:bex_cache, l:owner_dir)
        endif
    endif

    call s:normalize_cache()

    if empty(g:bex_cache)
        let b:bex_changes_view = 0
        setlocal modifiable
        call s:render()
    else
        call s:show_changes_in_buffer()
        call cursor(min([l:save_lnum, line('$')]), 1)
    endif
endfunction

" Helpers

function! bex#SafeRerender() abort
    if !bufexists(bufnr('%')) | return | endif
    if mode() !~# '^n' | return | endif
    try
        if get(b:, 'bex_changes_view', 0)
            let b:bex_changes_view = 0
            setlocal modifiable
        endif
        setlocal nonumber norelativenumber nowrap noeol nofixeol
        call s:reapply_props()
        call s:render()
    catch
    endtry
endfunction

function! s:handle_bounds() abort
    if get(b:, 'bex_changes_view', 0) | return | endif
    call s:lock_cursor()
    call bex#UpdateVirtualDirectory(b:bex_dir)
    call s:position_header_popup()
endfunction

function! s:relative_time(ftime) abort
    let l:d = localtime() - a:ftime
    return l:d < 60 ? l:d.'s ago'
        \ : l:d < 3600 ? (l:d/60).'m ago'
        \ : l:d < 86400 ? (l:d/3600).'h ago'
        \ : l:d < 31536000 ? (l:d/86400).'d ago'
        \ : (l:d/31536000).'y ago'
endfunction

function! s:human_size(size) abort
    return a:size < 1024 ? a:size.'B'
        \ : a:size < 1048576 ? printf('%.1fKB', a:size/1024.0)
        \ : a:size < 1073741824 ? printf('%.1fMB', a:size/1048576.0)
        \ : a:size < 1099511627776 ? printf('%.1fGB', a:size/1073741824.0)
        \ : printf('%.1fTB', a:size/1099511627776.0)
endfunction
