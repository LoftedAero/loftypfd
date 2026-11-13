# Releasing

A release is a version tag on this repository, published as a GitHub release. Nothing built
is committed: what goes on a radio is the source files, placed per radio. Lofty GCS installs
a release by reading its `manifest.json` and fetching each file from the tag; the release's
zips are for installing by hand.

## 1. Before tagging

1. Bump `VERSION`. The manifest, the zips' names and the tag all carry it, and bug reports
   refer to it.
2. Run `.venv/Scripts/python tools/test.py`, and `tests/sitl_test.py` if decoding or the
   device client changed.
3. Look at what changed in both simulators (`tools/build.py --ethos --edgetx`), and on a radio
   where it touches timing, touch or sound, which the simulators don't show as a radio does.
4. Run `.venv/Scripts/python tools/build.py --manifest`. `tools/test.py` fails while
   `manifest.json` is out of date, since Lofty GCS checks every file it downloads against the
   hashes there.
5. Commit and push `main`.

## 2. Tagging and publishing

1. Tag the commit `v<version>` and push the tag:

   ```sh
   git tag v0.1.0
   git push origin v0.1.0
   ```

   Lofty GCS fetches each file from the tag, so the tag must hold the manifest that lists
   them.
2. Build the zips:

   ```sh
   .venv/Scripts/python tools/build.py --package   # -> dist/LoftyPFD_<version>_<radio>.zip
   ```

3. Publish the release with the zips attached, titled "Lofty PFD <version>":

   ```sh
   gh release create v0.1.0 dist/LoftyPFD_0.1.0_*.zip --title "Lofty PFD 0.1.0" --notes-file notes.md
   ```

   Don't mark it a pre-release, and don't leave it a draft. Lofty GCS asks GitHub for the
   latest release, which skips both, so it would keep installing the one before.
4. Link [installing.md](installing.md) from the release notes. Until Lofty GCS installs it,
   the guide is how a pilot gets Lofty PFD onto a radio.

Never move or reuse a tag. A radio installed from it would no longer match its manifest, and
the next install would see changed files it can't account for. Fix a bad release with a new
version.

## 3. Checking

Without signing in, so it's what Lofty GCS sees:

```sh
curl -s https://api.github.com/repos/LoftedAero/loftypfd/releases/latest | grep tag_name
curl -sI https://raw.githubusercontent.com/LoftedAero/loftypfd/v0.1.0/manifest.json
```

The first gives the new tag. The second answers 200 with `Access-Control-Allow-Origin: *`,
which the browser version of Lofty GCS needs. A release's attached files don't send that
header, which is why Lofty GCS reads the tag's files rather than the zips.
