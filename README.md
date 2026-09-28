
# DTerm 

<img src="Images/DTerm128.png" style="float:left;margin-right:1em;">

***A command line anywhere and everywhere***

Command line work isn't a separate task that should live on its own—it's an integrated part of your natural workflow. DTerm provides a context-sensitive command line that makes it fast and easy to run commands on the files you're working with and then use the results of those commands.

<br break="both">

# How does it look?

![](Images/DTerm-ScreenShot@2x.png)

# What's new in this fork?

This fork of [muhqu/dterm][upstream] adds shell-like command history to the command field.

- **↑ / ↓** (or **⌃P / ⌃N**) step through the commands you've run. Stepping past the newest one brings back what you had typed.
- **⌃R** opens a fuzzy search over the history, also available as *Search History…* in the action menu. The list filters as you type and highlights the matched letters.
  - ↑ / ↓, or ⌃R again, move through the matches.
  - Return or a double-click puts the chosen command in the command field without running it.
  - Esc closes the search and leaves the command field unchanged.
- The history keeps up to 500 commands and is kept across relaunches. Commands that start with a space aren't recorded, as with bash's `HISTCONTROL=ignorespace` or zsh's `HIST_IGNORE_SPACE`.

It also opens **⌘↩** (*Execute in Terminal*) in [agterm][] instead of iTerm2 when agterm is installed. The command runs in a new agterm session in the working directory. Without agterm, it falls back to Terminal.

# How to get it?

For drag'n'drop installable DMG images, see the [releases][] section of [muhqu's DTerm fork][releases] on GitHub.  

# How to build it yourself?

``` sh
git clone git://github.com/muhqu/dterm
cd ./dterm
./build.sh --with-dmg
```


# License

[The MIT License (MIT)](./LICENSE).

---

Copyright © 2004-2013 [Decimus Software, Inc][decimus].

"DTerm" and "Decimus" are either trademarks or registered trademarks of [Decimus Software, Inc][decimus].

[releases]: https://github.com/muhqu/dterm/releases
[upstream]: https://github.com/muhqu/dterm
[agterm]: https://github.com/umputun/agterm
[decimus]: http://decimus.net
