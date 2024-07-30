# Zounds

A minimal(?) audio synthesis toolkit

## What does this thing do?

It can help you play sounds, and some other stuff! It might not be very good at it, though.

- Real-time audio graph and signal synthesis (sort of)
- MIDI Message parsing (sort of)
- Integrations with audio backends (MacOS only for now) (sort of)
- Reading WAV files

### TODO

- Writing WAV files
- More audio backends
- Multichannel output for signal graph
- Additional affordances for synthesizers
- Additional DSP nodes
- Device output selection
- waaaaay more tests
- ...And More!

## Goals

Zounds was primarily an exploration in systems programming and DSP, and it has been a lovely learning experience. That said, the feature set is pretty handwavey and inconsistent as a result.

Zounds was initially designed to be something that could run on embedded hardware. Dynamic memory allocation has been kept to a minimum in generating audio node graphs, which allows for predictability in memory footprint. Expensive calculations (sinewaves and such) are computed at compile-time, and stored in lookup tables.

Extensibility of the Zounds audio graph module is also an ongoing focus.

Zounds was also pretty much written exclusively for my use and education; don't expect any rock solid performance out of this, and for all I know this could brick your PC.

Further documentation TK.
