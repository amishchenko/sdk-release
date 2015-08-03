//
//  TuneEventQueue.m
//  Tune
//
//  Created by John Bender on 8/12/14.
//  Copyright (c) 2014 TUNE. All rights reserved.
//

#import <UIKit/UIKit.h>

#import "TuneEncrypter.h"
#import "TuneEventQueue.h"
#import "TuneKeyStrings.h"
#import "TuneLocationHelper.h"
#import "TuneReachability.h"
#import "TuneRequestsQueue.h"
#import "TuneUtils.h"
#import "TuneUserAgentCollector.h"
#import "NSString+TuneURLEncoding.h"


int const TUNE_NETWORK_REQUEST_TIMEOUT_INTERVAL          = 60;

static NSString* const TUNE_REQUEST_QUEUE_FOLDER         = @"MATqueue";
static NSString* const TUNE_REQUEST_QUEUE_FILENAME       = @"events.json";
static NSString* const TUNE_LEGACY_REQUEST_QUEUE_FOLDER  = @"queue";

static const NSInteger TUNE_REQUEST_400_ERROR_CODE       = 1302;

#pragma mark - Private variables

@interface TuneEventQueue()
{
    /*!
     Shared NSOperationQueue.
     */
    NSOperationQueue *requestOpQueue;
    
    /*!
     List of queued events.
     */
    NSMutableArray *events;
    
    /*!
     Disk location of file used for storing serialized events.
     */
    NSString *storageDir;
}

@property (nonatomic, weak) id <TuneEventQueueDelegate> delegate;

#if TESTING
@property (nonatomic, readonly) NSMutableArray *events;
@property (nonatomic, assign) BOOL forceError;
@property (nonatomic, assign) NSInteger forcedErrorCode;

- (void) saveQueue;
- (void) dumpQueue;
#endif

@end


/*!
 Shared singleton event queue object.
 */
static TuneEventQueue *sharedQueue = nil;


@implementation TuneEventQueue

#if TESTING
@synthesize events = events;
#endif


#pragma mark - Initialization

+ (void)initialize
{
    sharedQueue = [TuneEventQueue new];
}

- (id)init
{
    self = [super init];
    if( self ) {
        requestOpQueue = [NSOperationQueue new];
        requestOpQueue.maxConcurrentOperationCount = 1;
        
        [self addNetworkAndAppNotificationListeners];
        
        [self createQueueStorageDirectory];
        
        [self prependItemsFromLegacyQueue];

        [self dumpQueue];
    }
    return self;
}

- (void)addNetworkAndAppNotificationListeners
{
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(networkChangeHandler)
                                                 name:kTuneReachabilityChangedNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(networkChangeHandler)
                                                 name:UIApplicationDidBecomeActiveNotification
                                               object:nil];
}

/*!
 Creates a disk folder to be used to store the serialized event queue.
 */
- (void)createQueueStorageDirectory
{
    // create queue storage directory
    CGFloat systemVersion = [TuneUtils numericiOSSystemVersion];
    NSSearchPathDirectory folderType = systemVersion < TUNE_IOS_VERSION_501 ? NSCachesDirectory : NSDocumentDirectory;
    NSArray *paths = NSSearchPathForDirectoriesInDomains(folderType, NSUserDomainMask, YES);
    NSString *baseFolder = [paths objectAtIndex:0];
    storageDir = [baseFolder stringByAppendingPathComponent:TUNE_REQUEST_QUEUE_FOLDER];
    
    if( ![[NSFileManager defaultManager] fileExistsAtPath:storageDir] ) {
        NSError *error = nil;
        [[NSFileManager defaultManager] createDirectoryAtPath:storageDir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:&error];
        if( error != nil ) {
            NSLog( @"Tune: error creating queue storage directory: %@", error );
        }
        else {
            [TuneUtils addSkipBackupAttributeToItemAtURL:[NSURL fileURLWithPath:storageDir]];
        }
    }
}

/*!
 Reads disk file that may contain legacy request queue and prepends the items to the main event queue.
 */
