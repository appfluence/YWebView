//
//  YWebView.m
//  YWebView
//
//  Created by Hai Feng Kao on 2016/06/25.
//
//

#import "YWebView.h"
#import "NSString+Cookie.h" // convert NSString to NSHttpCookie

/** 
  * YMessageHandler deals with the script messages sent from cookieOutScript
  */
@interface YMessageHandler : NSObject<WKScriptMessageHandler>
@property (nonatomic, weak) WKWebView* webView;
@end

@implementation YMessageHandler

#pragma mark - WKScriptMessageHandler
- (void)userContentController:(WKUserContentController *)userContentController didReceiveScriptMessage:(WKScriptMessage *)message 
{
    NSAssert(self.webView, @"do you forget to set it?");
    NSArray<NSString*>* cookies = [message.body componentsSeparatedByString:@"; "];
    for (NSString *cookie in cookies) {
        // Get this cookie's name and value
        NSArray<NSString *> *comps = [cookie componentsSeparatedByString:@"="];
        if (comps.count < 2) {
            continue;
        }

        // we need NSHTTPCookieOriginURL for NSHTTPCookie to be created
        NSString* cookieWithURL = [NSString stringWithFormat:@"%@; ORIGINURL=%@", cookie, self.webView.URL];
        NSHTTPCookie* httpCookie = [cookieWithURL cookie];

        if (httpCookie) {
            [[NSHTTPCookieStorage sharedHTTPCookieStorage] setCookie:httpCookie];
        } 
            
        // TODO: why do we update stale value only?
        // Get the cookie in shared storage with that name
        //NSHTTPCookie *localCookie = nil;
        //for (NSHTTPCookie *c in [[NSHTTPCookieStorage sharedHTTPCookieStorage] cookiesForURL:self.webView.URL]) {
            //if ([c.name isEqualToString:comps[0]]) {
                //localCookie = c;
                //break;
            //}
        //}

        // If there is a cookie with a stale value, update it now.
        //if (localCookie) {
            //NSMutableDictionary *props = [localCookie.properties mutableCopy];
            //props[NSHTTPCookieValue] = comps[1];
            //NSHTTPCookie *updatedCookie = [NSHTTPCookie cookieWithProperties:props];
            //[[NSHTTPCookieStorage sharedHTTPCookieStorage] setCookie:updatedCookie];
        //}
    }
}

@end

#define Y_HANDLER_NAME @"y_updateCookies"
@interface YWebView ()<WKNavigationDelegate>
@property (nonatomic, strong) YMessageHandler* messageHandler;
@property (nonatomic, strong) NSMutableArray* messageHandlerNames;
@property (nonatomic, strong) WKWebViewConfiguration* theConfiguration;
@end

@implementation YWebView

- (instancetype)init
{
    return [self initWithFrame:CGRectZero];
}

- (instancetype)initWithCoder:(NSCoder *)aDecoder
{
    return [self init];
}

- (instancetype)initWithFrame:(CGRect)frame
{
    return [self initWithFrame:frame configuration:nil];
}

- (instancetype)initWithFrame:(CGRect)frame configuration:(WKWebViewConfiguration*)theConfiguration
{
    YMessageHandler* handler = [[YMessageHandler alloc] init];

    WKWebViewConfiguration* configuration = theConfiguration ?: [[WKWebViewConfiguration alloc] init];
    WKUserContentController* controller = configuration.userContentController ?: [[WKUserContentController alloc] init];
    configuration.userContentController = controller;

    // TODO: addCookieInScriptWithController should not put all cookies of all domains into the javascript
    // BUT we don't know the correct domain unless the request has been loaded, what should we do?
    //[YWebView addCookieInScriptWithController:controller];
    
    [YWebView addCookieOutScriptWithController:controller handler:handler]; // will add Y_HANDLER_NAME here

    if (self = [super initWithFrame:frame configuration:configuration]) {
        self.navigationDelegate = self;
        _theConfiguration = configuration;
        _messageHandlerNames = [[NSMutableArray alloc] init];
        _messageHandler = handler;
        _messageHandler.webView = self;

        [self addScriptMessageHandlerNameForCleanup:Y_HANDLER_NAME];
    }
    return self;
}

- (void)dealloc
{
    for (NSString* name in _messageHandlerNames) {
        [_theConfiguration.userContentController removeScriptMessageHandlerForName:name];
    }
}

- (void)addScriptMessageHandlerNameForCleanup:(NSString*)name
{
    [self.messageHandlerNames addObject:name];
}


