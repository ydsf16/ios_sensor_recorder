# iPhone 12 dual-camera 60 fps buffer investigation

## Scope

- Device: iPhone 12 (`00008101-000A31621EE1001E`)
- Standard, hardware-synchronized Wide + Ultra Wide, 640×480 at 60 fps
- All available sensors enabled, including separate AAC audio and raw IMU
- Optimized Release build with the native matrix harness enabled for repeatable runs
- This report covers the reproduced profile only; it is not a full configuration sweep.

## Diagnosis

The original intermittent failure was an AVFoundation synchronized sample with dropped reason 2 (`OutOfBuffers`) immediately after the first recorded group. In a failed run, the two MP4 mux append calls took 0.26 and 0.41 ms and their maximum queued compressed packet count was one. Pixel detachment took 1.7 and 1.9 ms. The first VideoToolbox submissions took 21 and 26 ms; a separate failed run measured 31 and 35 ms. The audio capture callback itself averaged 0.024 ms. These measurements do not support disk throughput as the immediate cause. They point to startup resource scheduling and encoder contention. The 105 ms synchronized callback maximum in the failed run includes failure reporting and metadata generation after AVFoundation had already dropped the sample.

Disabling audio writing while leaving microphone capture active allowed a 20-second run with both video streams intact. Lowering only the independent audio writer's queue priority to background, while preserving AAC output, produced eight consecutive clean runs: seven about 20 seconds and one about 60 seconds. This is evidence that audio writer scheduling contributed to the failure, although it does not establish the internal AVFoundation cause.

## Changes retained

- The audio writer uses a bounded background-priority queue; the other sensor writers remain independent.
- Recording detaches each camera pixel buffer into its reusable encoder pool once. Preview reuses that detached buffer during recording instead of making a second pixel copy.
- The recording path passes pixel buffers and timing directly to VideoToolbox, avoiding a new sample buffer, format description and attachment dictionaries per encoded frame.
- Pool allocation attributes are cached, and matching pixel strides are copied per plane rather than per row.
- Lightweight per-stage timing summaries are written to the capture CSV files on finalization.

Encoder warm-up and forced H.264 were tested and rejected: each still produced a startup drop. Neither is part of the retained recording path.

## Verification

All eight final-priority runs passed manifest validation and file-level validation. The 60-second run recorded 3,630 frames from each camera at approximately 59.9665 fps, with maximum frame intervals of 16.680 and 16.688 ms. The synchronization file contains 3,630 complete groups and a maximum constituent timestamp skew of 0.0783 ms. Both MP4 files decoded, the AAC track decoded for 60.70 seconds, and the raw IMU file contained 6,072 samples. Video dimensions, frame rates, timestamps and frame counts matched the selected settings. No gap or silent camera downgrade was found in these runs.

The iPhone 12 has no LiDAR sensor, so this result does not validate LiDAR Depth. Other camera combinations and resolutions were deliberately not swept during this investigation.
