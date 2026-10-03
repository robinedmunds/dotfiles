# Image tools spec

Thin wrappers over libvips for converting between image codecs and for resizing to
a fixed shortest side. They exist because the same three shell incantations get
typed over and over, and because the existing `png-to-avif.sh` pair only does one
conversion, serially or 24-way parallel, with no resizing.

## Scope

Two tools:

- `img-convert.sh <input> <format>` — convert one file, e.g. `img-convert.sh example.png webp`
  writes `example.webp` beside it.
- `img-resize-<N>.sh <input>` — resize the shortest side to N and write
  `<stem>-<N>.<ext>` beside the input, keeping the input's codec. Shipped for
  1080, 1440 and 2160.

Both take exactly one file. Batch is left to the shell:

```sh
find . -name '*.png' -exec img-convert.sh {} webp +
```

The full layout, following the shape of the existing `rename-*` family — a shared
library plus thin wrappers:

```
image-lib.sh          backend detection, format table, quality, doctor
img-convert.sh        convert
img-resize.sh         resize, takes the target size as an argument
img-resize-1080.sh    -> img-resize.sh "$1" 1080
img-resize-1440.sh    -> img-resize.sh "$1" 1440
img-resize-2160.sh    -> img-resize.sh "$1" 2160
```

The three fixed-size scripts are ~15 lines each and hold no logic, so the
arithmetic exists once. `img-resize.sh` is also usable directly for a size that is
not one of the three.

## img-convert.sh

Two positional arguments: the input path, then a format name. The output is named
after the input with the format's extension, in the input's directory.

- The format argument is normalised by lowercasing and stripping a leading dot, so
  `webp`, `.webp` and `WebP` are all accepted.
- The format is validated against a fixed table. An unknown one is an error, not a
  guess.
- Canonical output extensions: `jpeg` → `.jpg`, `heic` → `.heic`, others are the
  identity. `img-convert.sh a.png jpeg` therefore produces `a.jpg`.
- The input's extension must be one we can read. `.gif` and `.tif` are refused with
  a message listing what is supported.
- Refuses if the target already exists, unless `-o`.
- Refuses a conversion that would not change the codec (`png` → `png`), rather than
  silently re-encoding.

## Resizing

One file in, `<stem>-<N>.<input's own extension>` out, in the input's directory.
The output extension is copied from the input, so the codec is preserved by
construction and there is no format argument on the resize tools at all.

Steps, in order:

1. Read width, height and EXIF orientation from the input. Whether there is Exif
   to read is decided from the file's own bytes, not from a reader: libvips
   carries the Exif slot on every image it loads, so asking it reports on the
   image rather than on the tag, and an absent tag and an unreadable one come
   back the same way. A file with no Exif carries no rotate-for-display tag and
   is orientation 1 by definition, so a desktop screenshot is resized without any
   reader being consulted. A file that *does* carry Exif goes to
   `vipsheader -f orientation` and then to `exiftool`, and one that neither can
   read is refused rather than guessed at.
2. **Swap width and height for orientations 5–8.** A portrait photo is usually
   stored landscape with a rotate-for-display tag. Sizing against the stored
   dimensions constrains the wrong axis and produces a sideways result. This is the
   single most important detail in the resize path.
3. Compare the corrected shortest side against the target. If it is already smaller,
   report why, write nothing, and exit 0. No upscaling: it costs bytes and adds no
   detail.
4. Compute both target dimensions from the corrected ones with integer ratio maths,
   so the result is deterministic rather than dependent on how libvips rounds.
5. `vips thumbnail <in> <out> <w'> --height <h'> --size force`, then save with the
   saver for the input's own format. `thumbnail` is the right operation because it
   brings JPEG shrink-on-load and applies orientation itself; `--size force` makes
   it hit exactly the dimensions computed in step 4.

   `--no-rotate` is added wherever step 1 settled the orientation *without* a
   reader — no Exif in the file, or `--assume-upright` over a tag nobody could
   read. libvips applying the orientation is only correct while it and step 2
   agree on what the orientation is, so where this tool decided the matter from
   something else, libvips is told not to decide it a second time. An assumption
   and an action then cannot come to different answers, which is what a sideways
   result is.
6. Write to a temporary file in the destination directory, `mv` into place only on
   success, then `touch -r` from the input so the output keeps the source's
   modification time and sorts with the originals.

