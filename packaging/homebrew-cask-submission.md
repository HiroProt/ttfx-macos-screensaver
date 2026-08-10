# Getting into the official Homebrew cask repo

Right now the install path is a personal tap (`HiroProt/homebrew-tap`), which
works immediately but requires two extra commands. The official
`homebrew/cask` repo needs no tap at all — `brew install --cask
ttfx-screensaver` just works — but it has a notability bar this project has
not cleared yet.

From Homebrew's [package acceptance policy](https://docs.brew.sh/Package-Acceptance-Policy):

> A new package must demonstrate public interest beyond its author. A GitHub
> project normally satisfies this requirement by meeting one of these
> thresholds:
> * at least 30 forks, 30 watchers or 75 stars.
> * at least 90 forks, 90 watchers or 225 stars for a self-submission by the
>   repository owner.

Submitting your own project means the **higher** bar: 90 forks, 90 watchers,
or 225 stars. Submitting before then wastes maintainer time and gets closed,
so don't.

## When the bar is met

The cask file is already written and known-good — it is the one in
[HiroProt/homebrew-tap](https://github.com/HiroProt/homebrew-tap). To submit:

```sh
brew bump-cask-pr --version <new-version> ttfx-screensaver   # for updates
```

or for the first submission, copy `Casks/ttfx-screensaver.rb` into a fork of
`Homebrew/homebrew-cask` under `Casks/t/`, then:

```sh
brew audit --new --cask ttfx-screensaver
brew style --fix ttfx-screensaver
brew install --cask ttfx-screensaver   # verify a clean install
```

and open the PR. Both audit and style must pass; the maintainers run them
too.

## Keeping the tap in sync

Every release needs the tap's `version` and `sha256` bumped. The sha256 of
the release zip is printed by `release.sh`, and is also what
`shasum -a 256 dist/ttfx-screensaver-<version>.zip` reports.
