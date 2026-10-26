" Vim syntax file
" Language: Jacquard surface syntax (.jac)
" Source of truth: src/surface_lex.ml and docs/surface-syntax.md. The keyword
" list must equal Surface_lex.keywords; editors/check.sh enforces that.

if exists("b:current_syntax")
  finish
endif

" Names are kebab-case, may be dotted and may end in ? or !, and the lexer
" matches keywords against the whole atom, so all of those characters are part
" of a word: `option.then` is a name, not the keyword `then`.
syn iskeyword @,48-57,_,-,?,!,.

syn keyword jacquardConditional if then else match
syn keyword jacquardStatement handle return resume try
syn keyword jacquardStorageClass once multi
syn keyword jacquardStructure type effect
syn keyword jacquardDeclaration fn let rec
syn keyword jacquardKeyword where forall as with
syn keyword jacquardQuote quote unquote jqd
syn match jacquardStorageClass /\<opaque\ze\s\+type\>/

" Patterns use whole atoms; the lexer ends an atom at whitespace,
" ( ) { } [ ] , : ; = | " ` # or ->.
syn match jacquardCall /\<\l[a-z0-9.-]*[?!]\=\ze(/
" A top-level signature or definition head; defined after jacquardCall so it wins.
syn match jacquardDefinition /^\l[a-z0-9.-]*[?!]\=\ze\s*[(:=]/
" An atom also ends at ->, which \> misses because - is a word character.
syn match jacquardType /\<\u[A-Za-z0-9]*\ze\%(->\|[^A-Za-z0-9_?!.-]\|$\)/
syn match jacquardWildcard /\<_\ze\%(->\|[^A-Za-z0-9_?!.-]\|$\)/

syn match jacquardNumber /\%(^\|[^A-Za-z0-9_?!.+-]\)\@1<=-\=\d\+\%(\.\d*\)\=\%([eE][+-]\=\d\+\)\=\ze\%(->\|[^A-Za-z0-9_?!.-]\|$\)/
syn match jacquardNumber /\%(^\|[^A-Za-z0-9_?!.+-]\)\@1<=[+-]\%(inf\|nan\)\.0\ze\%(->\|[^A-Za-z0-9_?!.-]\|$\)/

syn match jacquardEscapedName /`\%(term\|op\|type\|con\|effect\|tvar\|rvar\):[^`]*`/
syn match jacquardReference /#group\[\d\+\]/
" read_hash ends a reference at whitespace, ( ) { } [ ] , ; = | " ` or ->.
syn match jacquardReference /#\x\{64}:\%(term\|op\|type\|con\|effect\)\ze\%(->\|[ \t(){}\[\],;=|"`]\|$\)/

syn match jacquardOperator /->\||>\||\|=/

syn match jacquardStringEscape /\\\%([\\"ntr]\|x\x\x\)/ contained
" Plain strings may span lines, as in the lexer; marked text may not.
syn region jacquardString start=/"/ skip=/\\\\\|\\"/ end=/"/ contains=jacquardStringEscape,@Spell
syn match jacquardBraceEscape /{{/ contained
" An interpolation ends at the } that balances its {, as in the lexer.
syn cluster jacquardNotInCode contains=jacquardStringEscape,jacquardBraceEscape,jacquardInterpolation,jacquardTodo,jacquardRawParens,jacquardRawString,jacquardRawComment
syn region jacquardInterpolation matchgroup=jacquardInterpolationDelimiter start=/{\ze[^{]/ end=/}/ contained oneline contains=ALLBUT,@jacquardNotInCode
syn region jacquardInterpolationBraces start=/{/ end=/}/ contained oneline transparent contains=ALLBUT,@jacquardNotInCode
syn region jacquardMarkedText start=/\$"/ skip=/\\\\\|\\"/ end=/"\|$/ oneline contains=jacquardStringEscape,jacquardBraceEscape,jacquardInterpolation,@Spell

" jqd { ... } is raw bootstrap syntax: balanced parentheses, strings and
" ; comments, ending at the first } outside parentheses.
syn region jacquardRaw matchgroup=jacquardQuote start=/\%(\<jqd\s*\)\@<={/ end=/}/ contains=jacquardRawParens,jacquardRawString,jacquardRawComment,jacquardNumber
syn region jacquardRawParens start=/(/ end=/)/ contained transparent contains=jacquardRawParens,jacquardRawString,jacquardRawComment,jacquardNumber
syn region jacquardRawString start=/"/ skip=/\\\\\|\\"/ end=/"/ contained contains=jacquardStringEscape
syn match jacquardRawComment /;.*$/ contained

syn keyword jacquardTodo TODO FIXME XXX NOTE contained
syn match jacquardComment /--.*$/ contains=jacquardTodo,@Spell
syn match jacquardDocComment /--|.*$/ contains=jacquardTodo,@Spell

syn sync minlines=200

hi def link jacquardConditional Conditional
hi def link jacquardStatement Statement
hi def link jacquardStorageClass StorageClass
hi def link jacquardStructure Structure
hi def link jacquardDeclaration Keyword
hi def link jacquardKeyword Keyword
hi def link jacquardQuote PreProc
hi def link jacquardDefinition Function
hi def link jacquardCall Function
hi def link jacquardType Type
hi def link jacquardWildcard Special
hi def link jacquardNumber Number
hi def link jacquardEscapedName Identifier
hi def link jacquardReference Constant
hi def link jacquardOperator Operator
hi def link jacquardString String
hi def link jacquardMarkedText String
hi def link jacquardStringEscape SpecialChar
hi def link jacquardBraceEscape SpecialChar
hi def link jacquardInterpolationDelimiter Delimiter
hi def link jacquardRawString String
hi def link jacquardRawComment Comment
hi def link jacquardComment Comment
hi def link jacquardDocComment SpecialComment
hi def link jacquardTodo Todo

let b:current_syntax = "jacquard"
