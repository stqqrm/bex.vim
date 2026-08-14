" File: autoload/bex.vim
" Description: Cleaned, State-Driven ID-Tracked File Browser Engine

" --- Global State Initializations ---
let g:bex_id_counter        = get(g:, 'bex_id_counter', 0)
let g:bex_cache             = get(g:, 'bex_cache', {})
let g:bex_path_ids          = get(g:, 'bex_path_ids', {})
let g:bex_snapshots         = get(g:, 'bex_snapshots', {})
let g:bex_show_hidden       = get(g:, 'bex_show_hidden', 0)
let g:bex_toggling          = get(g:, 'bex_toggling', 0)
let g:bex_cursor_pos        = get(g:, 'bex_cursor_pos', {})
let g:bex_header_at_bottom  = get(g:, 'bex_header_at_bottom', 0)

" Image preview support. Entering (<CR>) a file whose extension is in this
" list renders it in-place with chafa or ImageMagick instead of opening it
" as a text buffer -- see s:image_backend(). Set g:bex_image_preview = 0 to
" disable the feature entirely and always fall back to a normal :edit.
let g:bex_image_extensions  = get(g:, 'bex_image_extensions',
    \ ['png', 'jpg', 'jpeg', 'gif', 'bmp', 'webp', 'tiff', 'tif', 'ico'])
let g:bex_image_preview     = get(g:, 'bex_image_preview', 1)

" Auto-refresh open bex windows when this file itself gets resourced (handy
" while developing the plugin). This is deliberately scoped to bex.vim's
" own path rather than a <buffer>-local SourcePost autocmd: SourcePost
" matches on the sourced file, and <buffer> only filters by "is bex the
" active buffer right now" — so a buffer-local version fires on *every*
" script sourced anywhere (colorscheme reloads, lazy-loaded plugins,
" ftplugin files, ...) as long as the user happens to be sitting in a bex
" buffer at that moment, silently resetting their cursor position.
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

    " Tell coc.nvim (and compatible completion/LSP/diagnostics engines) to
    " leave this buffer alone entirely. bex uses buftype=acwrite, which
    " looks like a "real" editable file rather than a scratch buffer, so
    " coc.nvim was attaching its usual document-sync/diagnostics machinery
    " to it — and that machinery's own CursorHold-triggered background
    " housekeeping (sourcing its internal compat shims) was silently
    " resetting the cursor mid-navigation. b:coc_enabled / b:coc_suggest_disable
    " are the standard opt-out flags coc.nvim recognizes for exactly this
    " situation; NERDTree, fern.vim, and other file-explorer-style plugins
    " set the same flags for the same reason. Harmless no-op if coc.nvim
    " isn't installed.
    let b:coc_enabled = 0
    let b:coc_suggest_disable = 1

    nnoremap <buffer> <silent> . :call bex#ToggleHidden()<CR>
    nnoremap <buffer> <silent> <CR> :call bex#OnSelect()<CR>
    nnoremap <buffer> <silent> <Tab> :call bex#ToggleChangesView()<CR>
    nnoremap <buffer> <silent> e :call bex#ExtractUnderCursor()<CR>

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
    " Reset all global state
    let g:bex_cache      = {}
    let g:bex_snapshots  = {}
    let g:bex_id_counter = 0
    let g:bex_path_ids   = {}
    let g:bex_cursor_pos = {}

    " Find and wipe all bex buffers, then open fresh
    let l:dir = ''
    for l:buf in range(1, bufnr('$'))
        if getbufvar(l:buf, '&filetype') ==# 'bex' && bufexists(l:buf)
            let l:dir = getbufvar(l:buf, 'bex_dir', '')
            call setbufvar(l:buf, '&modified', 0)
            execute 'bwipeout! ' . l:buf
            break
        endif
    endfor

    " Prefer explicit path, then previous bex dir, then cwd
    let l:open = !empty(l:path) ? l:path : (!empty(l:dir) ? l:dir : '')
    call bex#Open(l:open)
endfunction

