# Pictures: JPEG decoded in Elixir at a scaled IDCT; drawn by the original's size
- Date: 2026-10-15
- Status: accepted

## Context
The chat's JPEG decoder (1c1ab08) only kept each 8x8 block's DC value: a
1/8-scale decode. A 3000x2000 photo came out 375x250 px, and the chat drew
files at their own pixels, so it showed as a thumbnail beside a full-width
PNG, and the viewer stretched the same 375 px. There is no native image
decode in mob to call instead.

## Decision
`Bezalel.Images.Jpeg` decodes at the smallest of 1/8, 1/4, 1/2 and 1/1
whose result covers the picture's target size in both dimensions
(`Jpeg.scale/4`), separately for the chat box and the viewer box, then
box-downscales. Subsampled chroma is decoded at up to twice the scale per
halving, as libjpeg does (jdmaster.c). A reduced block is libjpeg's reduced-size IDCT (jidctred.c):
the 8-point IDCT averaged over (8/n)x(8/n) squares, folded into an n x 8
basis, so it equals a full decode box-averaged; coefficients whose basis
averages to zero at the scale are skipped. Fixed point, 11-bit basis. Fixture
JPEGs (4:4:4, and odd-sized 4:2:0) and libjpeg-turbo 3.1's decodes of them
at all four scales are committed; the test holds every channel within 3 levels (mean < 0.5).

Pictures are sized by the original's dimensions, which travel with the
cached file (in its name): the chat draws one at its own size at one
pixel per screen pixel, fitted to the chat's width and 420 dp, never
larger; the viewer fits it to the screen. A file decoded smaller than its
box (an unsupported format kept as is) is still drawn at that size.

## Consequences
Decoding stays off the screen process and is cached. Cost of a 3000x2000 4:2:0 baseline JPEG
(1/8, the chat's 1/2, the viewer's 1/1), after a clean app start: iOS
simulator 158 ms / 0.89 s / 2.1 s; Android emulator (Pixel 8 arm64) 142 ms
/ 1.31 s / 3.7 s (a run on a hot-loaded node measured 1.67 s / 7.0 s). The
chat decode on Android sits near the ~1.5 s line and the viewer's is slow
everywhere: the next step is a native decode API in mob, not more Elixir.
Progressive JPEG is still shown as the
original file.
