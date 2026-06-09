" autoload/bex.vim - Minimalist ID-tracked file browser engine (All IDs Visible)

function! bex#Open(path) abort
  let l:dir = empty(a:path) ? getcwd() : fnamemodify(a:path, ':p')
  " Clean up trailing slashes
  let l:dir = substitute(l:dir, '[/\\]$', '', '')
  
  if !isdirectory(l:dir)
    echoerr 'bex: Absolute path directory not found: ' . l:dir
    return
  endif

  " Fullscreen switch inside the active window
  execute 'edit ' . fnameescape('bex://' . l:dir)
  
  setlocal buftype=acwrite
  setlocal bufhidden=wipe
  setlocal noswapfile
  setlocal nobuflisted
  setlocal filetype=bex
  setlocal nonumber norelativenumber
  setlocal nowrap

  let b:bex_dir = l:dir
  call s:render()

  augroup bex_events
    autocmd! * <buffer>
    autocmd BufWriteCmd <buffer> call s:apply_buffer_changes()
  augroup END
endfunction

function! s:render() abort
  " Grab all files, folder structures, and hidden dotfiles safely
  let l:all = glob(b:bex_dir . '/*', 0, 1) + glob(b:bex_dir . '/.[^.]*', 0, 1)
  let b:bex_snapshot = {}
  
  let l:lines = []
  let l:idx = 0
  
  for l:p in l:all
    let l:name = fnamemodify(l:p, ':t')
    if l:name ==# '.' || l:name ==# '..' || empty(l:name) | continue | endif
    
    let l:is_dir = isdirectory(l:p)
    " Upgraded string representation to 4 bytes (8 hexadecimal characters)
    let l:id = printf('ID:%08x ', l:idx)
    let l:display = l:name . (l:is_dir ? '/' : '')
    
    call add(l:lines, l:id . l:display)
    " Cache snapshots natively mapped directly to the string ID key token
    let b:bex_snapshot[trim(l:id)] = { 'name': l:name, 'is_dir': l:is_dir, 'path': l:p }
    let l:idx += 1
  endfor

  silent %delete _
  call setline(1, l:lines)
  setlocal nomodified
  
  " Syntactically highlight the IDs, keeping them completely visible (no conceal)
  syntax clear
  syntax match BexID /^ID:[0-9a-fA-F]\+\s/
  
  " Match any item ending with a slash as a directory (including hidden ones)
  syntax match BexDir /[^/]\+\/$/
  
  " Match hidden flat files only (do not end with a slash)
  syntax match BexHidden /ID:[0-9a-fA-F]\+\s\+\.[^/]\+$/
  
  highlight default BexID     guifg=#555555          ctermfg=239
  highlight default BexDir    guifg=#6fb3d2 gui=bold ctermfg=74 cterm=bold
  highlight default BexHidden guifg=#777777          ctermfg=243
endfunction

function! bex#OnSelect() abort
  let l:line = getline('.')
  let l:match = matchlist(l:line, '^\(ID:[0-9a-fA-F]\+\)\s\+.*$')
  if empty(l:match) | return | endif
  
  let l:id = l:match[1]
  if has_key(b:bex_snapshot, l:id)
    let l:item = b:bex_snapshot[l:id]
    if l:item.is_dir
      call bex#Open(l:item.path)
    else
      execute 'edit ' . fnameescape(l:item.path)
    endif
  endif
endfunction

function! bex#GoUp() abort
  let l:parent = fnamemodify(b:bex_dir, ':h')
  if l:parent ==# b:bex_dir
    echo 'bex: Already at root directory'
    return
  endif
  call bex#Open(l:parent)
endfunction

function! s:apply_buffer_changes() abort
  let l:seen_ids = {}
  let l:errors = []

  " Phase 1: Mutation Loop — Evaluates Renames and In-line Created items
  for l:line in getline(1, line('$'))
    let l:raw = trim(l:line)
    if empty(l:raw) | continue | endif

    let l:match = matchlist(l:raw, '^\(ID:[0-9a-fA-F]\+\)\s\+\(.*\)$')
    if !empty(l:match)
      let l:id = l:match[1]
      let l:clean_name = substitute(l:match[2], '/$', '', '')
      let l:seen_ids[l:id] = 1

      if has_key(b:bex_snapshot, l:id)
        let l:snap = b:bex_snapshot[l:id]
        if l:snap.name !=# l:clean_name
          let l:src = b:bex_dir . '/' . l:snap.name
          let l:dst = b:bex_dir . '/' . l:clean_name
          if rename(l:src, l:dst) != 0
            call add(l:errors, 'Rename failed: ' . l:snap.name . ' -> ' . l:clean_name)
          endif
        endif
      endif
    else
      " A plain line without an explicit tracker ID -> brand new creation target
      let l:clean_name = substitute(l:raw, '/$', '', '')
      let l:target = b:bex_dir . '/' . l:clean_name
      if l:raw =~# '/$'
        if !isdirectory(l:target) | call mkdir(l:target, 'p') | endif
      else
        if !filereadable(l:target) | call writefile([], l:target) | endif
      endif
    endif
  endfor

  " Phase 2: Compute Missing Tracker IDs for Delayed Batch Deletions
  let l:del_paths = []
  let l:del_names = []
  for [l:id, l:snap] in items(b:bex_snapshot)
    if !has_key(l:seen_ids, l:id)
      call add(l:del_paths, l:snap.path)
      call add(l:del_names, l:snap.name . (l:snap.is_dir ? '/' : ''))
    endif
  endfor

  if !empty(l:del_paths)
    redraw
    echo "bex: The following items will be permanently deleted:\n" . join(map(l:del_names, '"  - " . v:val'), "\n")
    if input('\nConfirm deletion of ' . len(l:del_paths) . ' item(s)? [y/N]: ') =~? '^y'
      for l:path in l:del_paths
        if isdirectory(l:path)
          let l:cmd = has('win32') || has('win64') ? 'rmdir /S /Q ' : 'rm -rf '
          call system(l:cmd . shellescape(l:path))
        else
          call delete(l:path)
        endif
      endfor
    endif
  endif

  if !empty(l:errors)
    echohl ErrorMsg | for l:err in l:errors | echom l:err | endfor | echohl None
  endif

  call s:render()
endfunction
