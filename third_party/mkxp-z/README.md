# Vendored mkxp-z

Open-source reimplementation of the RGSS runtime used by RPG Maker XP / VX /
VX Ace. Used by f69 to convert Windows-only RPG Maker VX / VX Ace games into
something playable on Linux without WINE.

Upstream: https://github.com/mkxp-z/mkxp-z (LGPL-2.1+)

## Provenance — `linux-x86_64/`

Sourced from the upstream Linux x86_64 CI artifact (no published release tag
existed at vendor time; the project is mid-transition to a meson build
system on PR #342).

```
Workflow run:  https://github.com/mkxp-z/mkxp-z/actions/runs/26370748029
Branch:        meson  (PR #342, "Build system overhaul")
Commit:        01520a4dc2960fc9b472b46cd8e80d515c97f12c
Artifact:      mkxp-z.linux.ubuntu.22.04.x86_64.PR342-4d938d1
Built:         2026-05-24
Artifact SHA256 (zip): afa4e53efceb1c9f7171639022c53ce8db719a835d9107d1a50b00573d7ddd1a
```

Fetched via `https://nightly.link/mkxp-z/mkxp-z/actions/artifacts/7188109342.zip`
on 2026-05-27, unpacked, then committed in-tree.

## Layout

| Entry                                | Purpose                                  |
| ------------------------------------ | ---------------------------------------- |
| `mkxp-z.x86_64`                      | The runtime ELF (38.7 MB; statically links SDL2, OpenAL, freetype, MRI Ruby, vorbis, theora) |
| `mkxp.json`                          | Default config template                  |
| `scripts/preload/*.rb`               | Ruby preload wrappers (win32/kernel/etc) |
| `stdlib/`                            | Bundled MRI Ruby standard library        |
| `LICENSE.mkxp-z-with-https.txt`      | Upstream LGPL + HTTPS sub-licenses       |

## Refreshing

When upstream tags a stable release or a newer CI artifact is worth picking
up, replace the contents of `linux-x86_64/` from the new build, update this
README's provenance block, and commit. f69's build step just copies whatever
is here into `<install>/bin/data/mkxp-z/`.
