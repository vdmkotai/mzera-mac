# Synthetic media fixtures

These files contain generated patterns only; no user media is included.

- `sequential.webp`: 96×64, 300 frames, 40 ms per frame; moving green rectangle on a dark background. Used to check sequential composition and reset. The first frame covers pixel (5,20); the last does not.
- `software.webm`: FFmpeg `testsrc2` at 160×90 and 15 fps, 1 second, VP8 (`libvpx`). Exercises the software decoder, resizing and CVPixelBufferPool.
- `ten-bit.mp4`: FFmpeg `testsrc2` at 320×180 and 30 fps, 2 seconds, HEVC (`libx265`) with `yuv420p10le` and `hvc1` tag. Exercises 10-bit decoding and the renderer's accepted pixel formats.

The tests assert frame count, dimensions, pixels or format acceptance, not codec timing thresholds. Fixtures are small enough to keep in Git. The larger animation used by the performance probe is intentionally not included here.