- (void)prependItemsFromLegacyQueue
{
    @synchronized( events ) {
        [self loadQueue];
        
        // if a legacy queue exists
        if([TuneRequestsQueue exists])
        {
            // load legacy queue items
            TuneRequestsQueue *legacyQueue = [TuneRequestsQueue new];
            [legacyQueue load];
            
            NSDictionary *item = [legacyQueue pop];
            NSMutableArray *legacyItems = [NSMutableArray array];
            
            while( item != nil ) {
                [legacyItems addObject:item];
                item = [legacyQueue pop];
            }
            
            // prepend legacy items
            if( [legacyItems count] > 0 ) {
                for( item in [legacyItems reverseObjectEnumerator] )
                    [events insertObject:item atIndex:0];
                [self saveQueue];
            }
            
            // permanently delete legacy queue file
            [legacyQueue closedown];
        }
    }
}

+ (void)setDelegate:(id <TuneEventQueueDelegate>)delegate
{
    sharedQueue.delegate = delegate;
}


#pragma mark - Notification Handlers

- (void)networkChangeHandler
{
    [self dumpQueue];
}


#pragma mark - Request handling

+ (void)enqueueUrlRequest:(NSString*)trackingLink
            encryptParams:(NSString*)encryptParams
                 postData:(NSString*)postData
                  runDate:(NSDate*)runDate
{
    [sharedQueue enqueueUrlRequest:trackingLink encryptParams:encryptParams postData:postData runDate:runDate];
}

- (void)enqueueUrlRequest:(NSString*)trackingLink
            encryptParams:(NSString*)encryptParams
                 postData:(NSString*)postData
                  runDate:(NSDate*)runDate
{
    // add retry count to tracking link
    [self appendOrIncrementRetryCount:&trackingLink sendDate:&runDate];
    
    // add item to queue
    // note that postData might be nil
    NSDictionary *item = [NSDictionary dictionaryWithObjectsAndKeys:
                          @([runDate timeIntervalSince1970]),   TUNE_KEY_RUN_DATE,
                          trackingLink,                         TUNE_KEY_URL,
                          encryptParams,                        TUNE_KEY_DATA,
                          postData,                             TUNE_KEY_JSON,
                          nil];
    
    @synchronized( events ) {
        [events addObject:item];
        [self saveQueue];
    }

    [self dumpQueue];
}


- (void)appendOrIncrementRetryCount:(NSString**)trackingLink sendDate:(NSDate**)sendDate
{
    NSInteger retryCount = 0;
    NSString *searchString = [NSString stringWithFormat:@"&%@=", TUNE_KEY_RETRY_COUNT];
    NSRange searchResult = [*trackingLink rangeOfString:searchString];
    
    if( searchResult.location == NSNotFound ) {
        *trackingLink = [*trackingLink stringByAppendingFormat:@"%@0", searchString];
        // don't touch send date
    }
    else {
        // parse number, increment it, replace it
        NSString *countString = [*trackingLink substringFromIndex:searchResult.location + searchResult.length];
        retryCount = [countString integerValue];
        NSUInteger valueLength = MAX(1, (int)(log10(retryCount)+1)); // count digits
        retryCount++;
        *trackingLink = [NSString stringWithFormat:@"%@%ld%@",
                         [*trackingLink substringToIndex:searchResult.location + searchResult.length],
                         (long)retryCount,
                         [*trackingLink substringFromIndex:searchResult.location + searchResult.length + valueLength]];
        *sendDate = [*sendDate dateByAddingTimeInterval:[[self class] retryDelayForAttempt:retryCount]];
    }
}

+ (NSTimeInterval)retryDelayForAttempt:(NSInteger)attempt
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        srand48( time( 0 ) );
    });
    
    NSTimeInterval delay;
    switch( attempt ) {
        case 0:
            delay = 0.;
            break;
        case 1:
            delay = 30.;
            break;
        case 2:
            delay = 90.;
            break;
        case 3:
            delay = 10.*60.;
            break;
        case 4:
            delay = 60.*60;
            break;
        case 5:
            delay = 6.*60.*60.;
            break;
        case 6:
        default:
            delay = 24.*60.*60.;
    }
    
    return (1 + 0.1*drand48())*delay;
}


#pragma mark - Sending requests

