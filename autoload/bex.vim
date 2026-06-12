" autoload/bex.vim - ID-tracked file browser engine (Free Cursor Layout)

if !exists('g:bex_id_counter')
	let g:bex_id_counter = 0
endif
if !exists('g:bex_cache')
	let g:bex_cache = {}
endif
if !exists('g:bex_path_ids')
	let g:bex_path_ids = {}
endif
if !exists('g:bex_snapshots')
	let g:bex_snapshots = {}
endif

function! bex#ToggleHidden() abort
	let g:bex_show_hidden = !g:bex_show_hidden
	call s:render()
endfunction

function! s:ensure_empty_line() abort
	let l:last = getline(line('$'))
	if !empty(trim(l:last))
		call append(line('$'), '')
	endif
endfunction

function! s:open_changes_buf() abort
	let l:main_win = winnr()
	if bufexists('bex://changes')
		let l:cbuf = bufnr('bex://changes')
		if bufwinnr(l:cbuf) == -1
			rightbelow vertical 1vnew
			execute 'buffer ' . l:cbuf
		endif
	else
		rightbelow vertical 1vnew
		edit bex://changes
		setlocal buftype=nofile bufhidden=wipe noswapfile nobuflisted
		setlocal nonumber norelativenumber nowrap
		setlocal filetype=bex_changes
		setlocal modifiable
		setlocal winfixwidth
		setlocal statusline=\ changes
	endif
	let b:bex_changes_for = bufnr('#')
	execute l:main_win . 'wincmd w'
	call s:update_changes_buf()
endfunction

function! s:resize_changes_buf() abort
	let l:cbuf = bufnr('bex://changes')
	if l:cbuf == -1 || bufwinnr(l:cbuf) == -1 | return | endif
	let l:cur_win = winnr()
	execute bufwinnr(l:cbuf) . 'wincmd w'
	vertical resize 30
	execute l:cur_win . 'wincmd w'
endfunction