function! bex#Navigate(path, ...) abort
    " Optional a:1 = allow_virtual (1 to permit navigating into a
    " directory that doesn't exist on disk yet, e.g. a freshly typed
    " entry the user is about to create).
    let l:allow_virtual = get(a:, 1, 0)

    let l:dir = fnamemodify(a:path, ':p')
    let l:dir = len(l:dir) > 1 ? substitute(l:dir, '[/\\]$', '', '') : l:dir
    if !isdirectory(l:dir) && !l:allow_virtual
        echoerr 'bex: Directory not found: ' . l:dir
        return
    endif

    " Navigating away always leaves the changes view first — the buffer's
    " about to hold a different directory's listing, which needs to be
    " modifiable to build. Must actually re-render here (not just flip the
    " flag and modifiable), since the very next line queries buffer text
    " for pending edits — leaving stale changes-view text in place would
    " make every previously-tracked file look deleted (nothing there
    " starts with a valid ID).
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

function! bex#ToggleHidden() abort
    " While viewing the changes summary (<Tab>), there's no listing in the
    " buffer to toggle -- it's read-only summary text built from
    " g:bex_cache, unrelated to the current dotfiles state. Just flip the
    " flag and refresh the header popup's on/off indicator in place; the
    " new state takes effect next time the listing itself is rendered
    " (e.g. when <Tab> returns to it). Deliberately does not leave the
    " changes view, touch the buffer, or call s:render() here -- doing so
    " previously caused every tracked file to get flagged for deletion
    " (see history: render() rebuilds b:bex_snapshot to the new listing
    " before it rewrites the buffer text, and a stray diff against that
    " half-updated state during the switch back to a listing was reading
    " everything as missing).
    if get(b:, 'bex_changes_view', 0)
        let g:bex_show_hidden = !g:bex_show_hidden
        call s:position_header_popup()
        return
    endif

    " Guard set before s:render() below: render() rebuilds b:bex_snapshot
    " to the new (full) listing *before* it clears and repopulates the
    " buffer text (%delete _ then setline/append), so there's a brief
    " window where the buffer is empty/partial while the snapshot already
    " reflects everything. If a TextChanged autocmd fired in that window,
    " bex#UpdateVirtualDirectory() -> s:QueryBuffer() would diff that
    " empty/partial buffer against the full snapshot and flag every
    " currently-tracked file as deleted. g:bex_toggling makes
    " bex#UpdateVirtualDirectory() no-op during exactly this window.
    let g:bex_toggling = 1

    let l:cursor_line = line('.')
    let l:cursor_id = matchstr(getline('.'), '^\/[0-9a-zA-Z]\+')

    " Query while the buffer still reflects the *pre-toggle* visibility.
    " Merge in anything previously staged on a currently-hidden item (see
    " s:merge_hidden_pending()) so that a directory whose only pending
    " change lives on a dotfile doesn't get silently dropped here just
    " because dotfiles happened to already be hidden when this toggle
    " started.
    let l:plan = s:merge_hidden_pending(b:bex_dir, s:QueryBuffer())
    let l:has_changes = !empty(l:plan.delete) || !empty(l:plan.rename)
        \ || !empty(l:plan.entries) || !empty(l:plan.move_to)
    if l:has_changes
        let g:bex_cache[b:bex_dir] = l:plan
    endif
    let g:bex_show_hidden = !g:bex_show_hidden
    call s:render()

    " IDs stay stable across a dotfiles toggle (only render() runs, not
    " apply_all(), so g:bex_path_ids isn't reassigned) — find the same
    " item's line again rather than leaving the cursor wherever render()
    " defaults to. Falls back to a clamped line number if the item just
    " became hidden (or shown, if it was already the file the cursor was
    " on before toggling dotfiles off left nothing to find).
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

" Stages whatever item is under the cursor in the changes view (<Tab>) to
" land in the bex directory that was open when <Tab> was pressed
" (b:bex_dir) -- i.e. "extract [this cut/staged item] to the current
" directory". Adds a move_to entry for that item's id here; apply_all()
" already treats a move_to as an actual move (not a copy) whenever a
" matching delete for the same id exists anywhere in g:bex_cache, which
" is exactly the state a cut (delete staged in the source directory)
" leaves things in, so nothing else needs to change on the source side --
" delete a file in one directory, navigate to another, open the changes
" view, and 'e' the deleted item to send it here instead of losing it.
" Only meaningful from the changes view -- there's no staged-item concept
" to extract from in the plain listing, where 'e' is a no-op.
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

    " Resolve the item's name/type: prefer the owning directory's own
    " cached snapshot (covers items only staged while dotfiles were
    " shown, etc.), falling back to the last full listing snapshot taken
    " for that directory.
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