- (NSString*)updateTrackingLink:(NSString*)trackingLink encryptParams:(NSString*)encryptParams
{
    // Add/update tracked values that are determined asynchronously.
    
    if( encryptParams != nil ) {
        // if iad_attribution, append/overwrite current status
        if( [self.delegate isiAdAttribution] ) {
            NSString *searchString = [NSString stringWithFormat:@"&%@=0", TUNE_KEY_IAD_ATTRIBUTION];
            NSString *replaceString = [NSString stringWithFormat:@"&%@=1", TUNE_KEY_IAD_ATTRIBUTION];
            if( [encryptParams rangeOfString:searchString].location != NSNotFound )
                encryptParams = [encryptParams stringByReplacingOccurrencesOfString:searchString withString:replaceString];
            else
                encryptParams = [encryptParams stringByAppendingString:replaceString];
        }
        
        // append user agent, if not present
        NSString *searchString = [NSString stringWithFormat:@"%@=", TUNE_KEY_CONVERSION_USER_AGENT];
        if( [encryptParams rangeOfString:searchString].location == NSNotFound )
        {
            // url encoded user agent string
            NSString *encodedUserAgent = [TuneUtils urlEncodeQueryParamValue:[TuneUserAgentCollector userAgent]];
            if(encodedUserAgent)
            {
                encryptParams = [encryptParams stringByAppendingFormat:@"&%@=%@", TUNE_KEY_CONVERSION_USER_AGENT, encodedUserAgent];
            }
        }
        
        searchString = [NSString stringWithFormat:@"%@=", TUNE_KEY_LATITUDE];
        // if the request url does not contain device location params, try to auto-collect
        if( [encryptParams rangeOfString:searchString].location == NSNotFound )
        {
            // check if location already exists
            NSArray *latLonAlt;
            BOOL locationEnabled = [TuneLocationHelper getOrRequestDeviceLocation:&latLonAlt];
            
            // if location has been enabled
            if(locationEnabled)
            {
                // if location is not readily available
                if(!latLonAlt)
                {
                    // wait for location update to finish
                    [NSThread sleepForTimeInterval:TUNE_LOCATION_UPDATE_DELAY];
                    locationEnabled = [TuneLocationHelper getOrRequestDeviceLocation:&latLonAlt];
                }
                
                // if the location is available
                if(latLonAlt)
                {
                    // include the location info in the request url
                    encryptParams = [encryptParams stringByAppendingFormat:@"&%@=%@&%@=%@&%@=%@&%@=%@&%@=%@&%@=%@"
                                     , TUNE_KEY_LATITUDE, [TuneUtils urlEncodeQueryParamValue:latLonAlt[0]]
                                     , TUNE_KEY_LONGITUDE, [TuneUtils urlEncodeQueryParamValue:latLonAlt[1]]
                                     , TUNE_KEY_ALTITUDE, [TuneUtils urlEncodeQueryParamValue:latLonAlt[2]]
                                     , TUNE_KEY_LOCATION_HORIZONTAL_ACCURACY, [TuneUtils urlEncodeQueryParamValue:latLonAlt[3]]
                                     , TUNE_KEY_LOCATION_VERTICAL_ACCURACY, [TuneUtils urlEncodeQueryParamValue:latLonAlt[4]]
                                     , TUNE_KEY_LOCATION_TIMESTAMP, [TuneUtils urlEncodeQueryParamValue:latLonAlt[5]]
                                     ];
                }
            }
        }
        
        // encrypt params and append
        NSString* encryptedData = [TuneEncrypter encryptString:encryptParams withKey:[self.delegate encryptionKey]];
        trackingLink = [trackingLink stringByAppendingFormat:@"&%@=%@", TUNE_KEY_DATA, encryptedData];
    }
    
    return trackingLink;
}

/*!
 Fires each enqueued event until the queue is emptied. Fires the next event only when the previous event request has finished.
 */
