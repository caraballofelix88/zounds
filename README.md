# Zounds

A minimal(?) zero-dependency, low-footprint audio synthesis toolkit

## What does this thing do?

It can help you play sounds, and some other stuff! Take a look at the examples for reference.

Zounds is very much a work in progress, and is primarily an educational exercise; don't expect anything crazy rock-solid just yet.

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

Zounds was primarily an exploration in systems programming and DSP, and it has been a lovely learning experience. That said, the feature set is pretty handwave-y and inconsistent as a result.

Zounds was initially designed to be something that could run on embedded hardware. Dynamic memory allocation has been kept to a minimum in generating audio node graphs, which allows for predictability in memory footprint. Expensive calculations (sinewaves and such) are computed at compile-time, and stored in lookup tables.

Extensibility of the Zounds audio graph module is also an ongoing focus.

### Further documentation TK
