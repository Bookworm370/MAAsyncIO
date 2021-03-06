//
//  MAAsyncHost.m
//  MAAsyncIO
//
//  Created by Michael Ash on 12/8/10.
//  Copyright 2010 Michael Ash. All rights reserved.
//

#import "MAAsyncHost.h"

#include <netdb.h>

#import "MAAsyncSocketUtils.h"


NSString * const MACFStreamNSErrorDomain = @"com.mikeash.MACFStreamNSErrorDomain";

@implementation MAAsyncHost

+ (void)_resolutionThread
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSPort *port = [NSPort port];
    [[NSRunLoop currentRunLoop] addPort: port forMode: NSDefaultRunLoopMode];
    [[NSRunLoop currentRunLoop] run];
    [pool release];
}

+ (void)_resolutionGetRunloop: (NSMutableArray *)array
{
    [array addObject: (id)CFRunLoopGetCurrent()];
}

+ (CFRunLoopRef)_resolutionRunloop
{
    static CFRunLoopRef runloop;
    static dispatch_once_t pred;
    dispatch_once(&pred, ^{
        NSThread *thread = [[NSThread alloc] initWithTarget: self selector: @selector(_resolutionThread) object: nil];
        [thread start];
        
        NSMutableArray *runloopArray = [NSMutableArray array];
        [self performSelector: @selector(_resolutionGetRunloop:) onThread: thread withObject: runloopArray waitUntilDone: YES];
        runloop = (CFRunLoopRef)[runloopArray lastObject];
        CFRetain(runloop);
        [thread release];
    });
    return runloop;
}

+ (id)hostWithName: (NSString *)name
{
    return [[[self alloc] initWithName: name] autorelease];
}

- (id)initWithName: (NSString *)name
{
    if((self = [self init]))
    {
        _cfhost = CFHostCreateWithName(NULL, (CFStringRef)name);
        _queue = dispatch_queue_create("com.mikeash.MAAsyncHost", NULL);
        _resolveBlocks = [[NSMutableArray alloc] init];
    }
    return self;
}

- (void)dealloc
{
    CFRelease(_cfhost);
    dispatch_release(_queue);
    [_addresses release];
    [_resolveBlocks release];
    
    [super dealloc];
}

- (void)_callResolveBlocksAddresses: (NSArray *)addresses error: (CFStreamError)error
{
    void (^block)(NSArray *addresses, CFStreamError error);
    for(block in _resolveBlocks)
        block(addresses, error);
    [_resolveBlocks removeAllObjects];
}

static void ResolveCallback(CFHostRef theHost, CFHostInfoType typeInfo, const CFStreamError *errorPtr, void *info)
{
    MAAsyncHost *self = info;
    CFStreamError error = { 0, 0 };
    if(errorPtr)
        error = *errorPtr;
    
    assert(!self->_addresses);
    
    NSArray *addresses = [(NSArray *)CFHostGetAddressing(self->_cfhost, NULL) copy];
    
    dispatch_async(self->_queue, ^{
        if(error.domain)
        {
            [self _callResolveBlocksAddresses: nil error: error];
        }
        else
        {
            self->_addresses = [addresses copy];
            [self _callResolveBlocksAddresses: self->_addresses error: (CFStreamError){ 0, 0 }];
        }
    });
    
    [addresses release];
}

- (void)resolve: (void (^)(NSArray *addresses, CFStreamError error))block
{
    dispatch_async(_queue, ^{
        if(_addresses)
        {
            block(_addresses, (CFStreamError){ 0, 0 });
        }
        else 
        {
            if(!_resolving)
            {
                CFHostClientContext ctx = { 0, self, CFRetain, CFRelease, NULL };
                CFHostSetClient(_cfhost, ResolveCallback, &ctx);
                
                CFHostScheduleWithRunLoop(_cfhost, [[self class] _resolutionRunloop], kCFRunLoopDefaultMode);
                
                CFStreamError error;
                Boolean success = CFHostStartInfoResolution(_cfhost, kCFHostAddresses, &error);
                
                if(!success)
                {
                    block(nil, error);
                }
                else
                {
                    [_resolveBlocks addObject: block];
                    _resolving = YES;
                }
            }
            else
                [_resolveBlocks addObject: block];
        }
    });
}

- (NSError *)_errorForCFStreamError: (CFStreamError)cferror
{
    NSDictionary *userInfo = [NSDictionary dictionaryWithObjectsAndKeys: 
                              [NSNumber numberWithInteger: cferror.error], @"cfcode",
                              nil];
    NSError *error = [NSError errorWithDomain: MACFStreamNSErrorDomain code: cferror.domain userInfo: userInfo];
    return error;
}

- (void)_connectToPort: (int)port addressEnumerator: (NSEnumerator *)enumerator lastError: (NSError *)lastError callback: (void (^)(MAAsyncReader *reader, MAAsyncWriter *writer, NSError *error))block
{
    NSData *address = [enumerator nextObject];
    if(!address)
    {
        if(!lastError)
            lastError = [self _errorForCFStreamError: (CFStreamError){ kCFStreamErrorDomainNetDB, NO_DATA }];
        block(nil, nil, lastError);
    }
    else
    {
        MAAsyncSocketConnect(address, port, ^(MAAsyncReader *reader, MAAsyncWriter *writer, NSError *error) {
            if(reader && writer)
                block(reader, writer, nil);
            else
                [self _connectToPort: port addressEnumerator: enumerator lastError: error callback: block];
        });
    }
}

- (void)connectToPort: (int)port callback: (void (^)(MAAsyncReader *reader, MAAsyncWriter *writer, NSError *error))block
{
    [self resolve: ^(NSArray *addresses, CFStreamError error) {
        if(!addresses)
        {
            block(nil, nil, [self _errorForCFStreamError: error]);
        }
        else
            [self _connectToPort: port addressEnumerator: [addresses objectEnumerator] lastError: nil callback: block];
    }];
}

@end
