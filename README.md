# SpaceKeeper

Keeps windows on the monitor and desktop (Space) you put them on when the Mac sleeps and wakes.
If a monitor drops off during sleep, macOS moves its windows onto the other screens. When the
monitor comes back, SpaceKeeper puts those windows back on their desktops and restores their positions.

## Install / update / remove

```sh
./build.sh       # builds, installs ~/Applications/SpaceKeeper.app, starts it now and at every login
./uninstall.sh   # stops it and removes the app, login agent and CLI link
```

On first launch macOS asks for **Accessibility** access (System Settings › Privacy & Security ›
Accessibility). Rebuilding keeps the permission: the app is signed with an identifier-only
requirement.

## How it works

- Every 10 seconds, and right before the displays sleep, it records each window's monitor,
  desktop and frame. One layout is kept per display setup (`~/Library/Application Support/SpaceKeeper/layouts.json`).
- After a wake or a monitor reconnect it waits for the displays to settle and the screen to be
  unlocked. It waits up to 45 s for monitors to reconnect, then puts misplaced windows back.
  Each display ends up showing the desktop it showed before.
- macOS 26 no longer lets other apps move windows between desktops directly. SpaceKeeper switches
  the target desktop into view by focusing a small panel of its own that it carried there, then
  moves the window onto that display with Accessibility. **Desktops visibly flip for a few seconds**
  while a restore runs.

Menu bar icon: status, *Restore Previous Layout*, *Save Layout Now*, *Pause Automatic Restore*, *Open Log*.

## Command line

```sh
spacekeeper dump       # displays, desktops and the windows on each
spacekeeper status     # agent running?, saved layouts, recent log
spacekeeper restore    # put windows back to the previous layout
spacekeeper selftest   # move a throwaway window through every restore path (your windows aren't touched)
```

Log: `~/Library/Logs/SpaceKeeper/SpaceKeeper.log`

## Limits

- Needs “Displays have separate Spaces” on (the macOS default).
- Leaves alone full-screen apps, windows set to appear on all desktops, and minimised windows.
- It can't create desktops. If macOS deleted some, their windows go to that monitor's last desktop.
- Windows are matched by window ID. A window closed and reopened while the monitor was gone is new
  to SpaceKeeper, so it stays where the app opens it.
