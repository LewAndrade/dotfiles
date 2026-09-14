function ve --description 'Open vanilla Emacs (emacs-plus@31) with isolated config'
    /opt/homebrew/opt/emacs-plus@31/Emacs.app/Contents/MacOS/Emacs --init-directory=$HOME/.config/vanilla-emacs $argv &
    disown
end
