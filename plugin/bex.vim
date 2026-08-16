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

" Raw numeric ANSI tokens (0-15): named cterm colors aren't stable across
" color-mode once &t_Co reaches 256, so target literal ANSI indices
" directly instead. 'br_' prefixed tokens are the bright 8-15 counterparts.
let s:bex_tokens = {
      \ 'black':      0,
      \ 'red':        1,
      \ 'green':      2,
      \ 'yellow':     3,
      \ 'blue':       4,
      \ 'magenta':    5,
      \ 'cyan':       6,
      \ 'white':      7,
      \ 'br_black':   8,
      \ 'br_red':     9,
      \ 'br_green':   10,
      \ 'br_yellow':  11,
      \ 'br_blue':    12,
      \ 'br_magenta': 13,
      \ 'br_cyan':    14,
      \ 'br_white':   15,
      \ }

let g:bex_gui_black      = get(g:, 'bex_gui_black',      'Black')
let g:bex_gui_red        = get(g:, 'bex_gui_red',        'Red')
let g:bex_gui_green      = get(g:, 'bex_gui_green',      'Green')
let g:bex_gui_yellow     = get(g:, 'bex_gui_yellow',     'Yellow')
let g:bex_gui_blue       = get(g:, 'bex_gui_blue',       'Blue')
let g:bex_gui_magenta    = get(g:, 'bex_gui_magenta',    'Magenta')
let g:bex_gui_cyan       = get(g:, 'bex_gui_cyan',       'Cyan')
let g:bex_gui_white      = get(g:, 'bex_gui_white',      'LightGray')
let g:bex_gui_br_black   = get(g:, 'bex_gui_br_black',   'DarkGray')
let g:bex_gui_br_red     = get(g:, 'bex_gui_br_red',     'LightRed')
let g:bex_gui_br_green   = get(g:, 'bex_gui_br_green',   'LightGreen')
let g:bex_gui_br_yellow  = get(g:, 'bex_gui_br_yellow',  'LightYellow')
let g:bex_gui_br_blue    = get(g:, 'bex_gui_br_blue',    'LightBlue')
let g:bex_gui_br_magenta = get(g:, 'bex_gui_br_magenta', 'LightMagenta')
let g:bex_gui_br_cyan    = get(g:, 'bex_gui_br_cyan',    'LightCyan')
let g:bex_gui_br_white   = get(g:, 'bex_gui_br_white',   'White')

let s:bex_gui_colors = [
      \ g:bex_gui_black, g:bex_gui_red, g:bex_gui_green, g:bex_gui_yellow,
      \ g:bex_gui_blue, g:bex_gui_magenta, g:bex_gui_cyan, g:bex_gui_white,
      \ g:bex_gui_br_black, g:bex_gui_br_red, g:bex_gui_br_green, g:bex_gui_br_yellow,
      \ g:bex_gui_br_blue, g:bex_gui_br_magenta, g:bex_gui_br_cyan, g:bex_gui_br_white
      \ ]

let g:bex_hi_BexHeader          = get(g:, 'bex_hi_BexHeader',          'br_yellow')
let g:bex_hi_BexInfo            = get(g:, 'bex_hi_BexInfo',            'br_black')
let g:bex_hi_BexDir             = get(g:, 'bex_hi_BexDir',             'br_yellow')
let g:bex_hi_BexFile            = get(g:, 'bex_hi_BexFile',            'br_white')
let g:bex_hi_BexHiddenDir       = get(g:, 'bex_hi_BexHiddenDir',       'yellow')
let g:bex_hi_BexHiddenFile      = get(g:, 'bex_hi_BexHiddenFile',      'white')
let g:bex_hi_BexVisible         = get(g:, 'bex_hi_BexVisible',         'br_green')
let g:bex_hi_BexHidden          = get(g:, 'bex_hi_BexHidden',          'br_red')
let g:bex_hi_BexID              = get(g:, 'bex_hi_BexID',              'br_black')
let g:bex_hi_BexHiddenID        = get(g:, 'bex_hi_BexHiddenID',        'br_black')
let g:bex_hi_BexExec            = get(g:, 'bex_hi_BexExec',            'br_green')
let g:bex_hi_BexSymlink         = get(g:, 'bex_hi_BexSymlink',         'br_blue')

