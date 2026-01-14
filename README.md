# MacBar - macOS Taskbar + Window Manager

I hate the dock. I think the taskbar concept from windows is objectively better. I'm not alone, there is existing software that ports this functionality to mac for example [here](https://lawand.io/taskbar/), but I wanted some specific features so I started vibe coding my own solution one day, and after a couple months of slow iteration this is what I use daily.

At this point it is still pretty bug but it works well for enough for me. I don't have any other users right, but maybe if I there's interest I will clean up some of the edge cases :)

Note, this is not just a taskbar. It will attempt to full screen new windows when you open them, sort of like a tiling window manager. Also, there are features for tiling windows side by side and switching between windows with a couple of key strokes.

https://github.com/user-attachments/assets/41f79a9c-c27b-4222-ac5e-e8e1456415cc

## Keyboard Reference

When you hit `cmd` (press and release), the icons of all the windows will be replaced by a key hint. You can hit that key to switch to that window. For example you could hit `cmd` then `2` to go to the second window in the task bar.

All keyboard shortcuts start with this `cmd`, after witch you enter `Bar` mode sort of like vi.

- `cmd`, `window key (0-9+)` To switch windows
- `cmd`, `/`, then any number of `window keys`, then `enter` will enter split screen mode for those windows
- `cmd`, `.` remove a window from a split group
- `cmd`, `delete`, `window key` To close a specific window
- `cmd`, `shfit+delete`, To close all windows except the focused window
- `cmd`, `delete`, `arrow left/right` To close all windows to the left/right of the focused window

## Known issues

- Sometimes the app will attempt to resize firefox and chrome extension windows, which is quite annoying
- Every once in a while the app will fail to open the taskbar for some space. A workaround is to go into mission control, move all the windows to a new space, then go to the new space and remove the old space.
- Multi-screen has a number of issues