- (WKNavigation *)loadRequest:(NSURLRequest*)originalRequest
{
    NSString *validDomain = originalRequest.URL.host;
    if (validDomain.length <= 0) {
        // hasSuffix requires non-nil string
        return [super loadRequest:originalRequest];
    }
    [self readCookies:nil];

    NSMutableURLRequest *request = [originalRequest mutableCopy];

    const BOOL requestIsSecure = [request.URL.scheme isEqualToString:@"https"];

    NSMutableArray *array = [NSMutableArray array];
    for (NSHTTPCookie *cookie in NSHTTPCookieStorage.sharedHTTPCookieStorage.cookies) {
        // Don't even bother with values containing a `'`
        if ([cookie.name rangeOfString:@"'"].location != NSNotFound) {
            //NSLog(@"Skipping %@ because it contains a '", cookie.properties);
            continue;
        }

        // Is the cookie for current domain?
        if (![validDomain hasSuffix:cookie.domain] && ![cookie.domain hasSuffix:validDomain]) {
            //NSLog(@"Skipping %@ (because not %@)", cookie.properties, validDomain);
            continue;
        }

        // Are we secure only?
        if (cookie.secure && !requestIsSecure) {
            //NSLog(@"Skipping %@ (because %@ not secure)", cookie.properties, request.URL.absoluteString);
            continue;
        }

        NSString *value = [NSString stringWithFormat:@"%@=%@", cookie.name, cookie.value];
        [array addObject:value];
    }

    NSString *header = [array componentsJoinedByString:@";"];
    [request setValue:header forHTTPHeaderField:@"Cookie"];

    return [super loadRequest:request];
}

- (void)removeCookies:(nullable void (^)(void))completion {
    if (@available(macOS 10.13, iOS 11.0, *)) {
        WKWebsiteDataStore *store = WKWebsiteDataStore.defaultDataStore;
        [store.httpCookieStore getAllCookies:^(NSArray<NSHTTPCookie *> * _Nonnull cookies) {
            for (NSHTTPCookie *cookie in cookies) {
                [store.httpCookieStore deleteCookie:cookie completionHandler:^{}];
            }

            if (completion) {
                completion();
            }
        }];
        return;
    }

    if (@available(macOS 10.11, iOS 9.0, *)) {
        NSSet *websiteDataTypes = [NSSet setWithArray:@[WKWebsiteDataTypeCookies]];
        NSDate *dateFrom = [NSDate dateWithTimeIntervalSince1970:0];
        [WKWebsiteDataStore.defaultDataStore removeDataOfTypes:websiteDataTypes
                                                 modifiedSince:dateFrom
                                             completionHandler:^{}];
    }

    if (completion) {
        completion();
    }
}

- (void)readCookies:(nullable void (^)(void))completion {
    [self removeCookies:^{
        if (@available(macOS 10.13, iOS 11.0, *)) {
            NSArray *cookies = NSHTTPCookieStorage.sharedHTTPCookieStorage.cookies;
            NSHTTPCookie *last = cookies.lastObject;
            for (NSHTTPCookie *cookie in NSHTTPCookieStorage.sharedHTTPCookieStorage.cookies) {
                WKWebsiteDataStore *store = WKWebsiteDataStore.defaultDataStore;
                [store.httpCookieStore setCookie:cookie completionHandler:cookie == last ? completion : nil];
            }
        } if (completion) {
            completion();
        }
    }];
}

- (void)saveCookies:(nullable void (^)(void))completion {
    if (@available(macOS 10.13, iOS 11.0, *)) {
        WKWebsiteDataStore *store = WKWebsiteDataStore.defaultDataStore;
        [store.httpCookieStore getAllCookies:^(NSArray<NSHTTPCookie *> * _Nonnull cookies) {
            for (NSHTTPCookie *cookie in cookies) {
                [NSHTTPCookieStorage.sharedHTTPCookieStorage setCookie:cookie];

            }

            if (completion) {
                completion();
            }
        }];
    } else if (completion) {
        completion();
    }
}

#pragma mark - private
+ (void)addCookieInScriptWithController:(WKUserContentController*)userContentController
{
    NSMutableString* script = [[NSMutableString alloc] init];

    // Get the currently set cookie names in javascriptland
    [script appendString:@"var cookieNames = document.cookie.split('; ').map(function(cookie) { return cookie.split('=')[0] } );\n"];

    for (NSHTTPCookie *cookie in [[NSHTTPCookieStorage sharedHTTPCookieStorage] cookies]) {
        // Skip cookies that will break our script
        if ([cookie.value rangeOfString:@"'"].location != NSNotFound) {
            continue;
        }
        // Create a line that appends this cookie to the web view's document's cookies
        [script appendFormat:@"if (cookieNames.indexOf('%@') == -1) { document.cookie='%@'; };\n", cookie.name, [self javascriptStringWithCookie:cookie]];

    }
    WKUserScript *cookieInScript = [[WKUserScript alloc] initWithSource:script
                                                          injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                                       forMainFrameOnly:NO];
    [userContentController addUserScript:cookieInScript];
}

+ (void)addCookieOutScriptWithController:(WKUserContentController*)userContentController handler:(id<WKScriptMessageHandler>)handler
{
    WKUserScript *cookieOutScript = [[WKUserScript alloc] initWithSource:@"window.webkit.messageHandlers." Y_HANDLER_NAME @".postMessage(document.cookie);"
                                                           injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                                        forMainFrameOnly:NO];
    [userContentController addUserScript:cookieOutScript];

    [userContentController addScriptMessageHandler:handler
                                              name:Y_HANDLER_NAME];
}

