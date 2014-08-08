//
//  LEANWebViewIntercept.m
//  GoNativeIOS
//
//  Created by Weiyin He on 4/12/14.
// Copyright (c) 2014 GoNative.io LLC. All rights reserved.
//

#import "LEANWebViewIntercept.h"
#import "LEANAppDelegate.h"
#import "LEANAppConfig.h"
#import "GTMNSString+HTML.h"

static NSPredicate* webViewUserAgentTest;
static NSPredicate* schemeHttpTest;
static NSOperationQueue* queue;

static NSString * kOurRequestProperty = @"io.gonative.ios.LEANWebViewIntercept";


@interface LEANWebViewIntercept () <NSURLConnectionDataDelegate>
@property NSMutableURLRequest *modifiedRequest;
@property NSURLConnection *conn;
@property BOOL isHtml;
@property NSStringEncoding htmlEncoding;
@property NSMutableData *htmlBuffer;
@end

@implementation LEANWebViewIntercept

+(void)initialize
{
    webViewUserAgentTest = [NSPredicate predicateWithFormat:@"self MATCHES '^Mozilla.*Mac OS X.*'"];
    schemeHttpTest = [NSPredicate predicateWithFormat:@"scheme in {'http', 'https'}"];
    queue = [[NSOperationQueue alloc] init];
    [queue setMaxConcurrentOperationCount:5];
    
    [NSURLProtocol registerClass:[LEANWebViewIntercept class]];
}

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    NSString* userAgent = [request valueForHTTPHeaderField:@"User-Agent"];
    if (userAgent && ![webViewUserAgentTest evaluateWithObject:userAgent]) return NO;
    if (![schemeHttpTest evaluateWithObject:request.URL]) return NO;
    if ([self propertyForKey:kOurRequestProperty inRequest:request]) return NO;
    
    // if is equal to current url being loaded, then intercept
    NSURLRequest *currentRequest = ((LEANAppDelegate*)[UIApplication sharedApplication].delegate).currentRequest;
    
    if ([[request URL] isEqual:[currentRequest URL]] &&
        [[request HTTPMethod] isEqualToString:[currentRequest HTTPMethod]] &&
        [request HTTPBody] == [currentRequest HTTPBody] &&
        [request HTTPBodyStream] == [currentRequest HTTPBodyStream]) {
        return YES;
    }
    else {
        return NO;
    }
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

- (id)initWithRequest:(NSURLRequest *)request cachedResponse:(NSCachedURLResponse *)cachedResponse client:(id<NSURLProtocolClient>)client {
    if (self = [super initWithRequest:request cachedResponse:cachedResponse client:client]) {
        self.modifiedRequest = request.mutableCopy;
        [[self class] setProperty:[NSNumber numberWithBool:YES] forKey:kOurRequestProperty inRequest:self.modifiedRequest];
    }
    self.isHtml = NO;
    return self;
}

- (void)startLoading {
    self.conn = [NSURLConnection connectionWithRequest:self.modifiedRequest delegate:self];
}

- (void)stopLoading {
    [self.conn cancel];
    self.modifiedRequest = nil;
    self.conn = nil;
}

- (NSData *)modifyHtml:(NSData *)htmlBuffer
{
    NSString *origString = [[NSString alloc] initWithData:htmlBuffer encoding:self.htmlEncoding];
    
    // find closing </head> tag
    NSRange insertPoint = [origString rangeOfString:@"</head>" options:NSCaseInsensitiveSearch];
    if (insertPoint.location != NSNotFound) {
        NSString *customCss = [LEANAppConfig sharedAppConfig].customCss;
        NSString *stringViewport = [LEANAppConfig sharedAppConfig].stringViewport;
        NSNumber *viewportWidth = [LEANAppConfig sharedAppConfig].forceViewportWidth;
        
        NSMutableString *newString = [[origString substringToIndex:insertPoint.location] mutableCopy];
        if (customCss) {
            [newString appendString:@"<style>"];
            [newString appendString:customCss];
            [newString appendString:@"</style>"];
        }
        
        
        if (stringViewport) {
            [newString appendString:@"<meta name=\"viewport\" content=\""];
            [newString appendString:[stringViewport gtm_stringByEscapingForHTML]];
            [newString appendString:@"\">"];
        }
        if (viewportWidth) {
            [newString appendFormat:@"<meta name=\"viewport\" content=\"width=%@,user-scalable=no\"/>", viewportWidth];
        }
        
        if (!stringViewport && !viewportWidth) {
            // find original viewport
            NSString *origViewport = [LEANWebViewIntercept extractViewport:origString];
            
            if ([origViewport length] > 0) {
                [newString appendFormat:@"<meta name=\"viewport\" content=\"%@,user-scalable=no\"/>", origViewport];
            }
            else {
                [newString appendFormat:@"<meta name=\"viewport\" content=\"user-scalable=no\"/>"];
            }
        }
        
        [newString appendString:[origString substringFromIndex:insertPoint.location]];
        return [newString dataUsingEncoding:self.htmlEncoding];
    } else {
        return htmlBuffer;
    }

}