- (void)dumpQueue
{
    if( ![TuneUtils isNetworkReachable] ) return;
    
    [requestOpQueue addOperationWithBlock:^{
        // get first request
        NSDictionary *request = nil;
        @synchronized( events ) {
            if( [events count] < 1 ) return;
            request = events[0];
        }
        
        // sleep until fire date
        NSDate *runDate = [NSDate dateWithTimeIntervalSince1970:[request[TUNE_KEY_RUN_DATE] doubleValue]];
        if( [runDate isKindOfClass:[NSDate class]] ) {
            [NSThread sleepUntilDate:runDate];
        }
        
        // fire URL request synchronously
        NSString *trackingLink = request[TUNE_KEY_URL];
        NSString *encryptParams = request[TUNE_KEY_DATA];
        NSString *postData = request[TUNE_KEY_JSON];
        
        NSString *fullRequestString = [self updateTrackingLink:trackingLink encryptParams:encryptParams];
        
#if DEBUG
        // for testing, attempt informing the delegate's delegate of the trackingLink
        if( [self.delegate respondsToSelector:@selector(delegate)] ) {
            id ddelegate = [self.delegate performSelector:@selector(delegate)];
            if( [ddelegate respondsToSelector:@selector(_tuneSuperSecretURLTestingCallbackWithURLString:andPostDataString:)] )
                [ddelegate performSelector:@selector(_tuneSuperSecretURLTestingCallbackWithURLString:andPostDataString:) withObject:fullRequestString withObject:postData];
        }
#endif
        NSURL *reqUrl = [NSURL URLWithString:fullRequestString];
        NSMutableURLRequest *urlReq = [NSMutableURLRequest requestWithURL:reqUrl
                                                              cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                          timeoutInterval:TUNE_NETWORK_REQUEST_TIMEOUT_INTERVAL];
        
        NSData *post = [postData dataUsingEncoding:NSUTF8StringEncoding];
        [urlReq setHTTPMethod:TUNE_HTTP_METHOD_POST];
        [urlReq setValue:TUNE_HTTP_CONTENT_TYPE_APPLICATION_JSON forHTTPHeaderField:TUNE_HTTP_CONTENT_TYPE];
        [urlReq setValue:[NSString stringWithFormat:@"%lu", (unsigned long)post.length] forHTTPHeaderField:TUNE_HTTP_CONTENT_LENGTH];
        [urlReq setHTTPBody:post];
        
        NSHTTPURLResponse *urlResp = nil;
        NSError *error = nil;
        NSData *data = nil;
        
        NSInteger code = 0;
        
#if TESTING
        // when testing network errors, skip request and force error response
        if(self.forceError)
        {
            error = [NSError errorWithDomain:@"TuneTest" code:self.forcedErrorCode userInfo:nil];
        }
        else
#endif
        data = [NSURLConnection sendSynchronousRequest:urlReq returningResponse:&urlResp error:&error];
        
        if( error != nil ) {
            
            DLLog(@"TuneEventQueue: dumpQueue: error code = %d", (int)error.code);
            
            if( [_delegate respondsToSelector:@selector(queueRequestDidFailWithError:)] )
                [_delegate queueRequestDidFailWithError:error];
            
            urlResp = nil; // set response to nil and make sure that the request is retried
        }
        
#if TESTING
        // when testing network errors, use forced error code
        if(self.forceError)
        {
            code = self.forcedErrorCode;
        }
        else
#endif
        code = [urlResp statusCode];
        NSDictionary *headers = [urlResp allHeaderFields];
        NSDictionary *newFirstItem = nil;
        
        // if the network request was successful, great
        if( code >= 200 && code <= 299 ) {
            if( [_delegate respondsToSelector:@selector(queueRequestDidSucceedWithData:)] )
                [_delegate queueRequestDidSucceedWithData:data];
            // leave newFirstItem nil to delete
        }
        // for HTTP 400, if it's from our server, drop the request and don't retry
        else if( code == 400 && headers[@"X-MAT-Responder"] != nil ) {
            if( [_delegate respondsToSelector:@selector(queueRequestDidFailWithError:)] ) {
                
                NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
                userInfo[NSLocalizedFailureReasonErrorKey] = @"Bad Request";
                userInfo[NSLocalizedDescriptionKey] = @"HTTP 400/Bad Request received from Tune server";
                userInfo[NSURLErrorKey] = reqUrl;
                
                // use setValue:forKey: to handle nil error object
                [userInfo setValue:error forKey:NSUnderlyingErrorKey];
                
                NSError *e = [NSError errorWithDomain:TUNE_KEY_ERROR_DOMAIN
                                                 code:TUNE_REQUEST_400_ERROR_CODE
                                             userInfo:userInfo];
                [_delegate queueRequestDidFailWithError:e];
            }
            // leave newFirstItem nil to delete
        }
        // for all other calls, assume the server/connection is broken and will be fixed later
        else {
            // update retry parameters
            NSDate *newSendDate = [NSDate date];
            
            [self appendOrIncrementRetryCount:&trackingLink sendDate:&newSendDate];
            
            NSMutableDictionary *newRequest = [NSMutableDictionary dictionaryWithDictionary:request];
            newRequest[TUNE_KEY_URL] = trackingLink;
            newRequest[TUNE_KEY_RUN_DATE] = @([newSendDate timeIntervalSince1970]);
            newFirstItem = [NSDictionary dictionaryWithDictionary:newRequest];
        }
        
        // pop or replace event from queue
        @synchronized( events ) {
            NSUInteger index = [events indexOfObject:request];
            
            if( index != NSNotFound ) {
                if( newFirstItem == nil )
                    [events removeObjectAtIndex:index];
                else
                    [events replaceObjectAtIndex:index withObject:newFirstItem];
            }
            
            [self saveQueue];
        }

        // send next
        [self performSelectorOnMainThread:@selector(dumpQueue) withObject:nil waitUntilDone:NO];
    }];
}


