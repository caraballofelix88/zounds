What does this thing do?

- Plays sounds
  - how?
    - backend
      - hooks up to MacOS audio libs (but could plug in to other stuff as well, eventually)
      - abstractions:
        - Context
        - MIDI
        - Player
    - frontend
      - modules that take signals and output signals
      - these processing nodes can be strung together to compose all kinds of crazy noises
      - signals serve as providers of input values, as well as edges to graph nodes
        - plugging into the node graph context reserves space for node output signals
- Reads wav files
- Processes MIDI (sort of)
  - uses MacOS MIDI backend libs, but parsing module should work agnostic of that

Goals:

- Initial goal was something that could run on embedded hardware

  - minimal dynamic memory allocation
  - comptime structs allow for easy scratch space adjustment
  - frontload processing to comptime where possible
    - generating waveforms
    - building node vtables

- Something easily extensible
  - adding new nodes to processing should be a snap, just follow the rules and add to signal context
  - node processing is standalone, which should make testing easy

TODO:

- [ ] Cleaning up old stuff:

  - [ ] remove `sources` directory, and rework existing stuff into something that works with the new context shape

- [ ] Benchmarking/profiling

- Backends:
  - [ ] a "raw" output backend. Might not be necessary, since we've already got the "dummy"
- Files:
  - [ ] Rendering wav files to output?
  - [ ] Reading/writing other filetypes?
- Signals:

  - [ ] Documentation + tests for each node type
  - [ ] Shore up signal context, handle edge cases (like reaching a node cap)
  - [ ] Handle node deregistration
  - [ ] Signals currently stuck as f32s, but how to extend to other types?
    - Currently stuck with f32s for a couple of reasons
      - Heterogeneous types in Port abstraction kind of weird
      - Structure to store heterogeneous types not obvious
        - This article talks through dense allocation of tagged union values by way of an "Array of Variant Arrays" -- https://alic.dev/blog/dense-enums
          - break up union tags by their value type size/alignment
          - set up separate arrays for each bucket size (eg. f32, u32 both fit in the 4-wide array, so they can cohabitate)
          - Would need to add type tags to Signals (a big ergo win)
  - [ ] how to free up scratch space if/when nodes are removed from the graph?
  - [ ] Remove dynamic port idea, needs more time in the oven and is getting in the way of other stuff (?)
  - [ ] Support multi-channel output
    - How to mux/demux across different channel counts?
  - [ ] Configurable Context, allow for comptime definition of node store size, etc.
  - [ ] Block-based processing, to allow for more sophisticated effects
  - [ ] Signal graph processing should pipe into buffer for consumption by backend, instead of being fed straight in
  - [ ] Producing signals should be on a separate thread from consumption

- Synth

  - [x] Polyphonic synth node
  - [ ] Scheduling attack and release
  - [ ] glide/portamento

- Ergonomics

  - [ ] Tidy up node registration, how to eliminate those additional steps?
  - [ ] Searching for nodes in graph by id, or other filters/rules?
  - [ ] How to refresh node processing list on assigning new signals?
  - Idea for ^: signal context keeps registry of available abstractions
    - ctx.connect(from: OutSignal, to: InSignal)
    - ctx.disconnect() // sets to static 0 signal
    - ctx.registerNode() // already have this!
    - ctx.deregisterNode()
      - looks at all the node's outlets and zeroes out any nodes using them?
        - Actually, if we use generational updates to track outdated nodes, we can skip this:
          - on signal.get(), check generation id on handle signal. If older than current handle, dump it.

- Inspo/Reading

  - PureData
  - http://www.rossbencina.com/code/real-time-audio-programming-101-time-waits-for-nothing
  -

- Documentation

  - [ ] examples for features not yet showcased:
  - [ ] annotate examples
  - [ ] document main components
