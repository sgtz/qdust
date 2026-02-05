# Editor Setup

Configure `.t` files as Q syntax for highlighting.

## VS Code

Add to `settings.json`:

```json
"files.associations": {"*.t": "q"}
```

## IntelliJ / Rider

1. Settings → Editor → File Types
2. Find Q (or kdb+/q) in the list
3. Click **+** in File name patterns
4. Add `*.t`
5. Click OK

## Vim

Add to `.vimrc`:

```vim
au BufRead,BufNewFile *.t set filetype=q
```

## Emacs

Add to `.emacs` or `init.el`:

```elisp
(add-to-list 'auto-mode-alist '("\\.t\\'" . q-mode))
```
