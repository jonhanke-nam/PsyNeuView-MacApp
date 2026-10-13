# Installing PsyNeuView

## What you need

- **macOS 14 (Sonoma) or later**, on Apple silicon
- An internet connection for the first launch

Nothing else. No GitHub account, no Homebrew, no Python, no Node. PsyNeuView and
the Python it runs on are included in the app.

## Install

1. **Download** the DMG from the
   [download page](https://jonhanke-nam.github.io/PsyNeuView-releases/).

2. **Open it and drag PsyNeuView to Applications.**

   The app is signed and notarized by Apple, so it opens normally — no
   right-clicking, nothing to click past. Opening the DMG itself may prompt;
   that is expected.

3. **Launch PsyNeuView and click "Get Started".**

   It unpacks PsyNeuView, creates a private Python environment, and installs the
   scientific packages it needs. That last step is a large download — expect
   roughly ten minutes on a good connection, almost all of it waiting on
   PsyNeuLink and PyTorch.

4. **Click "Launch PsyNeuView"** when setup finishes.

That's the whole thing. If you are asked for a password, a GitHub login, or to
install developer tools, something is wrong — see Troubleshooting.

## Where it puts things

The complete list for a standard install — worth knowing if you care what an
installer does to your machine:

| Path | What |
|---|---|
| `/Applications/PsyNeuView.app` | the app, including its own Python |
| `~/Library/Application Support/PsyNeuView/` | PsyNeuView itself, and its Python environment |
| `~/.psyneuview/` | PsyNeuLink sources and saved bundles |
| `~/.psynewview.json` | settings |
| `defaults` domain `PsyNeuView` | window and launch preferences |

It does not install Homebrew, does not touch your PATH, and does not change any
Python, Node, conda or pyenv setup you already have.

## Day to day

- **New window**: ⌘N
- **Settings**: ⌘, (PsyNeuView ▸ Settings…), including which PsyNeuLink to use
- **Logs**: Development ▸ View Logs
- **Quit**: ⌘Q, or close all windows

### Updates

PsyNeuView checks for updates daily and tells you when one is available.
Installing it updates PsyNeuView itself as well as the app — they ship together,
so there is no separate step.

You can check immediately with **PsyNeuView ▸ Check for App Updates…**, and every
released version stays available from the
[download page](https://jonhanke-nam.github.io/PsyNeuView-releases/) if you need
to go back to an earlier one.

### Choosing which PsyNeuLink to use

PsyNeuView ▸ **Settings…** (⌘,) ▸ **PsyNeuLink Source**. PyPI by default; you
can point it at a branch of the Princeton repository, or at a local checkout,
for example the PsyNeuLink you already develop in. Choose the source, then
**Save**. PsyNeuView installs it straight away: the bar at the bottom of the
window shows the install's progress, then **Saved — now using …** naming the
source, and the window closes a moment later. If it fails, the reason stays
on screen. PsyNeuView has to be running for
this, since the install happens in its backend. Your own Python environment
isn't touched.

## Troubleshooting

### Reporting a problem

Run this in Terminal and include the output. It reports versions, what got
installed and where, and changes nothing:

```bash
bash /Applications/PsyNeuView.app/Contents/Resources/diagnose-install.sh
```

It ships inside the app, so it works even when PsyNeuView won't start and needs
no network.

It answers the questions a log usually can't: which build you have and where it
is running from, whether the Python environment survived, and what that
environment thinks its interpreter is.


### It asks me to install developer tools

You are running a build older than 0.5.1. Update, or download the current
version — a bundled install needs no developer tools.

### It asks me to sign in to GitHub

Same cause, unless you have deliberately turned off **Use the bundled
PsyNeuView** in Settings, which restores the older behaviour of cloning the
repository. That path does need GitHub access.

### macOS says the app is "damaged" or won't open

Almost always an incomplete download. Delete the DMG, download it again, and
re-open it.

Older advice here was to run `xattr -cr` to strip the quarantine flag. That
should not be necessary now that the app is notarized, and stripping quarantine
disables a check worth keeping.

### Setup fails while installing Python packages

It needs a working connection for several minutes. If it failed partway, run
setup again — it will not re-download what it already has.

### "No demos found" after launch

Give the server a moment to warm up, then try again.

### An update says it "failed to download" — try again in ~10 minutes

The first check after a release can fail if the app is holding a briefly-stale
cached update feed. It clears itself within about ten minutes, or when you next
relaunch. Choose **Check for App Updates…** again after a short wait.

## Uninstall

1. Drag **PsyNeuView** from Applications to the Trash.
2. Remove its data, if you want it gone completely:

```bash
rm -rf ~/Library/Application\ Support/PsyNeuView
rm -rf ~/.psyneuview
rm -f  ~/.psynewview.json
defaults delete PsyNeuView
```

The Python environment lives inside the Application Support folder, so removing
it reclaims a couple of gigabytes.

## For developers

To work on PsyNeuView itself rather than just use it, turn off **Use the bundled
PsyNeuView** in Settings. Setup then clones the repository into a folder you
choose, which you can edit and switch branches in. That path needs a GitHub
account with access to the repository, and `git`.
