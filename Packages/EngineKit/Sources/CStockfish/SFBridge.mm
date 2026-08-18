#import "SFBridge.h"

#include <atomic>
#include <condition_variable>
#include <deque>
#include <iostream>
#include <mutex>
#include <streambuf>
#include <string>
#include <thread>

#include "bitboard.h"
#include "misc.h"
#include "position.h"
#include "tune.h"
#include "types.h"
#include "uci.h"

namespace {

/// Blocking FIFO of pending UCI commands.
class CommandQueue {
   public:
    void push(std::string command) {
        {
            std::lock_guard<std::mutex> lock(mutex_);
            queue_.push_back(std::move(command));
        }
        cv_.notify_one();
    }

    /// Blocks until a command is available.
    std::string pop() {
        std::unique_lock<std::mutex> lock(mutex_);
        cv_.wait(lock, [this] { return !queue_.empty(); });
        std::string command = std::move(queue_.front());
        queue_.pop_front();
        return command;
    }

   private:
    std::deque<std::string> queue_;
    std::mutex              mutex_;
    std::condition_variable cv_;
};

/// Feeds queued commands to `std::cin` one line at a time. Stockfish's loop
/// blocks in `getline`, so `underflow` blocking here is exactly the behavior
/// the engine expects from a pipe that has no data yet.
class InputStreamBuffer: public std::streambuf {
   public:
    explicit InputStreamBuffer(CommandQueue& queue) :
        queue_(queue) {}

   protected:
    int_type underflow() override {
        if (gptr() == egptr())
        {
            buffer_ = queue_.pop();
            buffer_ += '\n';
            setg(buffer_.data(), buffer_.data(), buffer_.data() + buffer_.size());
        }
        return traits_type::to_int_type(*gptr());
    }

   private:
    CommandQueue& queue_;
    std::string   buffer_;
};

/// Splits `std::cout` writes into lines and hands each to the Swift callback.
///
/// Stockfish serializes most output behind its own `sync_cout` mutex, but the
/// search threads' info callbacks are not covered in every path, so this keeps
/// its own lock rather than trusting that.
class OutputStreamBuffer: public std::streambuf {
   public:
    void setHandler(void (^handler)(NSString *)) {
        std::lock_guard<std::mutex> lock(mutex_);
        handler_ = handler;
    }

   protected:
    int_type overflow(int_type c) override {
        if (traits_type::eq_int_type(c, traits_type::eof()))
            return traits_type::not_eof(c);

        std::lock_guard<std::mutex> lock(mutex_);
        appendLocked(traits_type::to_char_type(c));
        return c;
    }

    std::streamsize xsputn(const char* s, std::streamsize count) override {
        std::lock_guard<std::mutex> lock(mutex_);
        for (std::streamsize i = 0; i < count; ++i)
            appendLocked(s[i]);
        return count;
    }

    int sync() override { return 0; }

   private:
    void appendLocked(char ch) {
        if (getenv("SFBRIDGE_TRACE") != nullptr && ch == '\n')
            fprintf(stderr, "[SFBridge OUT] %s\n", line_.c_str());
        if (ch == '\n')
        {
            if (handler_ != nil)
            {
                NSString* line = [[NSString alloc] initWithBytes:line_.data()
                                                          length:line_.size()
                                                        encoding:NSUTF8StringEncoding];
                if (line != nil)
                    handler_(line);
            }
            line_.clear();
        }
        else if (ch != '\r')
        {
            line_ += ch;
        }
    }

    std::string line_;
    std::mutex  mutex_;
    void (^handler_)(NSString*) = nil;
};

CommandQueue        gCommandQueue;
InputStreamBuffer   gInputBuffer(gCommandQueue);
OutputStreamBuffer  gOutputBuffer;
std::atomic<bool>   gStarted{false};

}  // namespace

@implementation SFBridge {
    std::thread _engineThread;
}

+ (SFBridge *)shared {
    static SFBridge *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[SFBridge alloc] init];
    });
    return shared;
}

- (BOOL)isRunning {
    return gStarted.load(std::memory_order_acquire);
}

- (void)startWithResponseHandler:(void (^)(NSString *))handler {
    bool expected = false;
    if (!gStarted.compare_exchange_strong(expected, true))
        return;  // already started

    gOutputBuffer.setHandler([handler copy]);

    std::cin.rdbuf(&gInputBuffer);
    std::cout.rdbuf(&gOutputBuffer);
    // Stockfish splits its output across both streams: UCI protocol replies go
    // to cout, but `bench` writes its summary (including "Nodes/second") to
    // cerr. Both must be captured or those commands appear to hang.
    std::cerr.rdbuf(&gOutputBuffer);

    _engineThread = std::thread([] {
        Stockfish::Bitboards::init();
        Stockfish::Position::init();

        // argv[0] is only used to derive a directory for default net lookup; we
        // always set EvalFile/EvalFileSmall to absolute paths, so a placeholder
        // is fine.
        static char  arg0[] = "stockfish";
        static char* argv[] = {arg0, nullptr};

        Stockfish::UCIEngine uci(1, argv);
        Stockfish::Tune::init(uci.engine_options());
        uci.loop();
    });
    _engineThread.detach();
}

- (void)sendCommand:(NSString *)command {
    if (command.length == 0)
        return;
    if (getenv("SFBRIDGE_TRACE") != nullptr)
        fprintf(stderr, "[SFBridge IN ] %s\n", command.UTF8String);
    gCommandQueue.push(std::string(command.UTF8String));
}

@end
