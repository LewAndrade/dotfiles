if status is-interactive
    # Commands to run in interactive sessions can go here
end

# if i have an issue with ssh
# if status is-interactive
#     ssh-add --apple-use-keychain ~/.ssh/id_ed25519 2>/dev/null
# end

fish_add_path /opt/homebrew/bin
fish_add_path /opt/homebrew/sbin

fish_add_path ~/bin
fish_add_path ~/.local/bin

# Doom Emacs CLI (doom sync/doctor/upgrade)
fish_add_path ~/.config/emacs/bin

set -gx CARGO_HOME $HOME/.cargo/bin
fish_add_path $CARGO_HOME

set -gx PNPM_HOME $HOME/Library/pnpm
fish_add_path $PNPM_HOME/bin

set -gx PYENV_ROOT $HOME/.pyenv
fish_add_path $PYENV_ROOT/bin
pyenv init - | source

set -g fish_greeting
set -gx EDITOR nvim
set -gx VISUAL nvim

set -x MANPAGER "sh -c 'col -bx | bat -l man -p'"
set -x MANROFFOPT -c

abbr -a ls 'eza --icons'
abbr -a ll "eza -l --icons --header --git --no-filesize --no-user --no-time --no-permissions"
abbr -a la "eza -la --icons --header --git"
abbr -a lt "eza -la --icons --header --tree --level=2"

abbr -a cd z

abbr -a cat bat

abbr -a --position anywhere -- --help '--help | bat -plhelp'
abbr -a --position anywhere -- -h '-h | bat -plhelp'

abbr -a lg lazygit

# Quick Look from terminal
abbr -a ql "qlmanage -p"
# Open current directory in Finder
abbr -a finder "open ."
# Flush DNS
abbr -a flushdns "sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder"
# Show/hide hidden files in Finder
abbr -a showhidden "defaults write com.apple.finder AppleShowAllFiles -bool true && killall Finder"
abbr -a hidehidden "defaults write com.apple.finder AppleShowAllFiles -bool false && killall Finder"

if test -d (brew --prefix)"/share/fish/completions"
    set -p fish_complete_path (brew --prefix)/share/fish/completions
end
if test -d (brew --prefix)"/share/fish/vendor_completions.d"
    set -p fish_complete_path (brew --prefix)/share/fish/vendor_completions.d
end

fish_vi_key_bindings

fzf --fish | source
zoxide init fish | source
starship init fish | source
