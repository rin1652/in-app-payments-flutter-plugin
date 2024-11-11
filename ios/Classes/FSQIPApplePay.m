/*
 Copyright 2018 Square Inc.
 
 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at
 
 http://www.apache.org/licenses/LICENSE-2.0
 
 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
*/

#import "FSQIPApplePay.h"
#import "FSQIPErrorUtilities.h"
#import "Converters/SQIPCardDetails+FSQIPAdditions.h"

API_AVAILABLE(ios(11.0))
typedef void (^CompletionHandler)(PKPaymentAuthorizationResult *_Nonnull);


API_AVAILABLE(ios(11.0))
@interface FSQIPApplePay ()

@property (strong, readwrite) FlutterMethodChannel *channel;
@property (strong, readwrite) NSString *applePayMerchantId;
@property (strong, readwrite) CompletionHandler completionHandler;

@end

// flutter plugin debug error codes
static NSString *const FSQIPApplePayNotInitialized = @"fl_apple_pay_not_initialized";
static NSString *const FSQIPApplePayNotSupported = @"fl_apple_pay_not_supported";

// flutter plugin debug messages
static NSString *const FSQIPMessageApplePayNotInitialized = @"Apple Pay must be initialized with an Apple merchant ID.";
static NSString *const FSQIPMessageApplePayNotSupported = @"This device does not have any supported Apple Pay cards. Please check `canUseApplePay` prior to requesting a nonce.";


@implementation FSQIPApplePay

- (void)initWithMethodChannel:(FlutterMethodChannel *)channel
{
    self.channel = channel;
}

- (void)initializeApplePay:(FlutterResult)result merchantId:(NSString *)merchantId
{
    self.applePayMerchantId = merchantId;
    result(nil);
}

- (void)canUseApplePay:(FlutterResult)result
{
    result(@(SQIPInAppPaymentsSDK.canUseApplePay));
}

- (void)requestApplePayNonce:(FlutterResult)result
                 countryCode:(NSString *)countryCode
                currencyCode:(NSString *)currencyCode
                summaryLabel:(NSString *)summaryLabel
                       price:(NSString *)price
                 paymentType:(NSString *)paymentType
{
    if (!self.applePayMerchantId) {
        result([FlutterError errorWithCode:FlutterInAppPaymentsUsageError
                                   message:[FSQIPErrorUtilities pluginErrorMessageFromErrorCode:FSQIPApplePayNotInitialized]
                                   details:[FSQIPErrorUtilities debugErrorObject:FSQIPApplePayNotInitialized debugMessage:FSQIPMessageApplePayNotInitialized]]);
        return;
    }
    if (!SQIPInAppPaymentsSDK.canUseApplePay) {
        result([FlutterError errorWithCode:FlutterInAppPaymentsUsageError
                                   message:[FSQIPErrorUtilities pluginErrorMessageFromErrorCode:FSQIPApplePayNotSupported]
                                   details:[FSQIPErrorUtilities debugErrorObject:FSQIPApplePayNotSupported debugMessage:FSQIPMessageApplePayNotSupported]]);
        return;
    }
    PKPaymentRequest *paymentRequest =
        [PKPaymentRequest squarePaymentRequestWithMerchantIdentifier:self.applePayMerchantId
                                                         countryCode:countryCode
                                                        currencyCode:currencyCode];
    if ([paymentType isEqual: @"PENDING"]) {
        paymentRequest.paymentSummaryItems = @[
           [PKPaymentSummaryItem summaryItemWithLabel:summaryLabel
                                               amount:[NSDecimalNumber decimalNumberWithString:price]
                                                 type:PKPaymentSummaryItemTypePending]
        ];
    } else {
        paymentRequest.paymentSummaryItems = @[
           [PKPaymentSummaryItem summaryItemWithLabel:summaryLabel
                                               amount:[NSDecimalNumber decimalNumberWithString:price]
                                                 type:PKPaymentSummaryItemTypeFinal]
        ];
    }

    PKPaymentAuthorizationViewController *paymentAuthorizationViewController =
        [[PKPaymentAuthorizationViewController alloc] initWithPaymentRequest:paymentRequest];

    paymentAuthorizationViewController.delegate = self;
    UIViewController *rootViewController = UIApplication.sharedApplication.keyWindow.rootViewController;
    [rootViewController presentViewController:paymentAuthorizationViewController animated:YES completion:nil];
    result(nil);
}

- (void)completeApplePayAuthorization:(FlutterResult)result
                            isSuccess:(BOOL)isSuccess
                         errorMessage:(NSString *__nullable)errorMessage
{
    if (self.completionHandler != nil) {
        if (isSuccess) {
            PKPaymentAuthorizationResult *authResult =[[PKPaymentAuthorizationResult alloc] initWithStatus:PKPaymentAuthorizationStatusSuccess errors:nil];
            self.completionHandler(authResult);
        } else {
            NSDictionary *userInfo = errorMessage == nil || errorMessage.length == 0 ? nil : @{NSLocalizedDescriptionKey : errorMessage };
            NSError *error = [NSError errorWithDomain:NSGlobalDomain
                                                 code:FSQIPApplePayErrorCode
                                             userInfo:userInfo];
            if (@available(iOS 11.0, *)) {
                PKPaymentAuthorizationResult *authResult = [[PKPaymentAuthorizationResult alloc] initWithStatus:PKPaymentAuthorizationStatusFailure errors:@[ error ]];
                self.completionHandler(authResult);
            } else {
                // This should never happen as we require target to be 11.0 or above
                NSAssert(false, @"No Apple Pay support for iOS 10 or below.");
            }
        }
        self.completionHandler = nil;
    }

    result(nil);
}

#pragma mark - PKPaymentAuthorizationViewControllerDelegate
- (void)paymentAuthorizationViewController:(PKPaymentAuthorizationViewController *)controller
                       didAuthorizePayment:(PKPayment *)payment
                                   handler:(CompletionHandler)completion API_AVAILABLE(ios(11.0));
{
    SQIPApplePayNonceRequest *nonceRequest = [[SQIPApplePayNonceRequest alloc] initWithPayment:payment];
    self.completionHandler = completion;

    [nonceRequest performWithCompletionHandler:^(SQIPCardDetails *_Nullable result, NSError *_Nullable error) {
        if (error) {
            NSString *debugCode = error.userInfo[SQIPErrorDebugCodeKey];
            NSString *debugMessage = error.userInfo[SQIPErrorDebugMessageKey];
            [self.channel invokeMethod:@"onApplePayNonceRequestFailure"
                             arguments:[FSQIPErrorUtilities callbackErrorObject:FlutterInAppPaymentsUsageError
                                                                        message:error.localizedDescription
                                                                      debugCode:debugCode
                                                                   debugMessage:debugMessage]];
        } else {
            // if error is not nil, result must be valid
            [self.channel invokeMethod:@"onApplePayNonceRequestSuccess" arguments:[result jsonDictionary]];
        }
    }];
}

- (void)paymentAuthorizationViewControllerDidFinish:(nonnull PKPaymentAuthorizationViewController *)controller;
{
    UIViewController *rootViewController = UIApplication.sharedApplication.keyWindow.rootViewController;
    if ([rootViewController isKindOfClass:[UINavigationController class]]) {
        [rootViewController.navigationController popViewControllerAnimated:YES];
    } else {
        [rootViewController dismissViewControllerAnimated:YES completion:nil];
    }
    [self.channel invokeMethod:@"onApplePayComplete" arguments:nil];
}

@end