#pragma mark - Queue storage

/*! Reads file from disk, deserializes and refills the network request queue.
 
 Note: Calls to loadQueue should be wrapped in @synchronized(events){}
 */
- (void)loadQueue
{
    events = [NSMutableArray array];
    
    NSString *path = [storageDir stringByAppendingPathComponent:TUNE_REQUEST_QUEUE_FILENAME];
    
    if( ![[NSFileManager defaultManager] fileExistsAtPath:path] )
        return;
    
    NSError *error = nil;
    NSData *serializedQueue = [NSData dataWithContentsOfFile:path options:0 error:&error];
    if( error != nil ) {
        NSLog( @"Tune: error reading event queue from file: %@", error );
        return;
    }
    
    id queue = [NSJSONSerialization JSONObjectWithData:serializedQueue options:0 error:&error];
    if( error != nil ) {
        NSLog( @"Tune: error deserializing event queue from storage: %@", error );
        return;
    }
    
    if( ![queue isKindOfClass:[NSArray class]] ) {
        NSLog( @"Tune: unexpected data type %@ read from storage", [queue class] );
        return;
    }
    
    for( id item in (NSArray*)queue ) {
        if( ![item isKindOfClass:[NSDictionary class]] ) {
            NSLog( @"Tune: unexpected data type %@ in array read from storage", [item class] );
            return;
        }
    }
    
    events = [NSMutableArray arrayWithArray:(NSArray*)queue];
}

/*! Serializes and saves the existing network request queue to disk.
 
 Note: Calls to saveQueue should be wrapped in @synchronized(events){}
 */
- (void)saveQueue
{
    NSError *error = nil;
    NSData *serializedQueue = [NSJSONSerialization dataWithJSONObject:events options:0 error:&error];
    if( error != nil ) {
        NSLog( @"Tune: error serializing event queue for storage: %@", error );
        return;
    }
    
    NSString *path = [storageDir stringByAppendingPathComponent:TUNE_REQUEST_QUEUE_FILENAME];
    if( [serializedQueue writeToFile:path atomically:YES] == NO ) {
        NSLog( @"Tune: error writing event queue to file: %@", error );
        return;
    }
}


#pragma mark - Testing Helper Methods

#if TESTING

+ (instancetype)sharedInstance
{
    return sharedQueue;
}

+ (NSMutableArray *)events
{
    @synchronized( sharedQueue.events ) {
        return sharedQueue.events;
    }
}

+ (NSDictionary *)eventAtIndex:(NSUInteger)index
{
    @synchronized( sharedQueue.events ) {
        return [sharedQueue.events objectAtIndex:index];
    }
}

+ (NSUInteger)queueSize
{
    @synchronized( sharedQueue.events ) {
        return [sharedQueue.events count];
    }
}

+ (void)drain
{
    @synchronized( sharedQueue.events ) {
        [sharedQueue.events removeAllObjects];
        
        [sharedQueue saveQueue];
    }
}

+ (void)dumpQueue
{
    [sharedQueue dumpQueue];
}

+ (void)setForceNetworkError:(BOOL)isError code:(NSInteger)code
{
    sharedQueue.forceError = isError;
    sharedQueue.forcedErrorCode = isError ? code : 0;
}

#endif

@end