Metadata (EXIF, ICC) is carried through. There is no `--strip`.

`--assume-upright` resizes a file whose Exif orientation cannot be read, as
though it carried no rotate-for-display tag: the pixels are left as stored and the
tag rides through untouched, so a viewer still turns the result the right way up.
It exists because a tool that can only refuse leaves no way through, and it is a
resize — never destructive — so the cost of getting it wrong is a look at the
result. The strict behaviour is the default.

## Quality

`--quality N`, default 90 for JPEG, WebP and AVIF, and ignored for PNG because PNG
is lossless.

libvips runs quality the opposite way from ImageMagick: lower is better, so `--Q 0`
is best and `--Q 100` is worst. A `-q 90` carried over from ImageMagick habit
produces a badly over-compressed file. Every usage message states this.

**AVIF at 90 will be large.** 90 is a safe near-transparent default for JPEG and
WebP, but AVIF at 40–55 is usually indistinguishable to the eye, so a 90-quality
AVIF can end up bigger than the JPEG it came from. The default stays 90 for
consistency across formats; the documentation suggests `--quality 45` for AVIF.

## Doctor

`--doctor` on either tool reports the libvips version, which formats can be read
and written, the core count, and — importantly — whether this build can actually
*write* AVIF. That last one is probed with a real 16×16 encode, because a libvips
can read AVIF without being able to write it, and that is not visible from the
operation list. AVIF goes through libheif, and whether an AV1 encoder is present
depends on how the package was built.

It also probes the orientation read, **for a JPEG and for a PNG separately**. A
build can answer `vipsheader -f orientation` for one and not the other, and the
difference decides whether a screenshot resizes, because a screenshot is a PNG
and a file with no Exif is settled from its own bytes. A doctor that only asked
about JPEGs could not see a failure specific to the file people most often
resize, which is how the refusal this probe exists to catch went unnoticed.

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Success, or a clean skip (already small enough). |
| `1` | Runtime failure. |
| `2` | Usage error: bad arguments, unsupported format, missing file. |

A resize that skips because the image is already small enough exits 0, not 1. That
is a skip, not a failure.

## Behaviour deliberately not included

**No ImageMagick fallback.** If libvips cannot write AVIF, the tools say so and
point at `--doctor`. Silently switching to a different encoder underneath would
make output quality unpredictable, and one code path is worth more than a rescue
for a build that is not present.

**No parallelism.** libvips is already multithreaded and uses every core by
default, so `xargs -P 24` on top would oversubscribe badly. The existing
`png-to-avif-parallel.sh` runs 24 ImageMagick processes, which is the right shape
for that tool precisely because ImageMagick is single-threaded per process; the same
pattern here would be wrong.

**No directory mode.** One file per invocation. If batch is wanted often enough,
`find -exec` composes without any of the path-mirroring and filtering complexity a
directory mode needs.

## Relationship to png-to-avif.sh

`png-to-avif.sh` and `png-to-avif-parallel.sh` stay as they are. This spec does not
deprecate them. They do one conversion with no resizing, and the serial/parallel
pair is a reasonable choice for ImageMagick. If they are ever replaced, it will be
because `img-convert.sh` and `img-resize-2160.sh` have been used for a while and
found to cover it.

## To verify before trusting this

Neither is checkable in an environment with no image tools installed:

- `vipsheader -f orientation` for the orientation read. If a given build does not
  expose it, the fallback is `exiftool` — but a resize that silently ignores
  rotation is worse than one that refuses, so this needs confirming rather than
  assuming. Run `--doctor` on the target machine: it reports the answer for a JPEG
  and for a PNG separately, which is the question that was previously unaskable.
  What it cannot report is the behaviour this fix no longer depends on — whether
  `vipsheader -f exif-data` distinguishes an absent tag from an unreadable one —
  because the tools no longer ask it. On a build where it does not, the Exif in a
  file is found in the file.
- Whether the target libvips can write AVIF. `--doctor` performs a real encode
  rather than inspecting the operation list.

## Test coverage

`tests/cases/image.sh` covers the resize path with stand-ins for `vips`,
`vipsheader` and `exiftool`, so libvips is not needed to run it. The case that
matters most is the one that pins a screenshot: it fails against the dead Exif
hatch, in which "there is Exif here that nobody could read" is what a file with
no Exif at all looks like from libvips's side.
