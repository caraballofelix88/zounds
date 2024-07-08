

What does this thing do?
- Plays sounds
  - how?
    - backend
      - hooks up to MacOS audio libs (but could plug in to other stuff as well)
    - frontend
      - modules that take in signals and output signals
      - these processing nodes can be strung together to compose all kinds of crazy noises
      
- Reads wav files
- Processes MIDI (sort of)
  - uses MacOS MIDI backend libs, but parsing module should work agnostic of that



Goals:
- Something that could run on embedded hardware  
  - minimal dynamic memory allocation
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
  - [ ] Support multi-channel output
    - How to mux/demux across different channel counts?
  - [ ] Configurable Context, allow for comptime definition of node store size, etc.
  - [ ] Block-based processing, to allow for more sophisticated effects 

- Synth
  - [ ] Polyphonic synth node 
  - [ ] Scheduling attack and release
  - [ ] glide/portamento

- Ergonomics
  - [ ] Tidy up node registration, how to eliminate those additional steps?
  - [ ] How to refresh node processing list on assigning new signals?

- Documentation
  - [ ] examples for features not yet showcased:
  
  - [ ] annotate examples
  - [ ] document main components
  