+(NSString *)extractViewport:(NSString*)html
{
    if (!html) return nil;
    
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"<meta\\s+name=[\"']viewport[\"']\\s+content=[\"']([-;,=\\.\\w\\s]+)[\"']\\s*/?>" options:NSRegularExpressionCaseInsensitive error:nil];
    NSArray *results = [regex matchesInString:html options:0 range:NSMakeRange(0, [html length])];
    if ([results count] > 0) {
        NSTextCheckingResult *result = results[0];
        return [html substringWithRange:[result rangeAtIndex:1]];
    }
    
    regex = [NSRegularExpression regularExpressionWithPattern:@"<meta\\s+content=[\"']([-;,=\\.\\w\\s]+)[\"']\\s+name=[\"']viewport[\"']\\s*/?>" options:NSRegularExpressionCaseInsensitive error:nil];
    results = [regex matchesInString:html options:0 range:NSMakeRange(0, [html length])];
    if ([results count] > 0) {
        NSTextCheckingResult *result = results[0];
        return [html substringWithRange:[result rangeAtIndex:1]];
    }
    
    return nil;
}

#pragma mark - URL Connection Data Delegate
- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response {
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    
    if ([[response MIMEType] hasPrefix:@"text/html"]) {
        self.isHtml = YES;
        self.htmlBuffer = [[NSMutableData alloc] init];
        NSString *encoding = [response textEncodingName];
        if (encoding == nil) {
            self.htmlEncoding = NSUTF8StringEncoding;
        } else {
            CFStringEncoding cfEncoding = CFStringConvertIANACharSetNameToEncoding((__bridge CFStringRef)encoding);
            if (cfEncoding == kCFStringEncodingInvalidId)
                self.htmlEncoding = NSUTF8StringEncoding;
            else
                self.htmlEncoding = CFStringConvertEncodingToNSStringEncoding(cfEncoding);
        }
    } else {
        self.isHtml = NO;
    }
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data {
    if (self.isHtml)
        [self.htmlBuffer appendData:data];
    else
        [self.client URLProtocol:self didLoadData:data];
}

- (NSURLRequest *)connection:(NSURLConnection *)connection willSendRequest:(NSURLRequest *)request redirectResponse:(NSURLResponse *)redirectResponse
{
    if (redirectResponse != nil) {
        NSMutableURLRequest *newReq = [request mutableCopy];
        [[self class] removePropertyForKey:kOurRequestProperty inRequest:newReq];
        [self.client URLProtocol:self wasRedirectedToRequest:newReq redirectResponse:redirectResponse];

        // client will resend request, so cancel this one.
        // See Apple's CustomHTTPProtocol example.
        [self.conn cancel];
        [self.client URLProtocol:self didFailWithError:[NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:nil]];
    }
    
    return request;
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection {
    if (self.isHtml) {
        [self.client URLProtocol:self didLoadData:[self modifyHtml:self.htmlBuffer]];
    } else {
        [self.client URLProtocol:self didLoadData:self.htmlBuffer];
    }
    
    [self.client URLProtocolDidFinishLoading:self];
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error {
    [self.client URLProtocol:self didFailWithError:error];
}

//- (NSCachedURLResponse *)connection:(NSURLConnection *)connection willCacheResponse:(NSCachedURLResponse *)cachedResponse
//{
//    if (self.isHtml)
//        return [[NSCachedURLResponse alloc] initWithResponse:[cachedResponse response] data:[self modifyHtml:[cachedResponse data]] userInfo:[cachedResponse userInfo] storagePolicy:[cachedResponse storagePolicy]];
//    else
//        return cachedResponse;
//}


@end



