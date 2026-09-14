# dotfiles

My configuration files, one GNU Stow package per tool. macOS only.

## Packages

| Package    | Links into                          | Notes                                          |
|------------|-------------------------------------|------------------------------------------------|
| `doom`     | `~/.config/doom`                    | Literate Doom Emacs config. Edit `config.org`. |
| `nvim`     | `~/.config/nvim`                    | LazyVim based.                                 |
| `ghostty`  | `~/.config/ghostty`                 | Terminal, with two bamboo themes.              |
| `fish`     | `~/.config/fish`                    | Shell. Plugins come from fisher, not from here.|
| `starship` | `~/.config/starship.toml`           | Prompt.                                        |
| `git`      | `~/.gitconfig`, `~/.config/git`     | Identity stays out of this repo. See below.    |

## Install

1. Install stow: `brew install stow`.
2. Clone this repo to `~/dotfiles`.
3. Link every package:

```sh
cd ~/dotfiles
stow --no-folding -t ~ doom nvim ghostty fish starship git
```

Link one package on its own with `stow --no-folding -t ~ doom`.

Remove a package with `stow -D -t ~ doom`.

`--no-folding` links each file separately, instead of replacing a whole
directory with one symlink. Local files, for example Emacs transcripts, then stay
out of this repo.

If stow reports a conflict, a real file already sits at that path. Move it away,
then stow again.

## Git identity

`.gitconfig` holds no name, no email and no signing key. It includes
`~/.gitconfig.local`, which is not tracked here. Create that file on a new
machine:

```ini
[user]
	name = Your Name
	email = you@example.com
	signingkey = YOURKEYID
```

Git ignores the include when the file is missing, so commits fail with an unset
identity until you write it.

## Doom Emacs

`config.org` is the source of truth. Doom tangles it into `config.el`, which is
generated and therefore not tracked. Do not edit `config.el`.

A tangle runs when you save any org file in `~/.config/doom`, and again before
every `doom sync`.

Other requirements for this config:

- Maple Mono NF and Noto Emoji fonts.
- `terminal-notifier` 3.x, for agent-shell notifications.
- fish at `/opt/homebrew/bin/fish`, which supplies the PATH.
- A JDK through sdkman, for the Java language server.

## Fish

`fish_plugins` lists the plugins. Install them with fisher:

```sh
fisher update
```

Plugin files land in `conf.d`, `completions` and `functions`. They are not
tracked here, and neither is `fish_variables`.