" Returns 1 if a:path's extension is one bex knows how to preview as an
" image (see g:bex_image_extensions). Purely extension-based -- same
" convention the rest of bex uses for filetype-ish decisions -- so it's
" cheap to call on every <CR> without touching the filesystem twice.
function! s:is_image(path) abort
    let l:ext = tolower(fnamemodify(a:path, ':e'))
    return !empty(l:ext) && index(g:bex_image_extensions, l:ext) >= 0
endfunction

" Picks the first available image-rendering backend and returns the
" argv list to run it, or [] if neither is installed.
"
" Mirrors what fastfetch does for its own chafa-rendered logos: give
" chafa an explicit character-cell size and otherwise leave everything
" else -- symbol selection, dithering, font aspect ratio -- to its own
" auto-detection/defaults. Earlier attempts to hand-tune those
" (restricting symbols, forcing a work factor, forcing a font ratio)
" were each fixing one symptom while making the overall output worse;
" chafa's own heuristics, the same ones fastfetch relies on, do better
" left alone.
"
" Color depth is the one exception, forced to full truecolor below
" rather than left to auto-detection. chafa normally auto-detects color
" depth from terminal-capability signals like $COLORTERM, but the image
" preview here runs *inside* a Vim :terminal job (see
" s:start_image_terminal() -> term_start()) -- i.e. chafa's own stdout
" is being relayed through libvterm before it ever reaches the real
" terminal emulator, and $COLORTERM doesn't reliably survive that
" relay. When chafa can't confirm truecolor support this way it falls
" back to a quantized ~256-color palette and dithers to approximate the
" image, which shows up as a speckled cross-hatch texture with visibly
" shifted colors -- not a real fidelity problem with the image, just
" chafa being conservative about a color depth libvterm can actually
" display just fine. Forcing it removes the guesswork.
let g:bex_image_chafa_args  = get(g:, 'bex_image_chafa_args', ['--colors=full'])

" ImageMagick's sixel output only actually renders on terminals with real
" sixel support, which Vim's builtin :terminal (backed by libvterm) does
" not have -- it's kept as a best-effort fallback for when chafa isn't
" installed at all, since sixel is the only static-image format it can
" produce on its own. (In practice, if you only have this fallback
" available, expect the preview to render as raw sixel escape data
" rather than an image, since libvterm can't interpret it -- installing
" chafa is the real fix in that case.)
"
" The default args below pin the colorspace to sRGB and use Floyd-
" Steinberg error-diffusion dithering. Without '-colorspace sRGB',
" ImageMagick performs the color-reduction math for '-colors'/sixel
" quantization in linear-light RGB, which comes out washed out and
" shifted toward yellow-green once rendered. Without an explicit
" '-dither', IM's default ordered/halftone dither leaves a visible
" cross-hatch speckle pattern over the whole image instead of the
" smoother, more photographic look error diffusion gives at typical
" terminal cell resolutions. Both are quantization-time settings, so
" they only affect the magick/convert fallback -- chafa does its own
" quantization and isn't affected by g:bex_image_magick_args at all.
let g:bex_image_magick_args = get(g:, 'bex_image_magick_args',
    \ ['-geometry', '1024x768>', '-colorspace', 'sRGB',
    \  '-dither', 'FloydSteinberg', '-colors', '256'])

" True if any supported image-preview backend is installed. Cheap
" existence check kept separate from s:image_backend() so callers that
" just need to know "is preview possible at all" don't have to supply a
" path/size first.
function! s:image_backend_available() abort
    return executable('chafa') || executable('magick') || executable('convert')
endfunction

" Character-cell bounding box to render the image into: the current
" window's size, minus one row reserved for the header popup. This is
" only ever fed to chafa's own '--size' argument below -- never to
" term_start()'s term_rows/term_cols -- so it has no effect on the actual
" Vim window or its statusline, unlike an earlier attempt at the same
" idea.
function! s:image_target_size() abort
    let l:winid = win_getid()
    return {
        \ 'cols':  max([winwidth(l:winid), 1]),
        \ 'lines': max([winheight(l:winid) - 1, 1]),
        \ }
endfunction