function! s:update_changes_buf() abort
	let l:plan = s:prepare_buffer_changes()

	let l:all_plans = {b:bex_dir: l:plan}
	for [l:dir, l:cplan] in items(g:bex_cache)
		if l:dir !=# b:bex_dir
			let l:all_plans[l:dir] = l:cplan
		endif
	endfor

	let l:has_changes = 0
	for [l:dir, l:p] in items(l:all_plans)
		if !empty(l:p.del_buffer) || !empty(l:p.rename_buffer)
			\ || !empty(l:p.move_buffer) || !empty(l:p.copy_buffer)
			\ || !empty(l:p.entries_buffer)
			let l:has_changes = 1
			break
		endif
	endfor

	let l:cbuf = bufnr('bex://changes')
	if !l:has_changes
		if l:cbuf != -1 && bufwinnr(l:cbuf) != -1
			let l:cur_win = winnr()
			let l:cbufwin = bufwinnr(l:cbuf)
			execute l:cbufwin . 'wincmd w'
			close
			if winnr() != l:cur_win
				execute l:cur_win . 'wincmd w'
			endif
		endif
		return
	endif

	if l:cbuf == -1 || bufwinnr(l:cbuf) == -1
		call s:open_changes_buf()
		return
	endif

	let l:home = expand('$HOME')
	let l:lines = []
	let l:highlights = []
	let l:lnum = 1

	for [l:dir, l:p] in items(l:all_plans)
		let l:dir_has_changes = !empty(l:p.del_buffer) || !empty(l:p.rename_buffer)
			\ || !empty(l:p.move_buffer) || !empty(l:p.copy_buffer)
			\ || !empty(l:p.entries_buffer)
		if !l:dir_has_changes | continue | endif

		let l:dd = stridx(l:dir, l:home) == 0 ? '~/' . l:dir[len(l:home)+1:] : l:dir
		call add(l:lines, l:dd)
		call add(l:highlights, {'lnum': l:lnum, 'hl': 'BexChangesHeader'})
		let l:lnum += 1

		for l:entry in l:p.del_buffer
			let l:id = matchstr(l:entry, '^\/[0-9a-fA-F]\+')
			if has_key(l:p.snapshot, l:id)
				let l:name = l:p.snapshot[l:id].name . (l:p.snapshot[l:id].is_dir ? '/' : '')
				call add(l:lines, '  - ' . l:name)
				call add(l:highlights, {'lnum': l:lnum, 'hl': 'BexChangesDel'})
				let l:lnum += 1
			endif
		endfor

		for l:item in l:p.rename_buffer
			let l:old = substitute(l:item.old, '^\/[0-9a-fA-F]\+\s\+', '', '')
			let l:new = substitute(l:item.new, '^\/[0-9a-fA-F]\+\s\+', '', '')
			call add(l:lines, '  ~ ' . l:old . ' -> ' . l:new)
			call add(l:highlights, {'lnum': l:lnum, 'hl': 'BexChangesRename'})
			let l:lnum += 1
		endfor

		for l:entry in l:p.move_buffer
			let l:name = substitute(l:entry.new, '^\/[0-9a-fA-F]\+\s\+', '', '')
			call add(l:lines, '  -> ' . l:name . ' (move)')
			call add(l:highlights, {'lnum': l:lnum, 'hl': 'BexChangesMove'})
			let l:lnum += 1
		endfor

		for l:entry in l:p.copy_buffer
			let l:name = substitute(l:entry.new, '^\/[0-9a-fA-F]\+\s\+', '', '')
			call add(l:lines, '  + ' . l:name . ' (copy)')
			call add(l:highlights, {'lnum': l:lnum, 'hl': 'BexChangesAdd'})
			let l:lnum += 1
		endfor

		for l:entry in l:p.entries_buffer
			call add(l:lines, '  + ' . l:entry)
			call add(l:highlights, {'lnum': l:lnum, 'hl': 'BexChangesAdd'})
			let l:lnum += 1
		endfor

		call add(l:lines, '')
		let l:lnum += 1
	endfor

	let l:cur_win = winnr()
	let l:cbufwin = bufwinnr(l:cbuf)
	execute l:cbufwin . 'wincmd w'

	call setbufvar(l:cbuf, '&modifiable', 1)
	silent %delete _
	call setline(1, l:lines)

	call prop_clear(1, line('$'))
	for l:item in l:highlights
		call prop_add(l:item.lnum, 1, {
			\ 'end_col': len(getline(l:item.lnum)) + 1,
			\ 'type': l:item.hl,
		\ })
	endfor

let l:max_width = 0
	" 1. Iterate through all lines in the buffer
	for l:lnum in range(1, line('$'))
		let l:line_content = getline(l:lnum)
		let l:width = strdisplaywidth(l:line_content)
		
		if l:lnum > 1
			let l:width += 1
		endif
		
		let l:max_width = max([l:max_width, l:width])
	endfor

	" 3. Apply the width with a minimal sanity floor
	let l:final_width = max([20, l:max_width + 2])
	execute 'vertical resize ' . l:final_width

	call setbufvar(l:cbuf, '&modifiable', 0)
	execute l:cur_win . 'wincmd w'
endfunction

