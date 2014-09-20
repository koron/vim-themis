" themis: Test runner
" Version: 1.2
" Author : thinca <thinca+vim@gmail.com>
" License: zlib License

let s:save_cpo = &cpo
set cpo&vim

let s:runner = {
\   'events': [],
\   '_suppporters': {},
\ }

function! s:runner.init()
  call self.clear_event()
  let self.styles = {}
  for style_name in themis#module#list('style')
    let self.styles[style_name] = themis#module#style(style_name, self)
  endfor
endfunction

function! s:runner.run(paths, options)
  call self.init()
  let paths = type(a:paths) == type([]) ? a:paths : [a:paths]

  call s:load_themisrc(paths)

  let options = themis#option#merge(themis#option(), a:options)

  let files = s:paths2files(paths, options.recursive)

  let excludes = join(filter(copy(options.exclude), '!empty(v:val)'), '\|\m')
  if !empty(excludes)
    call filter(files, 'v:val !~# excludes')
  endif

  let files_with_styles = {}
  for file in files
    let style = s:can_handle(values(self.styles), file)
    if style !=# ''
      let files_with_styles[file] = style
    endif
  endfor

  if empty(files_with_styles)
    throw 'themis: Target file not found.'
  endif

  let error_count = 0
  let save_runtimepath = &runtimepath

  let appended = [getcwd()]
  if !empty(options.runtimepath)
    for rtp in options.runtimepath
      let appended += s:append_rtp(rtp)
    endfor
  endif

  let plugins = globpath(join(appended, ','), 'plugin/**/*.vim', 1)
  for plugin in split(plugins, "\n")
    execute 'source' fnameescape(plugin)
  endfor

  let self.target_pattern = join(options.target, '\m\|')

  let stats = self.supporter('stats')
  call self.init_bundle()
  let reporter = themis#module#reporter(options.reporter)
  call self.add_event(reporter)
  try
    call self.load_scripts(files_with_styles)
    call self.emit('script_loaded', self)
    call self.emit('start', self)
    call self.run_all()
    call self.emit('end', self)
    let error_count = stats.fail()
  catch
    let phase = get(self,  'phase', 'core')
    if v:exception =~# '^themis:'
      let info = {
      \   'exception': matchstr(v:exception, '\C^themis:\s*\zs.*'),
      \ }
    else
      let info = {
      \   'exception': v:exception,
      \   'stacktrace': themis#util#callstack(v:throwpoint, -1),
      \ }
    endif
    call self.emit('error', phase, info)
    let error_count = 1
  finally
    let &runtimepath = save_runtimepath
  endtry
  return error_count
endfunction

function! s:runner.init_bundle()
  let self.bundle = themis#bundle#new()
  let self.current_bundle = self.bundle
endfunction