" Builds the argv for rendering a:path at roughly a:cols x a:lines
" character cells (see s:image_target_size()). Called fresh every time
" the image is (re)drawn, including on window resize, so it always
" matches the window's current size instead of a stale one.
function! s:image_backend(path, cols, lines) abort
    let l:cols  = max([a:cols, 1])
    let l:lines = max([a:lines, 1])

    if executable('chafa')
        return ['chafa', '--size', l:cols . 'x' . l:lines] + g:bex_image_chafa_args + [a:path]
    elseif executable('magick') || executable('convert')
        " '-geometry WxH>' already preserves aspect ratio on its own
        " (the trailing '>' only ever shrinks, never stretches), so no
        " explicit cell size is needed here.
        let l:bin = executable('magick') ? 'magick' : 'convert'
        return [l:bin, a:path] + g:bex_image_magick_args + ['sixel:-']
    endif
    return []
endfunction

" (Re)draws a:path into the current window as a fresh terminal job,
" replacing whatever terminal buffer (if any) was previously showing it.
" Used both for the initial preview and to redraw on window resize --
" term_start() always creates a brand-new buffer even with 'curwin', so
" the old one (if this is a redraw of the same image, not a first-time
" open) is wiped after the new one takes its place, and its now-stale
" header popup is closed along with it via BufUnload.
function! s:start_image_terminal(path) abort
    let l:old_buf = (get(b:, 'bex_image_src', '') ==# a:path) ? bufnr('%') : -1

    let l:size = s:image_target_size()
    let l:cmd = s:image_backend(a:path, l:size.cols, l:size.lines)
    if empty(l:cmd)
        execute 'edit ' . fnameescape(a:path)
        return
    endif

    " Deliberately NOT passing term_rows/term_cols to term_start(): those
    " don't just set the pty's reported size, they tell Vim to size the
    " *window* to match (padding/cropping otherwise), which was resizing
    " the actual window -- and with it every other window's statusline --
    " on each redraw. The terminal just fills the real window as-is; the
    " sizing chafa needs comes from the '--size' argument built above
    " instead, which has no effect on Vim's own layout.
    call term_start(l:cmd, {
        \ 'curwin': 1,
        \ 'term_name': '[image] ' . fnamemodify(a:path, ':t'),
        \ })
    let b:bex_image_src = a:path

    if l:old_buf > 0 && l:old_buf != bufnr('%') && bufexists(l:old_buf)
        execute 'bwipeout! ' . l:old_buf
    endif

    " nonumber/norelativenumber/signcolumn=no: without these, a global
    " 'number' or 'relativenumber' (or a gutter from another plugin)
    " shows up as a column of digits/marks laid directly over the
    " rendered image, since this is an ordinary Vim window like any
    " other -- term_start() doesn't clear those options on its own.
    setlocal nomodified nobuflisted nonumber norelativenumber
    setlocal signcolumn=no nowrap nolist

    nnoremap <buffer> <silent> - :call bex#ReturnFromImage()<CR>

    augroup bex_image_header
        autocmd! * <buffer>
        autocmd VimResized,WinScrolled,WinEnter <buffer> call s:reposition_image_header()
        autocmd VimResized                      <buffer> call s:redraw_image()
        autocmd BufWinLeave,BufUnload           <buffer> call s:close_image_header()
    augroup END

    call s:show_image_header(a:path)
endfunction

" Re-renders the currently displayed image at the window's new size.
" Bound to VimResized on the terminal buffer itself (see
" s:start_image_terminal()) -- the earlier one-shot chafa/magick job has
" already exited by the time a resize happens, so its output is just
" static text as far as Vim is concerned and won't reflow on its own;
" this reruns the backend from scratch against the new dimensions.
function! s:redraw_image() abort
    if !exists('b:bex_image_src') || empty(b:bex_image_src) | return | endif
    if &buftype !=# 'terminal' | return | endif
    call s:start_image_terminal(b:bex_image_src)
endfunction

" Bound to '-' in the image-preview buffer: switches back to browsing in
" bex (reusing the current window) and cleans up the now-unneeded
" terminal buffer behind it. bex#Toggle() finds whatever bex buffer is
" already sitting hidden -- bex#OnSelect() closes the bex *window* when
" opening a file, never the buffer -- and switches straight to it, so
" this lands back exactly where browsing left off, cursor position and
" all.
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

" Replaces the plain `execute 'edit ' . fnameescape(path)` bex#OnSelect()
" used to call directly. When the target is a previewable image and a
" backend is installed, render it into the current window via
" :terminal instead of loading it as a text buffer, and keep it sized to
" the window as it's resized; anything else (not an image, no backend
" found, or Vim built without +terminal) falls straight through to the
" normal :edit, so behavior is unchanged unless preview is actually
" possible.
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
            " target, not after: s:open_file_or_image() -> term_start()
            " for an image preview captures the window's size as it
            " exists the instant the job launches, and chafa renders
            " into that once, immediately. If the bex window (still
            " occupying half the split) hasn't been closed yet, the
            " terminal launches at that transient half-size and there's
            " no later event that re-triggers it -- closing a window is
            " an internal layout change, not the outer-terminal resize
            " that VimResized (and s:redraw_image()) actually watches
            " for. Closing first means the remaining window is already
            " at its true final size before anything renders into it.
            let l:bex_win = bufwinnr(l:bex_buf)
            if l:bex_win != -1
                execute l:bex_win . 'close'
            endif
            call s:open_file_or_image(l:path)

            " Do this last, and by buffer number rather than s:close_header_popup()'s
            " b: lookup: the vsplit above briefly opens a second window onto the
            " bex buffer, whose WinEnter recreates the popup even if we'd already
            " closed it — and by now the current buffer is the opened file, not
            " bex, so a plain current-buffer close can't see it anymore either.
            let l:popup = getbufvar(l:bex_buf, 'bex_header_popup', -1)
            if l:popup > 0 && exists('*popup_close')
                call popup_close(l:popup)
            endif
            call setbufvar(l:bex_buf, 'bex_header_popup', -1)
            redraw
        endif
        return
    endif

    " No tracked ID on this line: if it's a freshly typed directory entry
    " (e.g. "src/") that doesn't exist on disk yet, enter it as a virtual
    " directory so files and folders can be staged inside it before
    " anything is written to disk. Lines that still carry a stale/foreign
    " ID (matched above but not in b:bex_snapshot) are intentionally left
    " untouched, same as before.
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
    " While viewing changes the buffer holds rendered summary text, not a
    " listing — nothing to derive pending state from, and g:bex_cache
    " already has the real state anyway.
    if get(b:, 'bex_changes_view', 0) | return | endif
    if mode() =~# '^[vV]' || mode() ==# "\<C-v>" | return | endif

    " Merge in anything previously staged on a currently-hidden item (see
    " s:merge_hidden_pending()) before deciding whether there are pending
    " changes -- otherwise a directory whose only pending change lives on
    " a dotfile that's currently hidden would look empty here and get its
    " entire cache entry wiped out below.
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

" Toggle between the normal editable listing and a read-only summary of
" everything staged in g:bex_cache, rendered directly into the same
" buffer. Mapped to <Tab> — see the top-level comment near the mapping for
" why that key specifically.
function! bex#ToggleChangesView() abort
    if get(b:, 'bex_changes_view', 0)
        let b:bex_changes_view = 0
        setlocal modifiable
        call s:render()

        " s:render() rebuilds the listing from scratch, so the line the
        " cursor happens to be on (a leftover changes-view line number)
        " has nothing to do with the item it was on before <Tab> was
        " pressed. Find that same item again by ID, same as
        " bex#ToggleHidden() does, rather than leaving the cursor
        " wherever render() defaults to.
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

" Carries forward any previously staged 'delete'/'rename' entries whose id
" isn't present in the buffer's current snapshot -- i.e. a change staged on
" a dotfile while it was shown, which then got hidden again by toggling
" '.' off. QueryBuffer() only ever derives state from what's currently
" rendered, so callers that use its result to overwrite g:bex_cache would
" otherwise silently lose that pending change the moment dotfiles are
" hidden (whether that's mid-toggle or from any later edit made while
" hidden). 'entries' and 'move_to' don't need this: restore_cached_buffer()
" always re-inserts those into the buffer regardless of the hidden-files
" setting, so QueryBuffer() already recaptures them correctly on its own.
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
            " Carry the snapshot info along too -- apply_all()/validate_all()
            " read entry details (path, is_dir) from the cached state's own
            " 'snapshot' field, not from the live b:bex_snapshot, so without
            " this the preserved entry would have nothing to act on.
            if has_key(l:old.snapshot, l:item.id) && !has_key(a:state.snapshot, l:item.id)
                let a:state.snapshot[l:item.id] = l:old.snapshot[l:item.id]
            endif
        endfor
    endfor

    return a:state
endfunction

" File System Application

" If a directory is itself staged for deletion, deletions recorded for its
" descendants are redundant — deleting the directory already removes them
" recursively. Prune those descendant delete entries (and drop the cached
" state for that directory entirely if nothing else is pending there) so
" the changes view and the delete pass only ever deal with the top-most
" deleted directory.
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

" A virtual (not-yet-on-disk) directory is only meaningful as long as it is
" still reachable via an unbroken chain of pending creations, starting from
" a real directory. If the entry that would have created it (or one of its
" virtual ancestors) gets deleted from the buffer, it's no longer going to
" be created and shouldn't be treated as staged.
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

" Drop cached state for any virtual directory (and, transitively, anything
" staged underneath it) whose creation is no longer pending anywhere.
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
        " g:bex_cache already fully reflects what's pending — the buffer
        " right now is rendered summary text, not a listing to re-derive
        " state from, so just restore a modifiable listing (which
        " apply_all()'s closing render() needs) and skip straight to
        " applying.
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

" Move a path using the OS's own move/rename command rather than Vim's
" rename() builtin. Sets v:shell_error as its normal side effect from
" system(), matching how copies are checked elsewhere in this file.
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
            " Stage through a collision-safe temp name in the same
            " directory (keeps the move on the same filesystem) so
            " chained/swapped renames (A->B, B->A) never clash with each
            " other mid-flight.
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

        " The target directory itself may not exist yet (a virtual
        " directory staged via bex#OnSelect / bex#Navigate, possibly
        " several levels deep). mkdir(..., 'p') creates the whole chain
        " of missing ancestors in one shot and is a no-op if the
        " directory already exists, so this is safe regardless of the
        " iteration order of g:bex_cache.
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

    " Find whatever the cursor was on before the write, under its
    " (possibly new, since the ID counter reset above) ID, and put the
    " cursor back on it rather than leaving it wherever render() defaults
    " to (the top of the listing).
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

" IDs are printed as '/' + 4 base62 characters (a-z, A-Z, 0-9 = 62 symbols,
" 62^4 ≈ 14.7 million distinct values per session) instead of the previous
" 8-digit hex, so they read shorter on screen while still being effectively
" collision-free for a single Vim session's g:bex_id_counter.
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
        let l:lines += [l:id . ' ' . l:name . (isdirectory(l:p) ? '/' : '')]
        let b:bex_snapshot[l:id] = {'name': l:name, 'is_dir': isdirectory(l:p), 'path': l:p}
    endfor

    let g:bex_snapshots[b:bex_dir] = copy(b:bex_snapshot)

    silent %delete _
    if g:bex_header_at_bottom
        call setline(1, l:lines + [''])
        " Always leave at least one real line above the spacer so the
        " cursor has somewhere valid to land, even for an empty directory.
        if line('$') == 1 | call append(0, '') | endif
    else
        call setline(1, [''] + l:lines)
        " Always leave at least one real line under the spacer so the
        " cursor has somewhere valid to land, even for an empty directory.
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
        " Strip leading empty lines (nothing reserved up here in this mode).
        while line('$') > 2 && empty(trim(getline(1)))
            silent execute '1d _'
        endwhile
        " Strip empty lines sitting between real content and the reserved
        " trailing spacer, keeping the spacer (the last line) itself.
        while line('$') > 2 && empty(trim(getline(line('$') - 1)))
            silent execute (line('$') - 1) . 'd _'
        endwhile
        " Always keep exactly one trailing blank spacer line, and at least
        " one real editable line above it.
        if line('$') < 2 || !empty(trim(getline(line('$'))))
            call append(line('$'), '')
        endif
    else
        " Strip leading empty lines (right after the reserved spacer),
        " keeping the spacer itself untouched.
        while line('$') > 2 && empty(trim(getline(2)))
            silent execute '2d _'
        endwhile
        " Strip all trailing empty lines
        while line('$') > 2 && empty(trim(getline(line('$'))))
            silent execute line('$') . 'd _'
        endwhile
        " Always leave at least one editable line beneath the spacer.
        if line('$') == 1 | call append(1, '') | endif
    endif

    setlocal nomodified
endfunction

" First and one-past-last real content line. In top mode line 1 is the
" reserved spacer, so content runs [2, line('$')]. In bottom mode the very
" last line is the reserved spacer instead, so content runs
" [1, line('$')-1]. Both bounds are re-evaluated fresh on every call since
" line('$') changes as lines are added/removed.
function! s:content_start() abort
    return g:bex_header_at_bottom ? 1 : 2
endfunction

function! s:content_end() abort
    return g:bex_header_at_bottom ? line('$') - 1 : line('$')
endfunction

" Append a line of real content, keeping it on the correct side of the
" reserved spacer regardless of header position.
function! s:append_content(text) abort
    if g:bex_header_at_bottom
        call append(line('$') - 1, a:text)
    else
        call append(line('$'), a:text)
    endif
endfunction

" The header lives in a popup anchored to the window's screen position (not
" a buffer line and not a winbar), so it can never become stray buffer
" text and can never be edited or deleted. One end of the buffer is kept
" as a permanent blank spacer — line 1 in top mode, the last line in
" bottom mode — so the popup always has empty space to sit over instead of
" covering a real entry.
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

" Mirrors bex's own header popup for an opened image preview, showing the
" image's full path (home-shortened, same convention as
" s:position_header_popup()) rather than just its containing directory's
" last path component. bex#OnSelect() always closes the bex window once
" the image is showing, so this can't simply reuse b:bex_header_popup /
" the bex <buffer> autogroup -- both are scoped to a buffer that's about
" to disappear. It runs its own small, equivalent autogroup on the
" terminal buffer instead: reposition on resize/scroll, redraw the image
" itself on resize, and close when that buffer goes away (all wired up in
" s:start_image_terminal()).
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

" Keep the cursor from ever resting on the reserved spacer line, in any
" mode. In Visual/Visual-block mode this only moves the active end of the
" selection (cursor()); the anchor end ('v mark) is untouched, so it just
" clamps how far a selection can extend rather than cancelling it. No-op
" while viewing changes — there's no spacer concept in that view.
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
    " Sane defaults so the on/off state is visibly distinct even without a
    " colorscheme that defines these groups; 'default' means a user's own
    " definition always wins. These must be defined BEFORE prop_type_add
    " below — prop_type_add throws E970 if the highlight group it
    " references doesn't exist yet, which previously fired on every single
    " CursorMoved (since position_header_popup() runs on every cursor
    " move), throwing an error and eating the user's next keypress as that
    " error prompt's dismissal instead of processing it.
    highlight default BexDotfilesOn  ctermfg=Green guifg=#98c379
    highlight default BexDotfilesOff ctermfg=Red   guifg=#e06c75

    if empty(prop_type_get('BexDotfilesOn'))
        call prop_type_add('BexDotfilesOn', {'highlight': 'BexDotfilesOn'})
    endif
    if empty(prop_type_get('BexDotfilesOff'))
        call prop_type_add('BexDotfilesOff', {'highlight': 'BexDotfilesOff'})
    endif
endfunction

" Compact, single-line summary of the current directory's pending changes
" only (not the whole g:bex_cache — that's what <Tab> is for), e.g.
" "-old.txt ~renamed.txt +new.txt". Truncated by the caller to fit the
" window, since this is destined for the header popup.
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

    " Squeeze in a compact change summary between the path and the
    " dotfiles state, truncating it (never the path) with '...' if there
    " isn't room for the whole thing.
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

    " 1-based byte column where the dotfiles segment starts, so only that
    " part of the line is colored — the rest stays the plain header color.
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
    else
        call popup_settext(b:bex_header_popup, l:content)
        call popup_move(b:bex_header_popup, l:opts)
    endif
endfunction

function! s:reapply_props() abort
    " The changes view manages its own props/highlighting (see
    " s:show_changes_in_buffer()) — clearing/rebuilding the file-listing
    " ones here would just wipe that out for nothing, since none of the
    " listing patterns match changes-view text anyway.
    if get(b:, 'bex_changes_view', 0) | return | endif

    if empty(prop_type_get('bex_info')) | call prop_type_add('bex_info', {'highlight': 'BexInfo'}) | endif

    call prop_clear(1, line('$'))

    for l:lnum in range(s:content_start(), s:content_end())
        let l:id = matchstr(getline(l:lnum), '^\/[0-9a-zA-Z]\{4}')
        if empty(l:id) || !has_key(b:bex_snapshot, l:id) | continue | endif
        let l:p = b:bex_snapshot[l:id].path
        let l:size = b:bex_snapshot[l:id].is_dir ? '' : s:human_size(getfsize(l:p))
        let l:info = printf('%-10s %8s %10s', getfperm(l:p), l:size, s:relative_time(getftime(l:p)))
        call prop_add(l:lnum, 0, {'type': 'bex_info', 'text': l:info, 'text_align': 'right'})
    endfor

    syntax clear
    syntax match BexID       /^\/[0-9a-zA-Z]\+\ze\s/
    syntax match BexHiddenID /^\/[0-9a-zA-Z]\+\ze\s\+\.[^/]/
    syntax match BexDir        /\%(\/[0-9a-zA-Z]\+\s\+\|\s*\)\zs[^/].\+\/$/
    syntax match BexDir        /\zs\S\+\/$/
    syntax match BexHiddenDir  /\zs\.[^/]*\/$/
    syntax match BexHiddenFile /\%(^\s*\|\s\)\zs\.[^/]\+$/
endfunction

" Changes View — toggled in-place with <Tab> instead of a separate split.
" Builds a read-only (nomodifiable) rendering of everything staged across
" g:bex_cache directly into the current buffer; <Tab> again (or writing)
" returns to the normal editable listing.

" Builds the {lines, highlights} for every directory with pending changes
" in g:bex_cache — the full picture, not just the current directory (that
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

    " Drop the single trailing blank separator so the view doesn't end on
    " an empty line.
    if !empty(l:lines) && empty(l:lines[-1])
        call remove(l:lines, -1)
    endif

    return {'lines': l:lines, 'highlights': l:highlights}
endfunction

function! s:show_changes_in_buffer() abort
    let l:content = s:build_changes_content()
    let l:lines = empty(l:content.lines) ? ['(no pending changes)'] : l:content.lines
    let l:highlights = copy(l:content.highlights)

    " Reserve a blank line for the header popup to sit over — same
    " convention as the listing view — so it doesn't cover the first row
    " of real content (the changes view has no editable spacer/cursor-lock
    " machinery since it's read-only, but the popup still needs somewhere
    " blank to render).
    if g:bex_header_at_bottom
        let l:lines = l:lines + ['']
    else
        let l:lines = [''] + l:lines
        let l:highlights = map(l:highlights, {_, v -> extend(v, {'lnum': v.lnum + 1})})
    endif

    " Sane defaults, same reasoning as s:ensure_header_highlights(): these
    " must exist before prop_type_add references them below, or it throws
    " E970. 'default' still yields to any colorscheme that defines these
    " groups itself.
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

" Reverts whatever change is under the cursor while in the changes view
" (mapped through <CR> via bex#OnSelect()'s dispatch at the top).
" Locate which directory a changes-view line belongs to, by scanning
" upward from that line for the nearest unindented header line (item
" lines are always indented as '   [+~*-] ...').
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
        " A plain new-entry line (no ID) — find it by name within the
        " directory header it's nested under.
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
        " Scope this to the single directory the cursor line belongs to,
        " and remove only the one entry the cursor is actually on.
        " Matching by id alone isn't enough for move_to: pasting the same
        " source into one directory several times under different names
        " produces multiple move_to entries that all share that source's
        " id, and the same id can also appear as a move_to target in
        " other directories entirely. Filtering by id globally (the old
        " behavior) wiped out every one of those instead of just this
        " line's entry.
        let l:owner_dir = s:changes_view_owner_dir(l:save_lnum)
        if empty(l:owner_dir) || !has_key(g:bex_cache, l:owner_dir) | return | endif
        let l:state = g:bex_cache[l:owner_dir]

        let l:sym = matchstr(l:line, '^\s*\zs[+~*-]')

        if l:sym ==# '-'
            let l:state.delete = filter(copy(l:state.delete), {_, v -> v.id !=# l:id})
        elseif l:sym ==# '~'
            let l:state.rename = filter(copy(l:state.rename), {_, v -> v.id !=# l:id})
        else
            " '+' (move, source already deleted) or '*' (copy) -- both
            " live in move_to; disambiguate duplicate ids by name too,
            " and drop only the first match so a genuine duplicate line
            " loses just the one under the cursor.
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
        " Nothing left to review — drop back to the listing automatically.
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