let g:bex_hi_BexChangesDir      = get(g:, 'bex_hi_BexChangesDir',      'br_yellow')
let g:bex_hi_BexChangesDel      = get(g:, 'bex_hi_BexChangesDel',      'br_red')
let g:bex_hi_BexChangesAdd      = get(g:, 'bex_hi_BexChangesAdd',      'br_green')
let g:bex_hi_BexChangesRename   = get(g:, 'bex_hi_BexChangesRename',   'br_cyan')
let g:bex_hi_BexChangesMoveFrom = get(g:, 'bex_hi_BexChangesMoveFrom', 'br_black')
let g:bex_hi_BexChangesMoveTo   = get(g:, 'bex_hi_BexChangesMoveTo',   'br_magenta')
let g:bex_hi_BexChangesCopy     = get(g:, 'bex_hi_BexChangesCopy',     'br_blue')
let g:bex_hi_BexDotfilesOn      = get(g:, 'bex_hi_BexDotfilesOn',      'br_green')
let g:bex_hi_BexDotfilesOff     = get(g:, 'bex_hi_BexDotfilesOff',     'br_red')
let g:bex_hi_BexModified        = get(g:, 'bex_hi_BexModified',        'br_blue')

" 8-color fallback: on terminals reporting &t_Co < 16, fold any bright
" token (8-15) down to its base 0-7 ANSI color and add 'bold' to keep some
" visual distinction.
function! s:bex_hi(group, fg_token) abort
    let l:cmd = 'highlight! ' . a:group
    let l:attrs = []

    if a:fg_token !=# '' && has_key(s:bex_tokens, a:fg_token)
        let l:fg = s:bex_tokens[a:fg_token]

        let l:cmd .= ' guifg=' . s:bex_gui_colors[l:fg]

        if &t_Co < 16 && l:fg >= 8 && l:fg <= 15
            let l:fg = l:fg - 8
            call add(l:attrs, 'bold')
        endif

        let l:cmd .= ' ctermfg=' . l:fg
    endif

    if !empty(l:attrs)
        let l:cmd .= ' cterm=' . join(l:attrs, ',')
        let l:cmd .= ' gui=' . join(l:attrs, ',')
    endif

    execute l:cmd
endfunction

function! bex#RedefineHighlights() abort
    call s:bex_hi('BexHeader',          g:bex_hi_BexHeader)
    call s:bex_hi('BexInfo',            g:bex_hi_BexInfo)
    call s:bex_hi('BexDir',             g:bex_hi_BexDir)
    call s:bex_hi('BexFile',            g:bex_hi_BexFile)
    call s:bex_hi('BexHiddenDir',       g:bex_hi_BexHiddenDir)
    call s:bex_hi('BexHiddenFile',      g:bex_hi_BexHiddenFile)
    call s:bex_hi('BexVisible',         g:bex_hi_BexVisible)
    call s:bex_hi('BexHidden',          g:bex_hi_BexHidden)
    call s:bex_hi('BexID',              g:bex_hi_BexID)
    call s:bex_hi('BexHiddenID',        g:bex_hi_BexHiddenID)
    call s:bex_hi('BexExec',            g:bex_hi_BexExec)
    call s:bex_hi('BexSymlink',         g:bex_hi_BexSymlink)

    call s:bex_hi('BexChangesDir',      g:bex_hi_BexChangesDir)
    call s:bex_hi('BexChangesDel',      g:bex_hi_BexChangesDel)
    call s:bex_hi('BexChangesAdd',      g:bex_hi_BexChangesAdd)
    call s:bex_hi('BexChangesRename',   g:bex_hi_BexChangesRename)
    call s:bex_hi('BexChangesMoveFrom', g:bex_hi_BexChangesMoveFrom)
    call s:bex_hi('BexChangesMoveTo',   g:bex_hi_BexChangesMoveTo)
    call s:bex_hi('BexChangesCopy',     g:bex_hi_BexChangesCopy)
    call s:bex_hi('BexDotfilesOn',      g:bex_hi_BexDotfilesOn)
    call s:bex_hi('BexDotfilesOff',     g:bex_hi_BexDotfilesOff)
    call s:bex_hi('BexModified',        g:bex_hi_BexModified)
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

    for l:buf in range(1, bufnr('$'))
        if getbufvar(l:buf, '&filetype') ==# 'bex' && bufexists(l:buf)
            call setbufvar(l:buf, '&modified', 0)
            " Splitting only protects unsaved changes in the window we're
            " leaving -- otherwise reuse it directly, same rule bex#Open()
            " and the jumplist use everywhere else.
            execute (&modified ? 'sbuffer ' : 'buffer ') . l:buf
            if !empty(l:args)
                call bex#Navigate(l:args)
            endif
            return
        endif
    endfor

    call bex#Open(l:args)
endfunction