+ (NSString *)javascriptStringWithCookie:(NSHTTPCookie*)cookie {

    NSString *string = [NSString stringWithFormat:@"%@=%@;domain=%@;path=%@",
                        cookie.name,
                        cookie.value,
                        cookie.domain,
                        cookie.path ?: @"/"];

    if (cookie.secure) {
        string = [string stringByAppendingString:@";secure=true"];
    }

    return string;
}

#pragma mark - WKNavigationDelegate

- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    if ([_yNavigationDelegate respondsToSelector:@selector(webView:decidePolicyForNavigationAction:decisionHandler:)]) {
        [_yNavigationDelegate webView:webView decidePolicyForNavigationAction:navigationAction decisionHandler:decisionHandler];
    } else {
        decisionHandler(WKNavigationActionPolicyAllow);
    }
}

- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction preferences:(WKWebpagePreferences *)preferences decisionHandler:(void (^)(WKNavigationActionPolicy, WKWebpagePreferences *))decisionHandler API_AVAILABLE(macos(10.15), ios(13.0)); {
    if ([_yNavigationDelegate respondsToSelector:@selector(webView:decidePolicyForNavigationAction:preferences:decisionHandler:)]) {
        [_yNavigationDelegate webView:webView decidePolicyForNavigationAction:navigationAction preferences:preferences decisionHandler:decisionHandler];
    } else if ([_yNavigationDelegate respondsToSelector:@selector(webView:decidePolicyForNavigationAction:decisionHandler:)]) {
        [_yNavigationDelegate webView:webView decidePolicyForNavigationAction:navigationAction decisionHandler:^(WKNavigationActionPolicy policy) {
            decisionHandler(policy, preferences);
        }];
    } else {
        decisionHandler(WKNavigationActionPolicyAllow, preferences);
    }
}

- (void)webView:(WKWebView *)webView decidePolicyForNavigationResponse:(WKNavigationResponse *)navigationResponse decisionHandler:(void (^)(WKNavigationResponsePolicy))decisionHandler {
    if ([_yNavigationDelegate respondsToSelector:@selector(webView:decidePolicyForNavigationResponse:decisionHandler:)]) {
        [_yNavigationDelegate webView:webView decidePolicyForNavigationResponse:navigationResponse decisionHandler:decisionHandler];
    } else {
        decisionHandler(WKNavigationResponsePolicyAllow);
    }
}

- (void)webView:(WKWebView *)webView didStartProvisionalNavigation:(null_unspecified WKNavigation *)navigation {
    if ([_yNavigationDelegate respondsToSelector:@selector(webView:didStartProvisionalNavigation:)]) {
        [_yNavigationDelegate webView:webView didStartProvisionalNavigation:navigation];
    }
}

- (void)webView:(WKWebView *)webView didReceiveServerRedirectForProvisionalNavigation:(null_unspecified WKNavigation *)navigation {
    if ([_yNavigationDelegate respondsToSelector:@selector(webView:didReceiveServerRedirectForProvisionalNavigation:)]) {
        [_yNavigationDelegate webView:webView didReceiveServerRedirectForProvisionalNavigation:navigation];
    }
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(null_unspecified WKNavigation *)navigation withError:(NSError *)error {
    if ([_yNavigationDelegate respondsToSelector:@selector(webView:didFailProvisionalNavigation:withError:)]) {
        [_yNavigationDelegate webView:webView didFailProvisionalNavigation:navigation withError:error];
    }
}

- (void)webView:(WKWebView *)webView didCommitNavigation:(null_unspecified WKNavigation *)navigation {
    if ([_yNavigationDelegate respondsToSelector:@selector(webView:didCommitNavigation:)]) {
        [_yNavigationDelegate webView:webView didCommitNavigation:navigation];
    }
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(null_unspecified WKNavigation *)navigation {
    [self saveCookies:^{
        if ([self.yNavigationDelegate respondsToSelector:@selector(webView:didFinishNavigation:)]) {
            [self.yNavigationDelegate webView:webView didFinishNavigation:navigation];
        }
    }];
}

- (void)webView:(WKWebView *)webView didFailNavigation:(null_unspecified WKNavigation *)navigation withError:(NSError *)error {
    if ([_yNavigationDelegate respondsToSelector:@selector(webView:didFailNavigation:withError:)]) {
        [_yNavigationDelegate webView:webView didFailNavigation:navigation withError:error];
    }
}

- (void)webView:(WKWebView *)webView didReceiveAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition disposition, NSURLCredential * _Nullable credential))completionHandler {
    if ([_yNavigationDelegate respondsToSelector:@selector(webView:didReceiveAuthenticationChallenge:completionHandler:)]) {
        [_yNavigationDelegate webView:webView didReceiveAuthenticationChallenge:challenge completionHandler:completionHandler];
    } else {
        completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
    }
}

- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView API_AVAILABLE(macos(10.11), ios(9.0)) {
    if ([_yNavigationDelegate respondsToSelector:@selector(webViewWebContentProcessDidTerminate:)]) {
        [_yNavigationDelegate webViewWebContentProcessDidTerminate:webView];
    }
}

@end
