// Thin C interface around an embedded Stockfish engine.
//
// This file deliberately includes NO godot-cpp headers: Stockfish lives in the
// global namespace and clashes with godot:: types (Color, Move, …), so we keep
// the two worlds apart. stockfish_gd.cpp (godot side) talks to Stockfish only
// through these functions.
//
// Targets Stockfish 11 (classical eval, no NNUE net — small + simple to build).
// If you bump Stockfish, re-check the init sequence in sf_runner.cpp against the
// new src/main.cpp.

#pragma once

#include <string>
#include <vector>

namespace sfrunner {

// Redirect std::cin/std::cout, init Stockfish, and run its UCI loop on a thread.
// Safe to call once; further calls are no-ops until stop().
void start();

// Feed a UCI command line (no trailing newline needed), e.g. "go depth 10".
void send(const std::string &cmd);

// Return and clear any complete output lines Stockfish has emitted so far.
// Non-blocking; call it from a poll loop.
std::vector<std::string> poll();

bool running();

// Send "quit", join the engine thread, restore the streams.
void stop();

}  // namespace sfrunner
