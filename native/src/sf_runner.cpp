// Embedded Stockfish 11 runner. See sf_runner.h.
//
// Stockfish's UCI loop reads commands from std::cin (getline) and writes results
// to std::cout. We don't have a console here, so we swap in two custom
// streambufs: one that BLOCKS until we feed it a command, and one that CAPTURES
// output into a queue we drain from GDScript. Stockfish runs unmodified on its
// own thread.

#include "sf_runner.h"

#include <condition_variable>
#include <deque>
#include <iostream>
#include <mutex>
#include <streambuf>
#include <thread>

// Stockfish 11 headers (global namespace). Same set main.cpp includes.
#include "bitboard.h"
#include "endgame.h"
#include "position.h"
#include "search.h"
#include "syzygy/tbprobe.h"
#include "thread.h"
#include "tt.h"
#include "uci.h"

// PSQT::init() is implemented in psqt.cpp; main.cpp forward-declares it, so do we.
namespace PSQT {
void init();
}

namespace {

// --- std::cin replacement: blocks getline() until feed() supplies a line ---
class FeedBuf : public std::streambuf {
public:
	void feed(const std::string &s) {
		std::lock_guard<std::mutex> lk(_m);
		for (char c : s)
			_q.push_back(c);
		_q.push_back('\n');
		_cv.notify_one();
	}
	void close() {
		std::lock_guard<std::mutex> lk(_m);
		_closed = true;
		_cv.notify_one();
	}

protected:
	int underflow() override {
		std::unique_lock<std::mutex> lk(_m);
		_cv.wait(lk, [&] { return !_q.empty() || _closed; });
		if (_q.empty())
			return std::char_traits<char>::eof();
		_ch = _q.front();
		_q.pop_front();
		setg(&_ch, &_ch, &_ch + 1);
		return std::char_traits<char>::to_int_type(_ch);
	}

private:
	std::deque<char> _q;
	std::mutex _m;
	std::condition_variable _cv;
	char _ch = 0;
	bool _closed = false;
};

// --- std::cout replacement: splits output into lines we can drain ---
class CaptureBuf : public std::streambuf {
public:
	std::vector<std::string> take() {
		std::lock_guard<std::mutex> lk(_m);
		std::vector<std::string> out;
		out.swap(_lines);
		return out;
	}

protected:
	int overflow(int c) override {
		if (c == std::char_traits<char>::eof())
			return c;
		put((char)c);
		return c;
	}
	std::streamsize xsputn(const char *s, std::streamsize n) override {
		std::lock_guard<std::mutex> lk(_m);
		for (std::streamsize i = 0; i < n; ++i)
			put_locked(s[i]);
		return n;
	}

private:
	void put(char ch) {
		std::lock_guard<std::mutex> lk(_m);
		put_locked(ch);
	}
	void put_locked(char ch) {
		if (ch == '\n') {
			_lines.push_back(_cur);
			_cur.clear();
		} else if (ch != '\r') {
			_cur.push_back(ch);
		}
	}
	std::vector<std::string> _lines;
	std::string _cur;
	std::mutex _m;
};

FeedBuf g_in;
CaptureBuf g_out;
std::streambuf *g_old_cin = nullptr;
std::streambuf *g_old_cout = nullptr;
std::thread g_worker;
bool g_running = false;

}  // namespace

namespace sfrunner {

void start() {
	if (g_running)
		return;
	g_old_cin = std::cin.rdbuf(&g_in);
	g_old_cout = std::cout.rdbuf(&g_out);
	g_running = true;

	g_worker = std::thread([] {
		static char arg0[] = "stockfish";
		char *argv[] = {arg0, nullptr};
		// Mirrors Stockfish 11 main.cpp.
		UCI::init(Options);
		PSQT::init();
		Bitboards::init();
		Position::init();
		Bitbases::init();
		Endgames::init();
		Threads.set(size_t(Options["Threads"]));
		Search::clear();
		UCI::loop(1, argv);  // blocks on getline(cin) until "quit"
		Threads.set(0);
	});
}

void send(const std::string &cmd) {
	g_in.feed(cmd);
}

std::vector<std::string> poll() {
	return g_out.take();
}

bool running() {
	return g_running;
}

void stop() {
	if (!g_running)
		return;
	g_in.feed("quit");
	g_in.close();
	if (g_worker.joinable())
		g_worker.join();
	if (g_old_cin)
		std::cin.rdbuf(g_old_cin);
	if (g_old_cout)
		std::cout.rdbuf(g_old_cout);
	g_running = false;
}

}  // namespace sfrunner
