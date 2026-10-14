#import "MODWeatherService.h"
#import <CFNetwork/CFNetwork.h>

static NSString *const MODWeatherCachePath = @"/var/mobile/Library/ModernOS/weather.plist";
static const NSTimeInterval MODWeatherMaxAge = 30 * 60;
static const NSTimeInterval MODWeatherTimeout = 10;
static const CFIndex MODWeatherMaxBytes = 16 * 1024;

@implementation MODWeather

- (NSString *)summary {
    NSInteger c = self.code;
    if (c == 0) return @"Clear";
    if (c <= 3) return @"Partly Cloudy";
    if (c == 45 || c == 48) return @"Fog";
    if (c >= 51 && c <= 57) return @"Drizzle";
    if (c >= 61 && c <= 67) return @"Rain";
    if (c >= 71 && c <= 77) return @"Snow";
    if (c >= 80 && c <= 82) return @"Showers";
    if (c >= 85 && c <= 86) return @"Snow Showers";
    if (c >= 95) return @"Thunderstorm";
    return @"Weather";
}

@end

@implementation MODWeatherService {
    MODWeather *_cached;
    NSString *_cachedKey;
    BOOL _inFlight;
}

+ (instancetype)shared {
    static MODWeatherService *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[self alloc] init]; });
    return shared;
}

- (void)purge {
    _cached = nil;
}

- (MODWeather *)cachedWeather {
    if (_cached) return _cached;
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:MODWeatherCachePath];
    if (![dict isKindOfClass:[NSDictionary class]]) return nil;
    MODWeather *weather = [MODWeather new];
    weather.temperature = [dict[@"temperature"] doubleValue];
    weather.code = [dict[@"code"] integerValue];
    weather.fetchedAt = [dict[@"fetchedAt"] isKindOfClass:[NSDate class]] ? dict[@"fetchedAt"] : nil;
    _cachedKey = [dict[@"key"] isKindOfClass:[NSString class]] ? dict[@"key"] : nil;
    _cached = weather.fetchedAt ? weather : nil;
    return _cached;
}

- (void)refreshIfStaleForLatitude:(double)latitude longitude:(double)longitude
                       fahrenheit:(BOOL)fahrenheit
                       completion:(void (^)(MODWeather *, NSError *))completion {
    NSString *key = [NSString stringWithFormat:@"%.2f,%.2f,%d", latitude, longitude, fahrenheit];
    MODWeather *cached = [self cachedWeather];
    if (cached && [_cachedKey isEqualToString:key] && -[cached.fetchedAt timeIntervalSinceNow] < MODWeatherMaxAge) {
        completion(cached, nil);
        return;
    }
    if (_inFlight) return;
    _inFlight = YES;
    // Coordinates rounded to 2 decimals (~1 km).
    NSString *url = [NSString stringWithFormat:@"http://api.open-meteo.com/v1/forecast?latitude=%.2f&longitude=%.2f&current_weather=true%@",
                     latitude, longitude, fahrenheit ? @"&temperature_unit=fahrenheit" : @""];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        NSError *error = nil;
        NSData *body = [MODWeatherService fetch:[NSURL URLWithString:url] error:&error];
        MODWeather *weather = nil;
        if (body) {
            id json = [NSJSONSerialization JSONObjectWithData:body options:0 error:&error];
            NSDictionary *current = [json isKindOfClass:[NSDictionary class]] ? json[@"current_weather"] : nil;
            if ([current isKindOfClass:[NSDictionary class]] && [current[@"temperature"] respondsToSelector:@selector(doubleValue)]) {
                weather = [MODWeather new];
                weather.temperature = [current[@"temperature"] doubleValue];
                weather.code = [current[@"weathercode"] respondsToSelector:@selector(integerValue)] ? [current[@"weathercode"] integerValue] : -1;
                weather.fetchedAt = [NSDate date];
                [@{ @"temperature" : @(weather.temperature), @"code" : @(weather.code), @"fetchedAt" : weather.fetchedAt, @"key" : key }
                    writeToFile:MODWeatherCachePath atomically:YES];
            } else if (!error) {
                error = [NSError errorWithDomain:@"ModernOS" code:2 userInfo:@{ NSLocalizedDescriptionKey : @"Unexpected weather response" }];
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_inFlight = NO;
            if (weather) {
                self->_cached = weather;
                self->_cachedKey = key;
            }
            completion(weather ?: self->_cached, weather ? nil : error);
        });
    });
}

