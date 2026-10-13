# Writing release notes

Release notes are read by someone deciding whether to install. They are not a
commit log, and they are not for us later — GitHub already keeps the commits.

This document is what we learned shipping 0.5.12, which went out describing one
pull request and calling the other twenty "Bundles PsyNeuView 0.5.6."

## Derive the notes from what shipped, never from memory

The 0.5.12 tag message was drafted days before the tag, when the startup fix
genuinely was the headline. Twenty more pull requests merged after that, and the
message was never revisited. Everything in it was true; it was simply no longer
the release.

So: write notes at tag time, from the range, with the range in front of you.

    scripts/draft-notes.sh v0.5.5 v0.5.6 ../PsyNeuView

That prints every merged pull request in the range with its linked issue title
and labels. Issue titles are the best raw material we have, because they were
written from the user's side before anyone opened an editor:

    [Layout] Persist hand-shaped edges — waypoints are lost on reload

That is already a release note. "feat: add edgeRoutes to layout sidecar" is not.

Read the whole list before writing a word. The shape of a release is not
obvious from the inside — 0.5.6 looked like a layout release while we were in
it, and reads as an editor-workflow release from outside.

## A release is what the user installs, not what one repository changed

The Mac app bundles PsyNeuView. A release where the app changed one line and the
bundle moved twenty pull requests is a bundle release, and the notes belong to
the bundle. Run the derivation against **both** repositories and weight the
notes by where the work actually is.

The bundled version bump is the cheapest thing to mention and the easiest to
hide behind. "Bundles PsyNeuView 0.5.6" is a fact, not a note.

## What goes in, what stays out

In: anything a user could notice. Behaviour that changed, a bug that no longer
happens, something newly possible, something that now refuses where it used to
silently proceed.

Out: refactors, test work, CI, dependency bumps nobody sees, internal renames.
Not because they don't matter — because they answer a question the reader is
not asking.

A test-only pull request can still earn a line if it changes what we can
promise. "Edge rendering is now covered by tests that run on every change" is a
user-facing claim about reliability.

## How to write each entry

Lead with the change from the user's side, then explain why it was wrong
before. The second half is what makes a note trustworthy — it shows we
understood the problem, not just that we touched the code.

    Sync says what it is doing. A small indicator states whether the file on
    disk is being watched, whether a change just arrived, or whether a decision
    is waiting on you. Before, sync was invisible: when it worked you saw the
    canvas change, and when it stopped you saw nothing at all.

Name limits plainly. If a fix only applies to installs that track a git branch,
say so — a note that overstates its reach is how a working feature becomes a
bug report.

Open with a sentence saying what the release is for. Order by what a user would
care about, not by merge order. Put anything that changes existing behaviour
where it cannot be missed.

## Format: plain text, no markdown

The message is rendered for the in-app update dialog by `scripts/tag-notes.sh`,
which understands exactly two things: blank-line-separated paragraphs, and
lines starting with `- `. Everything else is passed through `html.escape`.

That means `**bold**` reaches users as literal asterisks. It is the first thing
that went wrong in the 0.5.12 rewrite.

Avoid a heading line followed by an indented body. The renderer joins them into
one paragraph, which is why 0.5.10 reads, in the dialog users actually see:

    Crash when declining to move the app If you ran PsyNeuView from somewhere...

Use a sentence-lead paragraph instead. It reads correctly as plain text and
renders as one clean paragraph.

## Where the text actually goes

The annotated tag message is the single source for the GitHub release in both
repositories and the Sparkle `<description>`. Write it once, at tag time.

The first line is the headline and becomes the GitHub release title. Keep it
short and specific — it is what someone scanning a list of releases reads:

    PsyNeuView 0.5.12 — works alongside your editor, and starts without the wait

`tag-notes.sh` strips that line from the body, since the title already shows
it. Through 0.5.12 the title was hardcoded to `PsyNeuView <version>`, so every
headline we wrote was stripped and then discarded (#158).

## The public changelog is generated, not written

`PsyNeuView-releases/CHANGELOG.md` mirrors every published release into one file
that can be read end to end, grepped, and opened offline — the things the
paginated releases page cannot do. `scripts/generate-changelog.sh` produces it,
and the release workflow regenerates it after publishing.

Never edit it by hand; the next release overwrites it. Fix the release notes
instead and regenerate. The old hand-maintained `CHANGELOG.md` in this
repository drifted twelve releases before anyone noticed, which is why this one
is derived (#161).

## Notes are fixable until people install, and not after

Sparkle shows the description only when offering an update. Once a version is
installed, that dialog never returns, and a rebuilt same-version release is not
re-offered. So the correction window closes on adoption, not on publication.

Check adoption before choosing how to fix a mistake:

    gh api repos/<owner>/<repo>/releases/tags/<tag> \
      --jq '.assets[] | "\(.name): \(.download_count)"'

- **Nobody has it** — delete the releases and retag. The history then shows one
  correct release, which is accurate, because the wrong one reached no one.
- **People have it** — ship the next version carrying corrected notes. Do not
  delete something people are running, and accept that the in-app dialog for
  the bad version is spent.

Two things that bite during a retag:

- `git push origin :refs/tags/X` deletes only the remote tag. The local tag
  survives and `git tag -a` will refuse; delete it with `git tag -d X` or the
  old message gets pushed straight back.
- `update-appcast.sh` prepends without checking for an existing version, so
  remove the old `<item>` from `PsyNeuView-releases/docs/appcast.xml` first or
  the appcast ends up with two entries for one version.

Deleting a tag also turns its GitHub release into a draft, which unpublishes it
in the private repo but leaves the public copy visible.

## Before you tag

- [ ] Ran the derivation over every repository the release includes
- [ ] Every user-visible pull request in the range is represented or
      deliberately left out
- [ ] Bundled-dependency changes are described, not just named
- [ ] No markdown; no heading-plus-indent paragraphs
- [ ] Limits and caveats stated
- [ ] Tag is annotated (`git cat-file -t <tag>` prints `tag`)

## After it publishes

Verify the artifact, not the green tick. The build going green says the steps
ran, not that the right thing shipped.

- [ ] DMG reports the expected version, and contains the expected bundle
- [ ] `spctl -a -vvv -t install` reports `Notarized Developer ID`
- [ ] The published notes contain the work the release is actually about
- [ ] Exactly one appcast item for the version, and earlier ones untouched
- [ ] The enclosure URL returns 200

Wait for GitHub Pages before judging the appcast. It lagged the release by
several minutes on both 0.5.12 attempts, and both times the first check looked
like a failure that wasn't.
