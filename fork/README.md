# luskaner/wails

A fork of [wailsapp/wails](https://github.com/wailsapp/wails) that makes **Wails v3 run on
32-bit Windows** (GOARCH=386).

Everything else is upstream: this fork only carries a patch and republishes itself on top of
every new upstream v3 release.

## Why

Wails v3 does not start on 32-bit Windows. Two separate defects kill every application, and
both of them are in the runtime, not in the application:

1. **A panic before `main` runs.** The `IDropTarget` COM callbacks are registered from an
   unconditional `init()` in `pkg/w32`, and they take the drag and drop `POINT` by value.
   `syscall.NewCallback` rejects any callback argument wider than a `uintptr`, and a `POINT` is
   8 bytes: one word on amd64 and arm64, two on 386.

   ```
   panic: compileCallback: argument size is larger than uintptr
   ```

2. **A panic while styling the window.** `GetWindowLongPtrW` and `SetWindowLongPtrW` are
   compiler macros on 32-bit Windows, not exported symbols of `user32.dll`, so the first window
   style change blows up with `Failed to find GetWindowLongPtrW procedure in user32.dll`.

The patch in [`patches/`](patches) fixes both. It is the patch from
[wailsapp/wails#5836](https://github.com/wailsapp/wails/pull/5836), which is still open upstream.

## Using it

The fork keeps the module path of upstream, so it is used with a `replace`:

```go
require github.com/wailsapp/wails/v3 v3.0.0-beta.30

replace github.com/wailsapp/wails/v3 => github.com/luskaner/wails/v3 v3.0.0-beta.30-patched.2
```

The application keeps importing `github.com/wailsapp/wails/v3/...` unchanged: Go accepts a
replacement that declares the path it replaces, and the module proxy serves the fork as it is.

Renaming the module to `github.com/luskaner/wails/v3` also works, but then the application has
to import the fork under that path, and Go refuses a module that ends up being used under two
paths at once, so the imports of the whole tree have to be rewritten. Keeping the upstream path
is the smaller change, and it keeps the difference between this fork and upstream down to the
patch itself.

## Releases

Every upstream v3 release is republished here as `<upstream tag>-patched`, for example
`v3.0.0-beta.34-patched`. The suffix sorts after the upstream tag it is based on, so
`go get github.com/luskaner/wails/v3@latest` picks the patched build and not the unpatched
upstream one.

A release is never republished. The go module proxy and the checksum database keep the first
content they ever saw for a version, so a tag that has been published once is frozen: if the
patch has to change, the release gets a new name (`--tag-name`).

The [`fork-release`](../../.github/workflows/fork-release.yml) workflow does it: it runs every
day, and it can also be started by hand from the Actions tab. It checks out the upstream tag,
applies the patch, builds the result for windows/386, windows/amd64 and windows/arm64, and
then tags, pushes and publishes the release.

## Keeping the patch up to date

The patch touches five files:

| File | Change |
| --- | --- |
| `v3/pkg/w32/idroptarget.go` | the three `POINT` thunks move out |
| `v3/pkg/w32/idroptarget_thunks.go` | the thunks for everything that is not 386 |
| `v3/pkg/w32/idroptarget_thunks_386.go` | the thunks for 386, with the point as two words |
| `v3/pkg/w32/user32.go` | the `Get/SetWindowLongPtr` wrappers pick the non `Ptr` procedure on 32 bits |
| `v3/internal/webview2/internal/w32/w32.go` | two unused `*Ptr` declarations are removed |

When upstream changes any of them and the patch no longer applies, the workflow fails with
`the patch does not apply to <tag>` and the patch has to be updated by hand. Rebase it on the
new upstream release:

```bash
git checkout upstream/v3.0.0-beta.35
git apply --3way ../fork/patches/0001-v3-windows-32bit-runtime-fixes.patch
```

If the context moved but the change is still valid, `git apply --3way` merges it. If the
upstream code changed the same lines, the conflict has to be resolved by hand and the patch
regenerated:

```bash
git diff -- v3/ > fork/patches/0001-v3-windows-32bit-runtime-fixes.patch
```

## License

Wails is MIT licensed, and so is this fork.