function! s:runner.add_new_bundle(title)
  return self.add_bundle(themis#bundle#new(a:title))
endfunction

function! s:runner.add_bundle(bundle)
  if has_key(self, '_current')
    let a:bundle.filename = self._current.filename
    let a:bundle.style_name = self._current.style_name
  endif
  call self.current_bundle.add_child(a:bundle)
  return a:bundle
endfunction

function! s:runner.load_scripts(files_with_styles)
  let self.phase = 'script loading'
  for [filename, style_name] in items(a:files_with_styles)
    if !filereadable(filename)
      throw printf('themis: Target file was not found: %s', filename)
    endif
    let style = self.styles[style_name]
    let self._current = {
    \   'filename': filename,
    \   'style_name': style_name,
    \ }
    call style.load_script(filename)
    unlet self._current
  endfor
  unlet self.phase
endfunction

function! s:runner.run_all()
  call self.run_bundle(self.bundle)
endfunction

function! s:runner.run_bundle(bundle)
  let test_names = self.get_test_names(a:bundle)
  if empty(a:bundle.children) && empty(test_names)
    " skip: empty bundle
    return
  endif
  let self.current_bundle = a:bundle
  call self.emit('before_suite', a:bundle)
  call self.run_suite(a:bundle, test_names)
  for child in a:bundle.children
    call self.run_bundle(child)
  endfor
  call self.emit('after_suite', a:bundle)
endfunction

function! s:runner.run_suite(bundle, test_names)
  for name in a:test_names
    let report = themis#report#new(a:bundle, name)
    call self.emit('before_test', a:bundle, name)
    try
      let start_time = reltime()
      call a:bundle.run_test(name)
      let end_time = reltime(start_time)
      let report.result = 'pass'
      let report.time = str2float(reltimestr(end_time))
    catch
      call s:test_fail(report, v:exception, v:throwpoint)
    finally
      call self.emit(report.result, report)
      call self.emit('after_test', a:bundle, name)
    endtry
  endfor
endfunction

function! s:runner.get_test_names(bundle)
  let style = get(self.styles, a:bundle.get_style_name(), {})
  if empty(style)
    return []
  endif
  let names = style.get_test_names(a:bundle)
  if get(self, 'target_pattern', '') !=# ''
    let pat = self.target_pattern
    call filter(names, 'a:bundle.get_test_full_title(v:val) =~# pat')
  endif
  return names
endfunction

function! s:runner.supporter(name)
  if !has_key(self._suppporters, a:name)
    let self._suppporters[a:name] = themis#module#supporter(a:name, self)
  endif
  return self._suppporters[a:name]
endfunction

function! s:runner.add_event(event)
  call add(self.events, a:event)
  call s:call(a:event, 'init', [self])
endfunction

function! s:runner.clear_event()
  let self.events = []
endfunction

function! s:runner.total_test_count(...)
  let bundle = a:0 ? a:1 : self.bundle
  return len(self.get_test_names(bundle))
  \    + s:sum(map(copy(bundle.children), 'self.total_test_count(v:val)'))
endfunction

function! s:runner.emit(name, ...)
  let self.phase = a:name
  for event in self.events
    call s:call(event, a:name, a:000)
  endfor
  unlet self.phase
endfunction

function! s:call(obj, key, args)
  if has_key(a:obj, a:key)
    call call(a:obj[a:key], a:args, a:obj)
  elseif has_key(a:obj, '_')
    call call(a:obj['_'], [a:key, a:args], a:obj)
  endif
endfunction

function! s:test_fail(report, exception, throwpoint)
  if a:exception =~? '^themis:\_s*report:'
    let result = matchstr(a:exception, '\c^themis:\_s*report:\_s*\zs.*')
    let [a:report.type, a:report.message] =
    \   matchlist(result, '\v^%((\w+):\s*)?(.*)')[1 : 2]
  else
    let callstack = themis#util#callstacklines(a:throwpoint, -1)
    " TODO: More info to report
    let a:report.exception = a:exception
    let a:report.message = join(callstack, "\n") . "\n" . a:exception
  endif

  if get(a:report, 'type', '') =~# '^\u\+$'
    let a:report.result = 'pending'
  else
    let a:report.result = 'fail'
  endif
endfunction

function! s:append_rtp(path)
  let appended = []
  if isdirectory(a:path)
    let path = substitute(a:path, '\\\+', '/', 'g')
    let path = substitute(path, '/$', '', 'g')
    let &runtimepath = escape(path, '\,') . ',' . &runtimepath
    let appended += [path]
    let after = path . '/after'
    if isdirectory(after)
      let &runtimepath .= ',' . after
      let appended += [after]
    endif
  endif
  return appended
endfunction

function! s:load_themisrc(paths)
  let themisrcs = themis#util#find_files(a:paths, '.themisrc')
  for themisrc in themisrcs
    execute 'source' fnameescape(themisrc)
  endfor
endfunction

function! s:paths2files(paths, recursive)
  let files = []
  let target_pattern = a:recursive ? '**/*' : '*'
  for path in a:paths
    if isdirectory(path)
      let files += split(globpath(path, target_pattern, 1), "\n")
    else
      let files += [path]
    endif
  endfor
  let mods =  ':p:gs?\\?/?'
  return filter(map(files, 'fnamemodify(v:val, mods)'), '!isdirectory(v:val)')
endfunction

function! s:can_handle(styles, file)
  for style in a:styles
    if style.can_handle(a:file)
      return style.name
    endif
  endfor
  return ''
endfunction

function! s:sum(list)
  return empty(a:list) ? 0 : eval(join(a:list, '+'))
endfunction

function! themis#runner#new()
  let runner = deepcopy(s:runner)
  return runner
endfunction


let &cpo = s:save_cpo
unlet s:save_cpo