// CFHTTPStream is deprecated in iOS 9 in favour of NSURLSession, which cannot be
// used here (see header). Deliberate, scoped suppression.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
// Synchronous HTTP GET on the calling (background) thread with a hard time and
// size budget: spins the run loop in 50 ms slices for at most MODWeatherTimeout.
+ (NSData *)fetch:(NSURL *)url error:(NSError **)outError {
    CFHTTPMessageRef request = CFHTTPMessageCreateRequest(kCFAllocatorDefault, CFSTR("GET"), (__bridge CFURLRef)url, kCFHTTPVersion1_1);
    if (!request) return nil;
    CFHTTPMessageSetHeaderFieldValue(request, CFSTR("Accept"), CFSTR("application/json"));
    CFHTTPMessageSetHeaderFieldValue(request, CFSTR("User-Agent"), CFSTR("ModernOS/1.0 (iOS 9)"));
    CFReadStreamRef stream = CFReadStreamCreateForHTTPRequest(kCFAllocatorDefault, request);
    CFRelease(request);
    if (!stream) return nil;
    CFReadStreamSetProperty(stream, kCFStreamPropertyHTTPShouldAutoredirect, kCFBooleanTrue);
    // Scheduled on this worker thread's run loop, which is spun in short slices below.
    CFRunLoopRef runLoop = CFRunLoopGetCurrent();
    CFReadStreamScheduleWithRunLoop(stream, runLoop, kCFRunLoopDefaultMode);

    NSMutableData *data = [NSMutableData data];
    NSError *error = nil;
    if (!CFReadStreamOpen(stream)) {
        error = [NSError errorWithDomain:@"ModernOS" code:3 userInfo:@{ NSLocalizedDescriptionKey : @"Could not open connection" }];
    } else {
        CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + MODWeatherTimeout;
        UInt8 buffer[2048];
        for (;;) {
            CFStreamStatus status = CFReadStreamGetStatus(stream);
            if (status == kCFStreamStatusAtEnd) break;
            if (status == kCFStreamStatusError) {
                error = CFBridgingRelease(CFReadStreamCopyError(stream));
                break;
            }
            if (CFAbsoluteTimeGetCurrent() > deadline) {
                error = [NSError errorWithDomain:@"ModernOS" code:4 userInfo:@{ NSLocalizedDescriptionKey : @"Weather request timed out" }];
                break;
            }
            if (CFReadStreamHasBytesAvailable(stream)) {
                CFIndex n = CFReadStreamRead(stream, buffer, sizeof(buffer));
                if (n < 0) {
                    error = CFBridgingRelease(CFReadStreamCopyError(stream));
                    break;
                }
                if (n == 0) break;
                [data appendBytes:buffer length:(NSUInteger)n];
                if ((CFIndex)data.length > MODWeatherMaxBytes) {
                    error = [NSError errorWithDomain:@"ModernOS" code:5 userInfo:@{ NSLocalizedDescriptionKey : @"Weather response too large" }];
                    break;
                }
            } else {
                CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, true);
            }
        }
        if (!error) {
            CFHTTPMessageRef response = (CFHTTPMessageRef)CFReadStreamCopyProperty(stream, kCFStreamPropertyHTTPResponseHeader);
            CFIndex code = response ? CFHTTPMessageGetResponseStatusCode(response) : 0;
            if (response) CFRelease(response);
            if (code != 200) {
                error = [NSError errorWithDomain:@"ModernOS" code:6 userInfo:@{ NSLocalizedDescriptionKey : [NSString stringWithFormat:@"HTTP %ld", (long)code] }];
            }
        }
        CFReadStreamClose(stream);
    }
    CFReadStreamUnscheduleFromRunLoop(stream, runLoop, kCFRunLoopDefaultMode);
    CFRelease(stream);
    if (error) {
        if (outError) *outError = error;
        return nil;
    }
    return data;
}

#pragma clang diagnostic pop

@end