function! bex#Open(path) abort
	if empty(a:path)
		let l:current_file_dir = expand('%:p:h')
		let l:dir = empty(l:current_file_dir) ? getcwd() : l:current_file_dir
	else
		let l:dir = fnamemodify(a:path, ':p')
	endif

	if len(l:dir) > 1
		let l:dir = substitute(l:dir, '[/\\]$', '', '')
	endif

	if !isdirectory(l:dir)
		echoerr 'bex: Absolute path directory not found: ' . l:dir
		return
	endif

	if &modified
		execute 'split ' . fnameescape('bex://' . l:dir)
	else
		execute 'edit ' . fnameescape('bex://' . l:dir)
	endif

	setlocal buftype=acwrite
	setlocal bufhidden=wipe
	setlocal noswapfile
	setlocal nobuflisted
	setlocal filetype=bex
	setlocal nonumber norelativenumber
	setlocal nowrap

	let b:bex_dir = l:dir
	if !exists('g:bex_show_hidden')
		let g:bex_show_hidden = 0
	endif

	nnoremap <buffer> <silent> . :call bex#ToggleHidden()<CR>
	nnoremap <buffer> <silent> p p:call <SID>ensure_empty_line()<CR>
	nnoremap <buffer> <silent> P P:call <SID>ensure_empty_line()<CR>

	call s:render()
	call s:open_changes_buf()

	augroup bex_events
		autocmd! * <buffer>
		autocmd VimResized <buffer> call s:cache_current() | call s:render() | call s:reapply_props() | call s:resize_changes_buf() | call s:update_changes_buf()
		autocmd BufWriteCmd  <buffer> call s:on_write()
		autocmd BufLeave     <buffer> call s:on_leave()
		autocmd QuitPre      <buffer> call s:on_quit()
		"autocmd TextChanged  <buffer> call s:reapply_props()
		autocmd TextChangedI <buffer> call s:reapply_props()
		autocmd TextChanged  <buffer> call s:reapply_props() | call s:ensure_empty_line() | call s:update_changes_buf()
		autocmd TextChangedI <buffer> call s:reapply_props() | call s:ensure_empty_line() | call s:update_changes_buf()
		autocmd CursorMoved  <buffer> if line('.') == 1 | if line('$') == 1 | call append(1, '') | endif | call cursor(2, col('.')) | endif
		autocmd CursorMovedI <buffer> if line('.') == 1 | if line('$') == 1 | call append(1, '') | endif | call cursor(2, col('.')) | endif
	augroup END
endfunction

function! bex#Navigate(path) abort
	let l:dir = fnamemodify(a:path, ':p')
	if len(l:dir) > 1
		let l:dir = substitute(l:dir, '[/\\]$', '', '')
	endif
	if !isdirectory(l:dir)
		echoerr 'bex: Directory not found: ' . l:dir
		return
	endif

	call s:cache_current()

	setlocal nomodified
	let b:bex_dir = l:dir
	execute 'silent file ' . fnameescape('bex://' . l:dir)
	call s:render()
endfunction

function! s:cache_current() abort
	let l:plan = s:prepare_buffer_changes()
	let l:has_changes = !empty(l:plan.del_buffer)
		\ || !empty(l:plan.rename_buffer)
		\ || !empty(l:plan.entries_buffer)
		\ || !empty(l:plan.move_buffer)
		\ || !empty(l:plan.copy_buffer)
	if l:has_changes
		let g:bex_cache[b:bex_dir] = l:plan
	else
		if has_key(g:bex_cache, b:bex_dir)
			call remove(g:bex_cache, b:bex_dir)
		endif
	endif
endfunction

function! s:reset_cache() abort
	let g:bex_cache = {}
	let g:bex_snapshots = {}
	let g:bex_id_counter = 0
	let g:bex_path_ids = {}
endfunction

function! s:on_write() abort
	call s:cache_current()

	if empty(g:bex_cache)
		setlocal nomodified
		return
	endif

	" Validate all cached plans for errors first
	for [l:dir, l:plan] in items(g:bex_cache)
		if !empty(l:plan.error)
			echohl ErrorMsg | echom l:plan.error | echohl None
			return
		endif
	endfor

	" Collect all deletions that are not moves or copies
	let l:all_dels = []
	let l:home = expand('$HOME')
	for [l:dir, l:plan] in items(g:bex_cache)
		for l:entry in l:plan.del_buffer
			let l:id = matchstr(l:entry, '^\/[0-9a-fA-F]\+')
			if !s:id_exists_in_cache(l:id, l:dir)
				if has_key(l:plan.snapshot, l:id)
					let l:path = l:plan.snapshot[l:id].path
					let l:dpath = stridx(l:path, l:home) == 0 ? '~/' . l:path[len(l:home)+1:] : l:path
					call add(l:all_dels, {'id': l:id, 'dir': l:dir, 'path': l:path, 'display': l:dpath})
				endif
			endif
		endfor
	endfor

	if !empty(l:all_dels)
		echo 'bex: Files to delete:'
		for l:item in l:all_dels
			echo '  ' . l:item.display
		endfor
		let l:ans = input('bex: Delete these files and apply all changes? [y/N]: ')
		echo ''
		if l:ans !=# 'y' && l:ans !=# 'Y'
			setlocal nomodified
			return
		endif
	endif

	call s:apply_all()
