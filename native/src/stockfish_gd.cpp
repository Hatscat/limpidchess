#include "stockfish_gd.h"

#include "sf_runner.h"

#include <godot_cpp/core/class_db.hpp>

using namespace godot;

StockfishGD::~StockfishGD() {
	stop();
}

bool StockfishGD::start() {
	sfrunner::start();
	return sfrunner::running();
}

void StockfishGD::send(const String &cmd) {
	sfrunner::send(std::string(cmd.utf8().get_data()));
}

PackedStringArray StockfishGD::poll_lines() {
	PackedStringArray out;
	for (const std::string &line : sfrunner::poll())
		out.push_back(String::utf8(line.c_str()));
	return out;
}

bool StockfishGD::is_running() const {
	return sfrunner::running();
}

void StockfishGD::stop() {
	sfrunner::stop();
}

void StockfishGD::_bind_methods() {
	ClassDB::bind_method(D_METHOD("start"), &StockfishGD::start);
	ClassDB::bind_method(D_METHOD("send", "cmd"), &StockfishGD::send);
	ClassDB::bind_method(D_METHOD("poll_lines"), &StockfishGD::poll_lines);
	ClassDB::bind_method(D_METHOD("is_running"), &StockfishGD::is_running);
	ClassDB::bind_method(D_METHOD("stop"), &StockfishGD::stop);
}
