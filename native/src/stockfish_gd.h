// Godot-facing class: a thin RefCounted wrapper that exposes the embedded
// Stockfish engine to GDScript. Drive it the same way you'd drive a UCI process:
//   var sf = StockfishGD.new()
//   sf.start()
//   sf.send("position startpos"); sf.send("go depth 10")
//   for line in sf.poll_lines(): ...   # poll each frame until you see "bestmove"
//   sf.stop()
//
// Only ONE engine exists per process (Stockfish uses global state), so treat
// this as a singleton — make one and keep it.

#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>

namespace godot {

class StockfishGD : public RefCounted {
	GDCLASS(StockfishGD, RefCounted)

public:
	StockfishGD() = default;
	~StockfishGD();

	bool start();
	void send(const String &cmd);
	PackedStringArray poll_lines();
	bool is_running() const;
	void stop();

protected:
	static void _bind_methods();
};

}  // namespace godot