endfunction

function! s:id_exists_in_cache(id, exclude_dir) abort
	for [l:dir, l:plan] in items(g:bex_cache)
		if l:dir ==# a:exclude_dir | continue | endif
		for l:entry in l:plan.rename_buffer
			if stridx(l:entry.new, a:id) == 0
				return 1
			endif
		endfor
		for l:entry in l:plan.entries_buffer
			if stridx(l:entry, a:id) == 0
				return 1
			endif
		endfor
		for l:entry in l:plan.move_buffer
			if stridx(l:entry.new, a:id) == 0
				return 1
			endif
		endfor
		for l:entry in l:plan.copy_buffer
			if stridx(l:entry.new, a:id) == 0
				return 1
			endif
		endfor
	endfor
	return 0
endfunction

function! s:apply_all() abort
	for [l:dir, l:plan] in items(g:bex_cache)
		call s:apply_plan(l:dir, l:plan)
	endfor
	call s:reset_cache()
	setlocal nomodified
	call s:render()
endfunction

function! s:apply_plan(dir, plan) abort
	let l:sep = (a:dir ==# '/' || a:dir ==# '\') ? '' : '/'

	" 1. Execute moves first (before deletes)
	for l:entry in a:plan.del_buffer
		let l:id = matchstr(l:entry, '^\/[0-9a-fA-F]\+')
		if !s:id_exists_in_cache(l:id, a:dir) | continue | endif
		if !has_key(a:plan.snapshot, l:id) | continue | endif
		let l:src = a:plan.snapshot[l:id].path
		for [l:ddir, l:dplan] in items(g:bex_cache)
			if l:ddir ==# a:dir | continue | endif
			for l:mentry in l:dplan.move_buffer
				if stridx(l:mentry.new, l:id) == 0
					let l:dname = substitute(l:mentry.new, '^\/[0-9a-fA-F]\+\s\+', '', '')
					let l:dname = substitute(l:dname, '/$', '', '')
					let l:dsep = (l:ddir ==# '/' || l:ddir ==# '\') ? '' : '/'
					let l:dst = l:ddir . l:dsep . l:dname
					call rename(l:src, l:dst)
					let g:bex_path_ids[l:dst] = str2nr(matchstr(l:id, '[0-9a-fA-F]\+$'), 16)
					if has_key(g:bex_path_ids, l:src)
						call remove(g:bex_path_ids, l:src)
					endif
				endif
			endfor
		endfor
	endfor

	" 2. Execute copies
	for l:centry in a:plan.copy_buffer
		let l:id = l:centry.id
		let l:src = ''
		for [l:sdir, l:ssnap] in items(g:bex_snapshots)
			if has_key(l:ssnap, l:id)
				let l:src = l:ssnap[l:id].path
				break
			endif
		endfor
		if empty(l:src) | continue | endif
		let l:dname = substitute(l:centry.new, '^\/[0-9a-fA-F]\+\s\+', '', '')
		let l:dname = substitute(l:dname, '/$', '', '')
		let l:dst = a:dir . l:sep . l:dname
		if filereadable(l:dst) || isdirectory(l:dst)
			echohl ErrorMsg
			echom 'bex: Already exists: ' . l:dname
			echohl None
			continue
		endif
		if isdirectory(l:src)
			call system('cp -r ' . shellescape(l:src) . ' ' . shellescape(l:dst))
		else
			call system('cp ' . shellescape(l:src) . ' ' . shellescape(l:dst))
		endif
	endfor

	" 3. Delete (skip moves and copies)
	for l:entry in a:plan.del_buffer
		let l:id = matchstr(l:entry, '^\/[0-9a-fA-F]\+')
		if s:id_exists_in_cache(l:id, a:dir) | continue | endif
		if has_key(a:plan.snapshot, l:id)
			let l:path = a:plan.snapshot[l:id].path
			call delete(l:path, isdirectory(l:path) ? 'rf' : '')
		endif
	endfor

	" 4. Rename to __tmp__
	let l:tmp_buffer = []
	for l:item in a:plan.rename_buffer
		if !has_key(a:plan.snapshot, l:item.id) | continue | endif
		let l:old_path = a:plan.snapshot[l:item.id].path
		let l:tmp_path = fnamemodify(l:old_path, ':h') . '/__tmp__.' . fnamemodify(l:old_path, ':t')
		call rename(l:old_path, l:tmp_path)
		call add(l:tmp_buffer, {'tmp': l:tmp_path, 'new_name': substitute(l:item.new, '^\/[0-9a-fA-F]\+\s\+', '', '')})
	endfor

	" 5. Create new entries
	for l:entry in a:plan.entries_buffer
		let l:name = substitute(l:entry, '/$', '', '')
		let l:path = a:dir . l:sep . l:name
		if l:entry =~# '/$'
			call mkdir(l:path, 'p')
		else
			call writefile([], l:path)
		endif
	endfor

	" 6. Finalize renames
	for l:item in l:tmp_buffer
		let l:dst = fnamemodify(l:item.tmp, ':h') . '/' . substitute(l:item.new_name, '/$', '', '')
		call rename(l:item.tmp, l:dst)
	endfor
endfunction

function! s:on_leave() abort
	call s:cache_current()
	setlocal nomodified
endfunction

function! s:confirm_preview(apply) abort
	bwipe
	if a:apply
		call s:apply_all()
	else
		call setbufvar(bufnr('#'), '&modified', 0)
	endif
endfunction

function! s:on_quit() abort
	if &filetype !=# 'bex' | return | endif

	" Close changes buffer if open
	let l:cbuf = bufnr('bex://changes')
	if l:cbuf != -1 && bufwinnr(l:cbuf) != -1
		let l:cbufwin = bufwinnr(l:cbuf)
		execute l:cbufwin . 'wincmd w'
		close
	endif

	call s:cache_current()
	setlocal nomodified

	if empty(g:bex_cache) | return | endif
	let l:count = len(g:bex_cache)
	let l:ans = input('bex: Unsaved changes across ' . l:count . ' director' . (l:count == 1 ? 'y' : 'ies') . ', apply? [y/N]: ')
	echo ''
	if l:ans ==# 'y' || l:ans ==# 'Y'
		call s:apply_all()
	else
		call s:reset_cache()
		setlocal nomodified
	endif
endfunction

function! s:relative_time(ftime) abort
	let l:diff = localtime() - a:ftime
	if l:diff < 60 | return l:diff . 's ago'
	elseif l:diff < 3600 | return (l:diff / 60) . 'm ago'
	elseif l:diff < 86400 | return (l:diff / 3600) . 'h ago'
	elseif l:diff < 604800 | return (l:diff / 86400) . 'd ago'
	elseif l:diff < 2419200 | return (l:diff / 604800) . 'w ago'
	elseif l:diff < 29030400 | return (l:diff / 2419200) . 'mo ago'
	else | return (l:diff / 29030400) . 'y ago'
	endif
endfunction

function! s:human_size(size) abort
	if a:size < 1024 | return a:size . 'B'
	elseif a:size < 1048576 | return (a:size / 1024) . 'KB'
	elseif a:size < 1073741824 | return (a:size / 1048576) . 'MB'
	elseif a:size < 1099511627776 | return (a:size / 1073741824) . 'GB'
	else | return (a:size / 1099511627776) . 'TB'
	endif
endfunction

function! s:reapply_props() abort
	if empty(prop_type_get('bex_header'))
		call prop_type_add('bex_header', {'highlight': 'BexHeader'})
	endif
	if empty(prop_type_get('bex_info'))
		call prop_type_add('bex_info', {'highlight': 'BexInfo'})
	endif
	call prop_clear(1, line('$'))
	call s:render_header()
	for l:lnum in range(2, line('$'))
		let l:line = getline(l:lnum)
		let l:id = matchstr(l:line, '^\/[0-9a-fA-F]\{8}')
		if empty(l:id) | continue | endif
		if !has_key(b:bex_snapshot, l:id) | continue | endif
		let l:item = b:bex_snapshot[l:id]
		let l:perm = getfperm(l:item.path)
		let l:size = getfsize(l:item.path)
		let l:info = printf('%-10s %8s %10s', l:perm, s:human_size(l:size), s:relative_time(getftime(l:item.path)))
		call prop_add(l:lnum, 0, {'type': 'bex_info', 'text': l:info, 'text_align': 'right'})
	endfor
endfunction

function! s:render_header() abort
	if !empty(prop_type_get('bex_status'))
		call prop_type_delete('bex_status')
	endif
	call prop_type_add('bex_status', {'highlight': g:bex_show_hidden ? 'BexVisible' : 'BexHidden'})
	let l:home = expand('$HOME')
	let l:left = stridx(b:bex_dir, l:home) == 0 ? '~/' . b:bex_dir[len(l:home)+1:] : b:bex_dir
	let l:right = g:bex_show_hidden ? 'dotfiles=on' : 'dotfiles=off'
	call prop_add(1, 0, {
		\ 'type': 'bex_header',
		\ 'text': l:left,
		\ 'text_padding_left': 0,
	\ })
	call prop_add(1, 0, {
		\ 'type': 'bex_status',
		\ 'text': l:right,
		\ 'text_align': 'right',
	\ })
endfunction

function! s:render() abort
	let l:save_cursor = getcurpos()

	let l:sep = (b:bex_dir ==# '/' || b:bex_dir ==# '\') ? '' : '/'

	let l:all = glob(b:bex_dir . l:sep . '*', 0, 1)
	if g:bex_show_hidden
		let l:all += glob(b:bex_dir . l:sep . '.[^.]*', 0, 1)
	endif

	let b:bex_snapshot = {}
	let l:lines = []

	for l:p in l:all
		let l:name = fnamemodify(l:p, ':t')
		if l:name ==# '.' || l:name ==# '..' || empty(l:name) | continue | endif
		let l:is_dir = isdirectory(l:p)

		if has_key(g:bex_path_ids, l:p)
			let l:raw_id = g:bex_path_ids[l:p]
		else
			let l:raw_id = g:bex_id_counter
			let g:bex_id_counter += 1
			let g:bex_path_ids[l:p] = l:raw_id
		endif

		let l:id = printf('/%08x ', l:raw_id)
		let l:display = l:name . (l:is_dir ? '/' : '')
		call add(l:lines, l:id . l:display)
		let b:bex_snapshot[trim(l:id)] = { 'name': l:name, 'is_dir': l:is_dir, 'path': l:p }
	endfor

	let g:bex_snapshots[b:bex_dir] = copy(b:bex_snapshot)

	silent %delete _
	call setline(1, [''] + l:lines)
	if empty(l:lines)
		call append(1, '')
	endif
	setlocal nomodified

	call prop_clear(1, line('$'))

	highlight Normal		ctermfg=White
	highlight BexHeader		ctermfg=Blue cterm=bold gui=bold
	highlight BexInfo		guifg=#555555 ctermfg=239
	highlight BexID			guifg=#555555 ctermfg=239
	highlight BexDir		ctermfg=Blue cterm=bold
	highlight BexHiddenDir	ctermfg=Blue cterm=bold
	highlight BexHiddenFile	ctermfg=White
	highlight BexVisible	ctermfg=Green cterm=bold gui=bold
	highlight BexHidden		ctermfg=Red cterm=bold gui=bold

	highlight BexChangesHeader ctermfg=Blue   cterm=bold gui=bold
	highlight BexChangesDel    ctermfg=Red    cterm=bold gui=bold
	highlight BexChangesRename ctermfg=Green  cterm=bold gui=bold
	highlight BexChangesMove   ctermfg=Cyan   cterm=bold gui=bold
	highlight BexChangesAdd    ctermfg=Green

	for l:hl in ['BexChangesHeader', 'BexChangesDel', 'BexChangesRename', 'BexChangesMove', 'BexChangesAdd']
		if !empty(prop_type_get(l:hl))
			call prop_type_delete(l:hl)
		endif
		call prop_type_add(l:hl, {'highlight': l:hl})
	endfor



	if !empty(prop_type_get('bex_header'))
		call prop_type_delete('bex_header')
	endif
	call prop_type_add('bex_header', {'highlight': 'BexHeader'})
	if !empty(prop_type_get('bex_info'))
		call prop_type_delete('bex_info')
	endif
	call prop_type_add('bex_info', {'highlight': 'BexInfo'})

	call s:render_header()

	let l:idx = 0
	for l:p in l:all
		let l:name = fnamemodify(l:p, ':t')
		if l:name ==# '.' || l:name ==# '..' || empty(l:name) | continue | endif
		let l:perm = getfperm(l:p)
		let l:size = getfsize(l:p)
		let l:info = printf('%-10s %8s %10s', l:perm, s:human_size(l:size), s:relative_time(getftime(l:p)))
		call prop_add(l:idx + 2, 0, {'type': 'bex_info', 'text': l:info, 'text_align': 'right'})
		let l:idx += 1
	endfor

	"setlocal conceallevel=2
	"setlocal concealcursor=vc

	syntax clear
	syntax match BexID /^\/[0-9a-fA-F]\+\ze\s/
	syntax match BexDir        /\zs\S\+\/$/
	syntax match BexHiddenDir  /\zs\.[^/]*\/$/
	syntax match BexHiddenFile /\%(^\s*\|\s\)\zs\.[^/]\+$/

	call s:restore_cached_buffer()

	call setpos('.', l:save_cursor)
endfunction

function! s:restore_cached_buffer() abort
	if !has_key(g:bex_cache, b:bex_dir) | return | endif
	let l:plan = g:bex_cache[b:bex_dir]

	" Remove deleted entries
	for l:entry in l:plan.del_buffer
		let l:id = matchstr(l:entry, '^\/[0-9a-fA-F]\+')
		for l:lnum in range(line('$'), 2, -1)
			if stridx(getline(l:lnum), l:id) == 0
				silent execute l:lnum . 'd _'
				break
			endif
		endfor
	endfor

	" Reapply renames
	for l:item in l:plan.rename_buffer
		for l:lnum in range(2, line('$'))
			if stridx(getline(l:lnum), l:item.id) == 0
				call setline(l:lnum, l:item.new)
				break
			endif
		endfor
	endfor

	" Reapply pasted moves/copies
	for l:entry in l:plan.move_buffer + l:plan.copy_buffer
		let l:found = 0
		for l:lnum in range(2, line('$'))
			if stridx(getline(l:lnum), l:entry.id) == 0
				let l:found = 1
				break
			endif
		endfor
		if !l:found
			call append(line('$'), l:entry.new)
		endif
	endfor

	" Reapply new entries
	for l:entry in l:plan.entries_buffer
		let l:found = 0
		for l:lnum in range(2, line('$'))
			if getline(l:lnum) ==# l:entry
				let l:found = 1
				break
			endif
		endfor
		if !l:found
			call append(line('$'), l:entry)
		endif
	endfor

	setlocal nomodified
endfunction

function! s:prepare_buffer_changes() abort
	let l:result = {
		\ 'error': '',
		\ 'path': b:bex_dir,
		\ 'snapshot': b:bex_snapshot,
		\ 'del_buffer': [],
		\ 'rename_buffer': [],
		\ 'entries_buffer': [],
		\ 'move_buffer': [],
		\ 'copy_buffer': [],
	\ }

	let l:HasId = {line -> len(matchstr(line, '^\/[0-9a-fA-F]\+')) > 1}

	let l:new_buffer = []
	for l:line in getline(2, line('$'))
		if !empty(trim(l:line))
			call add(l:new_buffer, l:line)
		endif
	endfor

	let l:old_buffer = []
	for [l:id, l:item] in items(b:bex_snapshot)
		call add(l:old_buffer, l:id . ' ' . l:item.name . (l:item.is_dir ? '/' : ''))
	endfor

	" Deletions
	for l:entry in l:old_buffer
		let l:id = matchstr(l:entry, '^\/[0-9a-fA-F]\+')
		let l:found = 0
		for l:new_line in l:new_buffer
			if stridx(l:new_line, l:id) == 0
				let l:found = 1
				break
			endif
		endfor
		if !l:found
			call add(l:result.del_buffer, l:entry)
		endif
	endfor

	" Renames, moves, copies and new entries
	for l:new_line in l:new_buffer
		if l:HasId(l:new_line)
			let l:id = matchstr(l:new_line, '^\/[0-9a-fA-F]\+')
			let l:in_old = 0
			for l:old_entry in l:old_buffer
				if stridx(l:old_entry, l:id) == 0
					let l:in_old = 1
					if l:old_entry !=# l:new_line && !empty(l:id)
						call add(l:result.rename_buffer, {'id': l:id, 'old': l:old_entry, 'new': l:new_line})
					endif
					break
				endif
			endfor
			if !l:in_old
				let l:origin_count = 0
				for [l:odir, l:osnap] in items(g:bex_snapshots)
					if l:odir ==# b:bex_dir | continue | endif
					if !has_key(l:osnap, l:id) | continue | endif
					let l:deleted_in_origin = 0
					if has_key(g:bex_cache, l:odir)
						for l:odel in g:bex_cache[l:odir].del_buffer
							if stridx(l:odel, l:id) == 0
								let l:deleted_in_origin = 1
								break
							endif
						endfor
					endif
					if !l:deleted_in_origin
						let l:origin_count += 1
					endif
				endfor
				if l:origin_count > 0
					call add(l:result.copy_buffer, {'id': l:id, 'new': l:new_line})
				else
					call add(l:result.move_buffer, {'id': l:id, 'new': l:new_line})
				endif
			endif
		else
			call add(l:result.entries_buffer, l:new_line)
		endif
	endfor

	" Collision check
	let l:seen = []
	for l:line in l:result.rename_buffer + l:result.entries_buffer + l:result.move_buffer + l:result.copy_buffer
		let l:name = substitute(type(l:line) == v:t_dict ? l:line.new : l:line, '^\/[0-9a-fA-F]\+\s\+', '', '')
		if index(l:seen, l:name) >= 0
			let l:result.error = 'bex: Collision detected: ' . l:name
			return l:result
		endif
		call add(l:seen, l:name)
	endfor

	" Check new entries don't already exist on disk
	let l:sep = (b:bex_dir ==# '/' || b:bex_dir ==# '\') ? '' : '/'
	for l:entry in l:result.entries_buffer
		let l:name = substitute(l:entry, '/$', '', '')
		let l:path = b:bex_dir . l:sep . l:name
		if filereadable(l:path) || isdirectory(l:path)
			let l:result.error = 'bex: Already exists: ' . l:name
			return l:result
		endif
	endfor

	for l:entry in l:result.move_buffer + l:result.copy_buffer
		let l:name = substitute(substitute(l:entry.new, '^\/[0-9a-fA-F]\+\s\+', '', ''), '/$', '', '')
		let l:path = b:bex_dir . l:sep . l:name
		if filereadable(l:path) || isdirectory(l:path)
			let l:result.error = 'bex: Already exists: ' . l:name
			return l:result
		endif
	endfor

	return l:result
endfunction

function! bex#OnSelect() abort
	let l:line = getline('.')
	let l:match = matchlist(l:line, '^\(\/[0-9a-fA-F]\+\)\s\+\(.*\)$')
	if empty(l:match) | return | endif

	let l:id = l:match[1]
	if !has_key(b:bex_snapshot, l:id) | return | endif
	let l:item = b:bex_snapshot[l:id]

	if l:item.is_dir
		call bex#Navigate(l:item.path)
	else
		call s:cache_current()
		setlocal nomodified
		execute 'edit ' . fnameescape(l:item.path)
	endif
endfunction

function! bex#GoUp() abort
	let l:parent = fnamemodify(b:bex_dir, ':h')
	if l:parent ==# b:bex_dir
		echo 'bex: Already at root directory'
		return
	endif
	let l:prev_dir = b:bex_dir
	call bex#Navigate(l:parent)
	" Find and jump to the line matching the dir we came from
	let l:prev_name = fnamemodify(l:prev_dir, ':t') . '/'
	for l:lnum in range(2, line('$'))
		let l:line = getline(l:lnum)
		if l:line =~# '\s' . l:prev_name . '$' || l:line =~# '\s' . l:prev_name . '\s'
			call cursor(l:lnum, col('.'))
			break
		endif
	endfor
endfunction
