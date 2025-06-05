//
//  NotificationService.m
//  AppNotiService
//
//  Created by Sergei Golov on 03.06.25.
//

#import "NotificationService.h"

@interface NotificationService ()

@property (nonatomic, strong) void (^contentHandler)(UNNotificationContent *contentToDeliver);
@property (nonatomic, strong) UNMutableNotificationContent *bestAttemptContent;

@end

@implementation NotificationService

- (void)didReceiveNotificationRequest:(UNNotificationRequest *)request withContentHandler:(void (^)(UNNotificationContent * _Nonnull))contentHandler {
    self.contentHandler = contentHandler;
    self.bestAttemptContent = [request.content mutableCopy];
    
    NSLog(@"[Extension] didReceiveNotificationRequest called with userInfo: %@", request.content.userInfo);
    
    // Confirm the message if messageId is present
    NSString *messageId = request.content.userInfo[@"messageId"];
    if (messageId && [messageId isKindOfClass:[NSString class]]) {
        NSLog(@"[Extension] Confirming message with ID: %@", messageId);
        [self confirmMessage:messageId withUserInfo:request.content.userInfo];
    } else {
        NSLog(@"[Extension] No messageId found for confirmation");
    }
    
    NSLog(@"[Extension] Content processed, calling contentHandler");
    self.contentHandler(self.bestAttemptContent);
}

- (void)serviceExtensionTimeWillExpire {
    // Called just before the extension will be terminated by the system.
    // Use this as an opportunity to deliver your "best attempt" at modified content, otherwise the original push payload will be used.
    self.contentHandler(self.bestAttemptContent);
}

// MARK: - Message Confirmation

- (void)confirmMessage:(NSString *)messageId withUserInfo:(NSDictionary *)userInfo {
    NSLog(@"[Extension Confirm] Starting message confirmation for messageId: %@", messageId);
    
    // Get clientToken from shared UserDefaults
    NSUserDefaults *sharedDefaults = [[NSUserDefaults alloc] initWithSuiteName:@"group.pushed.example"];
    NSString *clientToken = [sharedDefaults stringForKey:@"clientToken"];
    
    // Fallback to file if UserDefaults fails
    if (!clientToken || clientToken.length == 0) {
        NSURL *sharedURL = [[NSFileManager defaultManager] containerURLForSecurityApplicationGroupIdentifier:@"group.pushed.example"];
        if (sharedURL) {
            NSURL *tokenFileURL = [sharedURL URLByAppendingPathComponent:@"clientToken.txt"];
            NSError *error;
            clientToken = [NSString stringWithContentsOfURL:tokenFileURL encoding:NSUTF8StringEncoding error:&error];
            if (error) {
                NSLog(@"[Extension Confirm] ERROR: Could not read clientToken from file: %@", error.localizedDescription);
            }
        }
    }
    
    if (!clientToken || clientToken.length == 0) {
        NSLog(@"[Extension Confirm] ERROR: clientToken is empty, cannot confirm message");
        return;
    }
    
    NSLog(@"[Extension Confirm] Using clientToken: %@...", [clientToken substringToIndex:MIN(10, clientToken.length)]);
    
    // Create Basic Auth: clientToken:messageId
    NSString *credentials = [NSString stringWithFormat:@"%@:%@", clientToken, messageId];
    NSData *credentialsData = [credentials dataUsingEncoding:NSUTF8StringEncoding];
    NSString *basicAuth = [NSString stringWithFormat:@"Basic %@", [credentialsData base64EncodedStringWithOptions:0]];
    
    // Create URL and request
    NSString *urlString = @"https://pub.pushed.ru/v1/confirm?transportKind=Apns";
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        NSLog(@"[Extension Confirm] ERROR: Invalid URL: %@", urlString);
        return;
    }
    
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    [request addValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request addValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [request addValue:basicAuth forHTTPHeaderField:@"Authorization"];
    
    NSLog(@"[Extension Confirm] Sending confirmation request to: %@", urlString);
    NSLog(@"[Extension Confirm] Authorization header created for messageId: %@", messageId);
    
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            NSLog(@"[Extension Confirm] Request error: %@", error.localizedDescription);
            return;
        }
        
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        if (!httpResponse) {
            NSLog(@"[Extension Confirm] ERROR: No HTTPURLResponse");
            return;
        }
        
        NSInteger status = httpResponse.statusCode;
        NSString *responseBody = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"<no body>";
        
        if (status >= 200 && status < 300) {
            NSLog(@"[Extension Confirm] SUCCESS - Status: %ld, Body: %@", (long)status, responseBody);
        } else {
            NSLog(@"[Extension Confirm] ERROR - Status: %ld, Body: %@", (long)status, responseBody);
        }
    }];
    
    [task resume];
    NSLog(@"[Extension Confirm] Confirmation request sent for messageId: %@", messageId);
}

@end
