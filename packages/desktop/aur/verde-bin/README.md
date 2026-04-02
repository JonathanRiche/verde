# verde-bin AUR package

This directory contains an AUR-ready `verde-bin` package for the current Linux
release artifact.

## Update flow

1. Update `pkgver` in `PKGBUILD`.
2. Update the release tarball checksum in `sha256sums`.
3. Regenerate `.SRCINFO`:

```bash
makepkg --printsrcinfo > .SRCINFO
```

4. Push `PKGBUILD` and `.SRCINFO` to the AUR `verde-bin` repository.

## Notes

- The package installs the bundled runtime under `/usr/lib/verde`.
- `/usr/bin/verde` is a thin wrapper that launches `/usr/lib/verde/verde`.
- Upstream ships a top-level MIT license, which the package installs to
  `/usr/share/licenses/verde-bin/LICENSE`.
