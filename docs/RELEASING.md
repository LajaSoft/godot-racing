# Releasing Godot FFB

The directory/repository name stays `godot-racing`. `addons/ffb` is the canonical installable runtime addon. The pre-existing `demo/` project resolves that folder through `demo/addons/ffb`, a symlink; its scenes and project settings are not rewritten by packaging.

## Two tag types

- `v0.1.0`: source tag, including C++ source and Docker build scripts. Native libraries are ignored in the source branch.
- `addon-v0.1.0`: a generated distribution tag, containing only the built `addons/ffb/` tree plus provenance. This tag is what gd-plug clones. Both debug and release Linux libraries are committed in this generated snapshot.

A GitHub Release attachment alone is not a gd-plug installation source. No post-install shell hook, compiler, Docker or root access is needed by consumers of the distribution tag. Source builds and the project's CI use Docker Compose.

## Local candidate

```bash
docker compose run --rm release
```

This compiles both targets using Ubuntu 22.04, verifies the ABI baseline and GDExtension entry point, packages into clean temporary consumer projects and runs the actual pinned gd-plug 0.2.6 installer against a temporary local Git repository. Tests do not open `/dev/input` or generate wheel effects. Output:

- `dist/godot-ffb-0.1.0-linux-x86_64.zip`
- `dist/SHA256SUMS`
- `dist/release.json`

The ZIP contains only `addons/ffb/`, with license notices, both binaries and `BUILD.json` hashes/provenance. A local build with uncommitted changes records `source_dirty: true`; this is reviewable but not publishable by the release script. Tests exercise the release binary using a temporary .gdextension debug mapping; an actual Godot release-export run is not part of this first packaging test.

## Publish after repository setup

1. Create/push the GitHub repository, choose its default branch, and enable Actions. There is no configured remote in the starting local checkout.
2. Update `addons/ffb/VERSION`, the changelog and release notes. Commit the desired source state. Existing unrelated changes to the demo must be reviewed separately.
3. Push a matching source tag, e.g. `v0.1.0`.
4. The workflow builds and tests on the minimum Godot 4.4.1 runtime and Godot 4.7.2, creates an immutable `addon-v0.1.0` distribution tag, then creates a **draft** GitHub Release with the ZIP/checksums.
5. Review the draft and publish it. Test a directly connected Moza R3 by hand and record the host kernel/driver, polarity, axis mapping and physical range.

A failed test prevents the publish job. An existing distribution tag is not overwritten. The publish job validates version, source commit, clean provenance and ZIP checksums before uploading. A retry may upload missing assets to an existing draft only if the distribution tag still points to the same source and archive.

No GitHub repository, tag or release is created by the local preparation commands. The included workflow performs publication only after a source release tag is pushed deliberately.

The pinned upstream gd-plug 0.2.6 may exit with POSIX code 255 after successful asynchronous installation (`request_quit` defaults to -1). The test harness recognizes this only for gd-plug after its completion message, rejects logged errors, compares every installed byte with the verified ZIP, and checks actual removal on uninstall. It does not normalize arbitrary subprocess failures.

Headless first-import tests run the editor for 120 frames with a 20 ms frame delay before quitting. Immediate `--import`/`--editor --quit` can hit the upstream Godot documentation-shutdown race [#111048](https://github.com/godotengine/godot/issues/111048), reproduced on 4.7.2. The harness allows documentation generation to finish, and still treats every crash or logged error as failure; there is no retry that hides a failed first import.

The upstream gd-plug 0.2.6 installer does not parse on Godot 4.7.2 (`_process` lacks the now-required return value). Use Godot 4.4.1 for projects retaining gd-plug 0.2.6, or install the ZIP directly on 4.7.2. Compatibility tests explicitly use 4.4.1 for the gd-plug consumer and 4.7.2 for clean ZIP consumers; the vendored installer is unmodified.
