#import <Foundation/Foundation.h>

@interface MODWeather : NSObject
@property (nonatomic, assign) double temperature;   // in the requested unit
@property (nonatomic, assign) NSInteger code;       // WMO weather code
@property (nonatomic, strong) NSDate *fetchedAt;
@property (nonatomic, readonly) NSString *summary;
@end

// Optional weather from Open-Meteo (no API key). Requests are made only while
// the dashboard is visible and the cache is older than 30 minutes, on a
// background thread with a hard 10 s budget.
//
// iOS 9 constraints (verified): SpringBoard enforces App Transport Security
// (no exceptions in its Info.plist) and iOS 9 does not trust the ISRG Root X1
// chain used by api.open-meteo.com, so NSURLSession cannot reach the service.
// The request therefore uses CFNetwork's HTTP stream (outside ATS) over plain
// HTTP. Only coarse coordinates are sent; nothing else leaves the device.
@interface MODWeatherService : NSObject
+ (instancetype)shared;
- (MODWeather *)cachedWeather;   // memory or on-disk cache, may be stale or nil
- (void)refreshIfStaleForLatitude:(double)latitude longitude:(double)longitude
                       fahrenheit:(BOOL)fahrenheit
                       completion:(void (^)(MODWeather *weather, NSError *error))completion;
- (void)purge;
@end
