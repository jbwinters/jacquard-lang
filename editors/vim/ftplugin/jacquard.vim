" Jacquard filetype settings.
if exists("b:did_ftplugin")
  finish
endif
let b:did_ftplugin = 1

setlocal comments=:--\|,:--
setlocal commentstring=--\ %s
" Kebab-case names ending in ? or ! are single words for motions and *.
setlocal iskeyword=@,48-57,_,-,?,!

let b:undo_ftplugin = "setlocal comments< commentstring< iskeyword<"
