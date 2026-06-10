" autoload/bex.vim - ID-tracked file browser engine (Free Cursor Layout)

function! bex#Open(path) abort
	" If no path is given, fall back to the active file's directory. 
	" If the current buffer has no file, use getcwd().
	if empty(a:path)
		let l:current_file_dir = expand('%:p:h')
		let l:dir = empty(l:current_file_dir) ? getcwd() : l:current_file_dir
	else
		let l:dir = fnamemodify(a:path, ':p')
	endif
  
	" Clean up trailing slashes only if it isn't the system root directory "/"
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
	nnoremap <buffer> . :let g:bex_show_hidden = !g:bex_show_hidden <bar> call <SID>render()<CR>
	call s:render()

  	augroup bex_events
		autocmd! * <buffer>
		autocmd BufWriteCmd <buffer> call s:apply_buffer_changes()
		autocmd BufLeave     <buffer> call s:confirm_unsaved()
		autocmd QuitPre      <buffer> call s:confirm_unsaved()
		autocmd TextChanged  <buffer> call s:reapply_props()
		autocmd TextChangedI <buffer> call s:reapply_props()
	augroup ENDendfunction
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
	call prop_clear(1, line('$'))
	for l:lnum in range(1, line('$'))
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

function! s:render() abort
	let l:save_cursor = getcurpos()
  
	" Prevent double-slashing "//" when rendering files inside the system root directory
	let l:sep = (b:bex_dir ==# '/' || b:bex_dir ==# '\') ? '' : '/'
	
	let l:all = glob(b:bex_dir . l:sep . '*', 0, 1)
	if g:bex_show_hidden
		let l:all += glob(b:bex_dir . l:sep . '.[^.]*', 0, 1)
	endif
	
	
	let b:bex_snapshot = {}
  
	let l:lines = []
	let l:idx = 0
  
	for l:p in l:all
		let l:name = fnamemodify(l:p, ':t')
		if l:name ==# '.' || l:name ==# '..' || empty(l:name) | continue | endif
    
		let l:is_dir = isdirectory(l:p)
		let l:id = printf('/%08x ', l:idx)
		let l:display = l:name . (l:is_dir ? '/' : '')
    
		call add(l:lines, l:id . l:display)
		let b:bex_snapshot[trim(l:id)] = { 'name': l:name, 'is_dir': l:is_dir, 'path': l:p }
		let l:idx += 1
	endfor

	silent %delete _
	call setline(1, l:lines)
	setlocal nomodified

	call prop_clear(1, line('$'))
	highlight BexInfo guifg=#555555 ctermfg=239
	if empty(prop_type_get('bex_info'))
		call prop_type_add('bex_info', {'highlight': 'BexInfo'})
	endif

	let l:idx = 0
	for l:p in l:all
		let l:name = fnamemodify(l:p, ':t')
		if l:name ==# '.' || l:name ==# '..' || empty(l:name) | continue | endif

		let l:perm = getfperm(l:p)
		let l:size = getfsize(l:p)
		let l:info = printf('%-10s %8s %10s', l:perm, s:human_size(l:size), s:relative_time(getftime(l:p)))
		call prop_add(l:idx + 1, 0, {'type': 'bex_info', 'text': l:info, 'text_align': 'right'})
		let l:idx += 1
	endfor
  
	syntax clear
	syntax match BexID /^\/[0-9a-fA-F]\+\ze\s/
	syntax match BexDir        /\zs\S\+\/$/
	syntax match BexHiddenDir  /\zs\.[^/]*\/$/
	syntax match BexHiddenFile /\%(^\s*\|\s\)\zs\.[^/]\+$/

	highlight Normal ctermfg=White 
	highlight BexID guifg=#555555 ctermfg=239
	highlight BexDir ctermfg=Blue cterm=bold
	highlight BexHiddenDir ctermfg=Blue cterm=bold
	highlight BexHiddenFile ctermfg=White

	call setpos('.', l:save_cursor)
endfunction

function! s:confirm_unsaved() abort
	if &modified
		let l:ans = input('bex: Unsaved changes, apply them? [y/N]: ')
		if l:ans ==# 'y' || l:ans ==# 'Y'
			call s:apply_buffer_changes()
		else
			setlocal nomodified
		endif
	endif
endfunction

function! bex#OnSelect() abort
	let l:line = getline('.')
	let l:match = matchlist(l:line, '^\(\/[0-9a-fA-F]\+\)\s\+\(.*\)$')
	if empty(l:match) | return | endif

	let l:id = l:match[1]
	if !has_key(b:bex_snapshot, l:id) | return | endif
	let l:item = b:bex_snapshot[l:id]

	call s:confirm_unsaved()

	if l:item.is_dir
		call bex#Open(l:item.path)
	else
		execute 'edit ' . fnameescape(l:item.path)
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
	setlocal nomodified

	let l:throw_error = v:false
	let l:err = ""

	" Queried buffers
	let l:new_buffer = []
	let l:old_buffer = []

	" Modification order. 
	" 1. Delete
	" 2. Rename (__tmp__ name)
	" 3. Create entries
	" 4. Remove (__tmp__)
	let l:del_buffer = []
	let l:rename_buffer = []
	let l:entries_buffer = []
	let l:result_buffer = []

	let l:HasId = {line -> len(matchstr(line, '^\/[0-9a-fA-F]\{8}')) == 9}

	for l:line in getline(1, line('$'))
		if !empty(trim(l:line))
			call add(l:new_buffer, l:line)
		endif
	endfor
	
	for [l:id, l:item] in items(b:bex_snapshot)
		call add(l:old_buffer, l:id . ' ' . l:item.name . (l:item.is_dir ? '/' : ''))
	endfor

	for l:entry in l:old_buffer
		let l:id = matchstr(l:entry, '^\/[0-9a-fA-F]\{8}')
		let l:found = 0
		for l:new_line in l:new_buffer
			if stridx(l:new_line, l:id) == 0
				let l:found = 1
				break
			endif
		endfor
		
		if !l:found
			call add(l:del_buffer, l:entry)
		endif
	endfor

	for l:new_line in l:new_buffer
		if l:HasId(l:new_line)
			let l:id = matchstr(l:new_line, '^\/[0-9a-fA-F]\{8}')
			for l:old_entry in l:old_buffer
				if stridx(l:old_entry, l:id) == 0
					if l:old_entry !=# l:new_line
						if !empty(l:id)
							call add(l:rename_buffer, {'id': l:id, 'old': l:old_entry, 'new': l:new_line})
						endif
					endif
					break
				endif
			endfor
		else
			call add(l:entries_buffer, l:new_line)
		endif
	endfor

	let l:result_buffer = []
	for l:item in l:rename_buffer
		call add(l:result_buffer, l:item.new)
	endfor
	for l:item in l:entries_buffer
		call add(l:result_buffer, l:item)
	endfor

	" Collision check
	let l:seen = []
	for l:line in l:result_buffer
		let l:name = substitute(l:line, '^\/[0-9a-fA-F]\{8}\s\+', '', '')
		if index(l:seen, l:name) >= 0
			let l:throw_error = v:true
			let l:err = "bex: Collision detected: " . l:name
			break
		endif
		call add(l:seen, l:name)
	endfor

	" Check new entries don't already exist on disk
	let l:sep = (b:bex_dir ==# '/' || b:bex_dir ==# '\') ? '' : '/'
	for l:entry in l:entries_buffer
		let l:name = substitute(l:entry, '/$', '', '')
		let l:path = b:bex_dir . l:sep . l:name
		if filereadable(l:path) || isdirectory(l:path)
			let l:throw_error = v:true
			let l:err = 'bex: Already exists: ' . l:name
			break
		endif
	endfor

	if l:throw_error
		echohl ErrorMsg | echom l:err | echohl None
		return
	endif

	" 1. Delete
	for l:entry in l:del_buffer
		let l:id = matchstr(l:entry, '^\/[0-9a-fA-F]\{8}')
		if has_key(b:bex_snapshot, l:id)
			let l:path = b:bex_snapshot[l:id].path
			if isdirectory(l:path)
				call delete(l:path, 'rf')
			else
				call delete(l:path)
			endif
		endif
	endfor

	" 2. Rename to __tmp__
	let l:tmp_buffer = []
	for l:item in l:rename_buffer
		let l:old_path = b:bex_snapshot[l:item.id].path
		let l:tmp_path = fnamemodify(l:old_path, ':h') . '/__tmp__.' . fnamemodify(l:old_path, ':t')
		call rename(l:old_path, l:tmp_path)
		call add(l:tmp_buffer, {'tmp': l:tmp_path, 'new_name': substitute(l:item.new, '^\/[0-9a-fA-F]\{8}\s\+', '', '')})
	endfor
	
	" 3. Create new entries
	let l:sep = (b:bex_dir ==# '/' || b:bex_dir ==# '\') ? '' : '/'
	for l:entry in l:entries_buffer
		let l:name = substitute(l:entry, '/$', '', '')
		let l:path = b:bex_dir . l:sep . l:name
		if l:entry =~# '/$'
			call mkdir(l:path, 'p')
		else
			call writefile([], l:path)
		endif
	endfor

	" 4. Finalize renames
	for l:item in l:tmp_buffer
		let l:dst = fnamemodify(l:item.tmp, ':h') . '/' . substitute(l:item.new_name, '/$', '', '')
		call rename(l:item.tmp, l:dst)
	endfor

	" Confirm deletions
	if !empty(l:del_buffer)
		let l:home = expand('$HOME')
		echo "bex: Files to delete:"
		for l:entry in l:del_buffer
			let l:id = matchstr(l:entry, '^\/[0-9a-fA-F]\{8}')
			if has_key(b:bex_snapshot, l:id)
				let l:dpath = b:bex_snapshot[l:id].path
				let l:dpath = stridx(l:dpath, l:home) == 0 ? '~/' . l:dpath[len(l:home)+1:] : l:dpath
				echo "  " . l:dpath
			endif
		endfor
		let l:confirm = input("bex: Delete these files? [y/N]: ")
		if l:confirm !=# 'y' && l:confirm !=# 'Y'
			echo "\nbex: Deletion cancelled"
			let l:del_buffer = []
		endif
		echo ""
	endif
	
	call s:render()
endfunction
