#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Thin ObjC++ bridge around Stockfish's UCI loop.
///
/// Stockfish drives itself from `std::cin`/`std::cout`. Rather than spawn a
/// subprocess (impossible on iOS) this swaps both streams for in-memory buffers
/// and runs `UCIEngine::loop()` on a dedicated thread. Commands go in through
/// `sendCommand:`, output lines come back one at a time on the response handler.
///
/// Stockfish keeps process-global state (bitboard tables, the transposition
/// table, thread pool), so exactly one bridge exists per process.
@interface SFBridge : NSObject

@property (class, readonly) SFBridge *shared;

/// True once `start` has spun up the engine thread.
@property (atomic, readonly, getter=isRunning) BOOL running;

/// Starts the engine thread. Each output line is delivered on an arbitrary
/// background thread — never the main thread. Calling twice is a no-op.
- (void)startWithResponseHandler:(void (^)(NSString *line))handler
    NS_SWIFT_NAME(start(responseHandler:));

/// Queues a UCI command. A trailing newline is added automatically.
/// Safe to call from any thread; ordering is preserved.
- (void)sendCommand:(NSString *)command NS_SWIFT_NAME(send(_:));

@end

NS_ASSUME_NONNULL_END
