# MO2 Git Filter

A Git filter for repositories that track a Mod Organizer 2 instance.
It keeps values that MO2 rewrites during normal use out of diffs and commits, while MO2's files keep them.

It removes:

- the `recentDirectories`, `Widgets`, `Servers`, `Geometry`, and `CompletedWindowTutorials` sections of `ModOrganizer.ini`;
- `lastNexusQuery` and `lastNexusUpdate` from the `[General]` section of `mods/*/meta.ini`.

Git commands that write these files, such as `checkout`, `restore`, `stash`, and `reset`, write them without the removed values.

## Setup

Extract the release archive to `tools/mo2-git-filter/` in the repository.
Assign the filters in `.gitattributes`:

```gitattributes
/ModOrganizer.ini filter=mo2-config
/mods/*/meta.ini filter=mo2-meta
```

Register them:

```sh
git config filter.mo2-config.process "tools/mo2-git-filter/mo2-git-filter.exe config"
git config filter.mo2-config.required true
git config filter.mo2-meta.process "tools/mo2-git-filter/mo2-git-filter.exe meta"
git config filter.mo2-meta.required true
```
