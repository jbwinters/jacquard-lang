# Editor support

Syntax highlighting for Jacquard surface source (`.jac`). Both grammars are
lexical: they are written from `src/surface_lex.ml` and the one-page grammar in
`docs/surface-syntax.md`, and do not parse. `sh editors/check.sh`, which runs
in the development gate, checks that they reserve exactly the lexer's keywords;
other lexical rules are matched by hand, so the known gaps below apply.

| Directory | Format | Used by |
|---|---|---|
| `textmate/` | TextMate grammar, scope `source.jacquard` | Shiki (jacquardlang.org highlights its samples with it) and TextMate-grammar editors; VS Code needs a small extension manifest, which is not provided here |
| `vim/` | Vim runtime files: `ftdetect`, `ftplugin`, `syntax` | Vim and Neovim |

## Vim and Neovim

Add `editors/vim` to the runtime path. With a checkout at `~/src/jacquard-lang`:

```vim
" ~/.vimrc or init.vim
set runtimepath+=~/src/jacquard-lang/editors/vim
filetype plugin on
syntax on
```

```lua
-- Neovim init.lua
vim.opt.runtimepath:append(vim.fn.expand("~/src/jacquard-lang/editors/vim"))

-- or with lazy.nvim
{ dir = "~/src/jacquard-lang/editors/vim", lazy = false }
```

`*.jac` files get the `jacquard` filetype, `--` comments for `gc`/commentary,
and kebab-case names ending in `?` or `!` count as one word for `*` and `w`.

## Shiki

```js
import { createHighlighter } from "shiki";
import jacquard from "./jacquard.tmLanguage.json" with { type: "json" };

const highlighter = await createHighlighter({
  langs: [{ ...jacquard, name: "jacquard" }],
  themes: ["github-dark"],
});
highlighter.codeToHtml(source, { lang: "jacquard", theme: "github-dark" });
```

## What is highlighted

Keywords (`Surface_lex.keywords`, plus `opaque` before `type`), `--` and
`--|` comments, strings with their escapes, `$"..."` text with `{expr}`
interpolation and `{{`, numbers including `±inf.0` and `±nan.0`, Pascal-case
type, effect and constructor names, top-level definition heads, calls,
`` `kind:name` `` escapes, `#hash:kind` and `#group[n]` references, `_`, and
`jqd { ... }` raw blocks (parentheses, strings and `;` comments).

Known gaps:

- Lowercase names in a type, such as type variables, are not distinguished
  from term names, because that needs a parser.
- Contextual splits the lexer makes, such as the `.` that ends `forall a b.`,
  are approximated.
- The bootstrap `.jqd` carrier has no grammar here.

## Changing the syntax

When `Surface_lex.keywords` or the lexical rules change, update both grammars
in the same change and run `sh editors/check.sh`.
