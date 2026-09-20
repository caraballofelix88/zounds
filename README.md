# Zounds

A minimal, zero-dependency signal graph processing toolkit, geared toward audio synthesis.

Zounds is primarily a personal exploration in systems programming, DSP, and how to build
from scratch, and it has been a lovely learning experience so far. As a result, the
feature set is limited and certainly not production ready. This library remains
a work in progress: try not to use it for anything super important just yet!

This library has been initially designed with the expectation it could run reasonably well on
embedded hardware. To keep memory footprint predictable, I've tried to steer away
from dynamic memory allocation, and relied on Zig's comptime to define signal graphs and
wavetables.


# Adding to your stuff

# Getting Started
To use Zounds to make sounds, you'll need to produce a Signal. Signals are values! Generally they can change over time. For example, a sinewave as heard from your
speakers is a stream of signals, oscillating back and forth between the values -1 and 1. For our purposes, Signals are 32 bit values.

Signals can come from a couple of different sources:
You can define a static value as a signal.
You can also provide a pointer as the source of a Signal's data.
Finally, you can define a Signal as coming from the output of somewhere else in a zounds Graph.

Graphs are how Signals get processed. Graphs are composed of Nodes, which
might take in Signals as input to calculate and produce Signals as output. Or not!

Nodes can take in Signals produced by other Nodes. As long as you don't end up with a cycle,
 you can plug nodes into eachother any which way. 


~How to use it?
  - ~What's all this stuff? What do I need to know about?

  I guess making sounds means putting out a stream of signals. Signals are a 





- 

Central concepts:
Signals
- Signals are objects that represent values.
- Sometimes they change over time.
- Their underlying value can be sourced from a couple of places:
  - A `static` value means its baked into the signal
  - A `ptr` means the value is pulled in from a pointer reference
  - A `handle` means that the value is produced by a Node in a Graph.

Nodes
- Modules that interact with Signals.
- An interface for plugging modules into 
- They can take in Signals as input, or produce them as output.
- They are part of a Graph, and need to be `registered`. Then, when the graph is processed,
  the nodes are processed.
- Once nodes are registered to a graph, you can use the node's Ports to plug in in/out signals.
- They have a `process()` function that acts as a "tick". They (should) consume a Graph context,
  and then they process that context, incoming signals, and instance data and may produce an output signal.
- Nodes are interfaces backed by some kind of base processor. Nodes own a pointer to an instance of that processor  

Graphs
- Maintains central context for signal generation
  - Manages processing Nodes
  - Manages signal data
  - Manages node processing order

AudioBackend (Player, maybe recorder eventually)
- Allows for interfacing with the target environment's audio IO interfaces.

MIDIBackend (same thing, for midi)


### What is it?
- At its core, a library for processing signal graphs.
  - Signals are values that are produced from some source. They can change over time.
    - Signals don't have to be produced by a Node! 
  - Nodes process signals.
    - They can optionally receive one or more signals as processing input.
    - They can optionally produce one or more signals as processing output.
    - Nodes can be connected with signals as input and output.
  - Graphs are groupings of Nodes. They store signals processed by Nodes and manage
    node processing.
    - Nodes within a Graph are processed in order of dependency. When a Node takes
      in some input Signal, the source producing that input must be produced first.
- A set of builtin Nodes for processing audio
  - Filters
  - Oscillator
  - etc.
- A Backend serves as an interface for platform-specific mechanisms.
  - There's a couple of interfaces that exist on the backend right now:
    - Midi
    - Audio
  - Right now, there's just the CoreAudio-backed audio + midi backends for macos,
    but maybe I'll get around to others.
- Misceallaneous utilities I need to organize
  - WAV file reader
  

### How to use







### Examples
Take a peek at the `/examples` folder to see what we can do.




# Old Readme, to be removed

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


Extensibility of the Zounds audio graph module is also an ongoing focus.

### Further documentation TK
