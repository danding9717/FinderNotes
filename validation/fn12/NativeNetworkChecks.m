#import <AppKit/AppKit.h>
#import <Sparkle/Sparkle.h>

// This driver records callbacks from the real Sparkle updater. It has no installer.
// Every install-ready callback is explicitly skipped, even for an unexpected valid package.
@interface FN12NetworkDriver : NSObject <SPUUserDriver, SPUUpdaterDelegate>
@property NSString *testCase;
@property SPUUpdater *updater;
@property NSMutableArray<NSString *> *events;
@property NSMutableArray<NSDictionary *> *errors;
@property BOOL finished;
@property BOOL updaterBusyAfterCheck;
@property BOOL updaterReadyBeforeCheck;
@property BOOL downloadCancelled;
@property NSInteger noUpdateReason;
@property uint64_t downloadedBytes;
@property (copy) void (^cancelDownload)(void);
@end

@implementation FN12NetworkDriver
- (void)event:(NSString *)event { [self.events addObject:event]; }
- (void)recordError:(NSError *)error {
    for (NSError *current = error; current != nil; current = current.userInfo[NSUnderlyingErrorKey]) {
        [self.errors addObject:@{@"domain": current.domain, @"code": @(current.code),
                                @"description": current.localizedDescription ?: @"",
                                @"reason": current.localizedFailureReason ?: @""}];
    }
}
- (void)showUpdatePermissionRequest:(SPUUpdatePermissionRequest *)request reply:(void (^)(SUUpdatePermissionResponse *))reply {
    [self event:@"unexpected-permission-request"];
    reply([[SUUpdatePermissionResponse alloc] initWithAutomaticUpdateChecks:NO sendSystemProfile:NO]);
}
- (void)showUserInitiatedUpdateCheckWithCancellation:(void (^)(void))cancellation { [self event:@"check-started"]; }
- (void)showUpdateFoundWithAppcastItem:(SUAppcastItem *)item state:(SPUUserUpdateState *)state reply:(void (^)(SPUUserUpdateChoice))reply {
    [self event:[@"found-version-" stringByAppendingString:item.versionString]];
    BOOL invalidArchive = [self.testCase isEqualToString:@"bad-signature"] || [self.testCase isEqualToString:@"corrupt"];
    BOOL cancelDownload = [self.testCase isEqualToString:@"slow-download"];
    reply((invalidArchive || cancelDownload) ? SPUUserUpdateChoiceInstall : SPUUserUpdateChoiceDismiss);
}
- (void)showUpdateReleaseNotesWithDownloadData:(SPUDownloadData *)data { [self event:@"release-notes"]; }
- (void)showUpdateReleaseNotesFailedToDownloadWithError:(NSError *)error { [self event:@"release-notes-error"]; [self recordError:error]; }
- (void)showUpdateNotFoundWithError:(NSError *)error acknowledgement:(void (^)(void))acknowledgement {
    [self event:@"no-update"]; self.noUpdateReason = [error.userInfo[SPUNoUpdateFoundReasonKey] integerValue];
    [self recordError:error]; acknowledgement();
}
- (void)showUpdaterError:(NSError *)error acknowledgement:(void (^)(void))acknowledgement {
    [self event:@"updater-error"]; [self recordError:error]; acknowledgement();
}
- (void)showDownloadInitiatedWithCancellation:(void (^)(void))cancellation {
    [self event:@"download-started"]; self.cancelDownload = cancellation;
}
- (void)showDownloadDidReceiveExpectedContentLength:(uint64_t)length { [self event:@"download-length"]; }
- (void)showDownloadDidReceiveDataOfLength:(uint64_t)length {
    self.downloadedBytes += length;
    if ([self.testCase isEqualToString:@"slow-download"] && !self.downloadCancelled) {
        self.downloadCancelled = YES;
        [self event:@"download-cancelled"];
        self.cancelDownload();
    }
}
- (void)showDownloadDidStartExtractingUpdate { [self event:@"preparing-extraction"]; }
- (void)showExtractionReceivedProgress:(double)progress { [self event:@"extraction-progress"]; }
- (void)showReadyToInstallAndRelaunch:(void (^)(SPUUserUpdateChoice))reply {
    [self event:@"unexpected-ready-to-install-SKIPPED"]; reply(SPUUserUpdateChoiceSkip);
}
- (void)showInstallingUpdateWithApplicationTerminated:(BOOL)terminated retryTerminatingApplication:(void (^)(void))retry {
    [self event:@"unexpected-installing-update"];
}
- (void)showUpdateInstalledAndRelaunched:(BOOL)relaunched acknowledgement:(void (^)(void))acknowledgement {
    [self event:@"unexpected-installed-update"]; acknowledgement();
}
- (void)dismissUpdateInstallation { [self event:@"dismissed"]; }
- (void)updater:(SPUUpdater *)updater didFinishUpdateCycleForUpdateCheck:(SPUUpdateCheck)check error:(NSError *)error {
    [self event:@"cycle-finished"]; self.finished = YES;
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2) { fprintf(stderr, "Provide one fixture case.\n"); return 2; }
        [NSApplication sharedApplication]; [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        FN12NetworkDriver *driver = [FN12NetworkDriver new];
        driver.testCase = [NSString stringWithUTF8String:argv[1]];
        driver.events = [NSMutableArray array]; driver.errors = [NSMutableArray array];
        driver.updater = [[SPUUpdater alloc] initWithHostBundle:NSBundle.mainBundle applicationBundle:NSBundle.mainBundle userDriver:driver delegate:driver];
        NSError *startError;
        if (![driver.updater startUpdater:&startError]) {
            fprintf(stderr, "Sparkle start failed: %s\n", startError.description.UTF8String); return 2;
        }
        driver.updaterReadyBeforeCheck = driver.updater.canCheckForUpdates;
        NSDate *began = [NSDate date];
        [driver.updater checkForUpdates];
        driver.updaterBusyAfterCheck = !driver.updater.canCheckForUpdates;
        while (!driver.finished && -began.timeIntervalSinceNow < 75.0) {
            [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
        }
        NSMutableDictionary *result = [@{@"case": driver.testCase, @"finished": @(driver.finished),
            @"events": driver.events, @"errors": driver.errors, @"downloadedBytes": @(driver.downloadedBytes),
            @"readyBeforeCheck": @(driver.updaterReadyBeforeCheck), @"busyAfterCheck": @(driver.updaterBusyAfterCheck),
            @"readyAfterCheck": @(driver.updater.canCheckForUpdates), @"noUpdateReason": @(driver.noUpdateReason),
            @"elapsed": @(-began.timeIntervalSinceNow)} mutableCopy];
        BOOL found = [driver.events containsObject:@"found-version-13"];
        BOOL noUpdate = [driver.events containsObject:@"no-update"];
        BOOL error = [driver.events containsObject:@"updater-error"];
        BOOL forbidden = [driver.events containsObject:@"unexpected-ready-to-install-SKIPPED"] ||
            [driver.events containsObject:@"unexpected-installing-update"] || [driver.events containsObject:@"unexpected-installed-update"];
        BOOL signatureFailure = NO;
        for (NSDictionary *entry in driver.errors) {
            signatureFailure |= [entry[@"domain"] isEqualToString:SUSparkleErrorDomain] &&
                [entry[@"code"] integerValue] == SUValidationError && [entry[@"description"] containsString:@"EdDSA signature does not match"];
        }
        BOOL passed = driver.finished && driver.updaterReadyBeforeCheck && driver.updaterBusyAfterCheck && driver.updater.canCheckForUpdates && !forbidden;
        if ([driver.testCase isEqualToString:@"update"]) passed &= found && !noUpdate && !error;
        else if ([driver.testCase isEqualToString:@"latest"]) passed &= noUpdate && !found && !error && driver.noUpdateReason == SPUNoUpdateFoundReasonOnLatestVersion;
        else if ([driver.testCase isEqualToString:@"local-ahead"]) passed &= noUpdate && !found && !error && driver.noUpdateReason == SPUNoUpdateFoundReasonOnNewerThanLatestVersion;
        else if ([driver.testCase isEqualToString:@"slow-download"]) passed &= found && driver.downloadCancelled && driver.downloadedBytes > 0 && !error;
        else if ([driver.testCase isEqualToString:@"bad-signature"] || [driver.testCase isEqualToString:@"corrupt"]) passed &= found && error && signatureFailure && !noUpdate;
        else passed &= error && !found && !noUpdate;
        result[@"passed"] = @(passed);
        NSData *json = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil];
        fwrite(json.bytes, 1, json.length, stdout); putchar('\n');
        return passed ? 0 : 1;
    }
}
