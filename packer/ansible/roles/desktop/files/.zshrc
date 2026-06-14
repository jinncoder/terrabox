HIST_STAMPS="dd.mm.yyyy"

export LANG=en_US.UTF-8

source ~/.paradox.zsh
source ~/.dotrc

# Remember the last 5000 commands.
setopt share_history

# Have zsh tell you when background jobs finish.
setopt notify

# Turn off the infuriating beeping noises.
setopt nobeep

# Protect files from being overwritten.
setopt noclobber

# Disable core dumps.
ulimit -c 0

# sainty...
cd() {
  builtin cd $1;
  ls -trhal | tail -n 30;
}

# Save lots of history
HISTSIZE=10000
SAVEHIST=1000000
HISTFILE=$HOME/.zsh_history

# Make sure everyone knows I use vim
EDITOR=/usr/bin/vim
VISUAL=/usr/bin/vim

# Misc things outside of /usr/local/bin
if [ -d "$HOME/.local/bin" ] ; then
    PATH="$HOME/.local/bin:$PATH"
fi

LS_COLORS="di=1:fi=96:*.m=31:*.py=32:*.txt=36:*.out=35"
