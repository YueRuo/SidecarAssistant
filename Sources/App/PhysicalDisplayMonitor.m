//
//  Created by YueRuo on 2026/11/2.
//

#import <Foundation/Foundation.h>

// State, timers and callbacks belong to the main thread. Only the reader runs on a worker.
// A notification requests one debounced read; there is no periodic polling.
static NSNumber *PhysicalDisplayPresence(id snapshot) {
    if (![snapshot isKindOfClass:NSDictionary.class] ||
        ![snapshot[@"physicalExternalDisplays"] isKindOfClass:NSArray.class] ||
        ![snapshot[@"builtInDisplays"] isKindOfClass:NSArray.class]) return nil;
    return [snapshot[@"physicalExternalDisplays"] count] || [snapshot[@"builtInDisplays"] count] ? @YES : @NO;
}

@interface PhysicalDisplayMonitor : NSObject
- (instancetype)initWithReader:(NSDictionary *(^)(void))reader
                removalHandler:(void (^)(void))handler
                   settleDelay:(NSTimeInterval)delay;
- (void)start;
- (void)stop;
- (void)displayConfigurationDidChange;
- (void)setOperationBusy:(BOOL)busy;
@property (nonatomic, readonly) BOOL hasBaseline;
@property (nonatomic, readonly) BOOL physicalDisplayPresent;
@property (nonatomic, readonly) BOOL pendingRemoval;
@property (nonatomic, readonly) BOOL scanRunning;
@end

@interface PhysicalDisplayMonitor ()
@property (nonatomic, copy) NSDictionary *(^reader)(void);
@property (nonatomic, copy) void (^removalHandler)(void);
@property (nonatomic) NSTimeInterval settleDelay;
@property (nonatomic, strong) NSTimer *settleTimer;
@property (nonatomic) NSUInteger generation;
@property (nonatomic) BOOL started;
@property (nonatomic) BOOL running;
@property (nonatomic) BOOL operationBusy;
@property (nonatomic) BOOL scanPending;
@property (nonatomic, readwrite) BOOL hasBaseline;
@property (nonatomic, readwrite) BOOL physicalDisplayPresent;
@property (nonatomic, readwrite) BOOL pendingRemoval;
@property (nonatomic, readwrite) BOOL scanRunning;
@end

@implementation PhysicalDisplayMonitor
- (instancetype)initWithReader:(NSDictionary *(^)(void))reader
                removalHandler:(void (^)(void))handler
                   settleDelay:(NSTimeInterval)delay {
    if (!reader || !handler) return nil;
    if ((self = [super init])) {
        _reader = [reader copy];
        _removalHandler = [handler copy];
        _settleDelay = MAX(0.01, delay);
    }
    return self;
}
- (void)start {
    if (self.started) return;
    self.started = YES;
    self.running = YES;
    [self beginScan];
}
- (void)stop {
    self.running = NO;
    self.generation++;
    [self.settleTimer invalidate];
    self.settleTimer = nil;
    self.scanPending = NO;
    self.pendingRemoval = NO;
}
- (void)scheduleCheck {
    if (!self.running) return;
    [self.settleTimer invalidate];
    __weak PhysicalDisplayMonitor *weakSelf = self;
    self.settleTimer = [NSTimer timerWithTimeInterval:self.settleDelay repeats:NO block:^(NSTimer *timer) {
        (void)timer;
        PhysicalDisplayMonitor *monitor = weakSelf;
        monitor.settleTimer = nil;
        [monitor beginScan];
    }];
    [NSRunLoop.mainRunLoop addTimer:self.settleTimer forMode:NSRunLoopCommonModes];
}
- (void)displayConfigurationDidChange {
    if (!self.running) return;
    self.generation++;
    [self scheduleCheck];
}
- (void)setOperationBusy:(BOOL)busy {
    _operationBusy = busy;
    // Recheck after the current operation before acting on a deferred removal.
    if (!busy && self.pendingRemoval) [self scheduleCheck];
}
- (void)beginScan {
    if (!self.running) return;
    if (self.scanRunning) { self.scanPending = YES; return; }
    self.scanRunning = YES;
    self.scanPending = NO;
    NSUInteger generation = self.generation;
    NSDictionary *(^reader)(void) = self.reader;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @autoreleasepool {
            NSDictionary *snapshot = reader();
            dispatch_async(dispatch_get_main_queue(), ^{
                self.scanRunning = NO;
                if (!self.running) return;
                NSNumber *present = PhysicalDisplayPresence(snapshot);
                if (present) {
                    if (self.hasBaseline && self.physicalDisplayPresent && !present.boolValue)
                        self.pendingRemoval = YES;
                    self.hasBaseline = YES;
                    self.physicalDisplayPresent = present.boolValue;
                    if (present.boolValue) self.pendingRemoval = NO;
                }
                // A stale result may establish history, but never starts a connection.
                BOOL fresh = generation == self.generation && !self.settleTimer && !self.scanPending;
                if (present && fresh && !self.operationBusy && self.pendingRemoval) {
                    self.pendingRemoval = NO;
                    self.removalHandler();
                }
                if (self.scanPending && !self.settleTimer) [self scheduleCheck];
            });
        }
    });
}
@end
