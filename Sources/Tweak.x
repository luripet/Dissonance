#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#import "Fonts.h"
#import "LoaderConfig.h"
#import "Logger.h"
#import "Settings.h"
#import "Themes.h"
#import "Utils.h"

static NSURL         *source;
static NSString      *dissonancePatchesBundlePath;
static NSURL         *dissonanceDirectory;
static LoaderConfig  *loaderConfig;
static NSTimeInterval shakeStartTime = 0;
static BOOL           isShaking      = NO;
id                    gBridge        = nil;

%hook RCTCxxBridge

- (void)executeApplicationScript:(NSData *)script url:(NSURL *)url async:(BOOL)async
{
    if (![url.absoluteString containsString:@"main.jsbundle"])
    {
        return %orig;
    }

    gBridge = self;
    DissonanceLog(@"Stored bridge reference: %@", gBridge);

    NSBundle *dissonancePatchesBundle = [NSBundle bundleWithPath:dissonancePatchesBundlePath];
    if (!dissonancePatchesBundle)
    {
        DissonanceLog(@"Failed to load DissonancePatches bundle from path: %@", dissonancePatchesBundlePath);
        showErrorAlert(@"Loader Error",
                       @"Failed to initialize mod loader. Please reinstall the tweak.", nil);
        return %orig;
    }

    NSURL *patchPath = [dissonancePatchesBundle URLForResource:@"payload-base" withExtension:@"js"];
    if (!patchPath)
    {
        DissonanceLog(@"Failed to find payload-base.js in bundle");
        showErrorAlert(@"Loader Error",
                       @"Failed to initialize mod loader. Please reinstall the tweak.", nil);
        return %orig;
    }

    NSData *patchData = [NSData dataWithContentsOfURL:patchPath];
    DissonanceLog(@"Injecting loader");
    %orig(patchData, source, YES);

    __block NSData *bundle =
        [NSData dataWithContentsOfURL:[dissonanceDirectory URLByAppendingPathComponent:@"bundle.js"]];

    dispatch_group_t group = dispatch_group_create();
    dispatch_group_enter(group);

    NSURL *bundleUrl;
    if (loaderConfig.customLoadUrlEnabled && loaderConfig.customLoadUrl)
    {
        bundleUrl = loaderConfig.customLoadUrl;
        DissonanceLog(@"Using custom load URL: %@", bundleUrl.absoluteString);
    }
    else
    {
        bundleUrl = [NSURL
            URLWithString:@"https://raw.githubusercontent.com/luripet/DissonanceBuilds/main/dissonance.min.js"];
        DissonanceLog(@"Using default bundle URL: %@", bundleUrl.absoluteString);
    }

    NSMutableURLRequest *bundleRequest =
        [NSMutableURLRequest requestWithURL:bundleUrl
                                cachePolicy:NSURLRequestReloadIgnoringLocalAndRemoteCacheData
                            timeoutInterval:3.0];

    NSString *bundleEtag = [NSString
        stringWithContentsOfURL:[dissonanceDirectory URLByAppendingPathComponent:@"etag.txt"]
                       encoding:NSUTF8StringEncoding
                          error:nil];
    if (bundleEtag && bundle)
    {
        [bundleRequest setValue:bundleEtag forHTTPHeaderField:@"If-None-Match"];
    }

    NSURLSession *session = [NSURLSession
        sessionWithConfiguration:[NSURLSessionConfiguration defaultSessionConfiguration]];
    [[session
        dataTaskWithRequest:bundleRequest
          completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
              if ([response isKindOfClass:[NSHTTPURLResponse class]])
              {
                  NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *) response;
                  if (httpResponse.statusCode == 200)
                  {
                      bundle = data;
                      [bundle
                          writeToURL:[dissonanceDirectory URLByAppendingPathComponent:@"bundle.js"]
                          atomically:YES];

                      NSString *etag = [httpResponse.allHeaderFields objectForKey:@"Etag"];
                      if (etag)
                      {
                          [etag
                              writeToURL:[dissonanceDirectory URLByAppendingPathComponent:@"etag.txt"]
                              atomically:YES
                                encoding:NSUTF8StringEncoding
                                   error:nil];
                      }
                  }
              }
              dispatch_group_leave(group);
          }] resume];

    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);

    NSData *themeData =
        [NSData dataWithContentsOfURL:[dissonanceDirectory
                                          URLByAppendingPathComponent:@"current-theme.json"]];
    if (themeData)
    {
        NSError      *jsonError;
        NSDictionary *themeDict = [NSJSONSerialization JSONObjectWithData:themeData
                                                                  options:0
                                                                    error:&jsonError];
        if (!jsonError)
        {
            DissonanceLog(@"Loading theme data...");
            if (themeDict[@"data"])
            {
                NSDictionary *data = themeDict[@"data"];
                if (data[@"semanticColors"] && data[@"rawColors"])
                {
                    DissonanceLog(@"Initializing theme colors from theme data");
                    initializeThemeColors(data[@"semanticColors"], data[@"rawColors"]);
                }
            }

            NSString *jsCode =
                [NSString stringWithFormat:@"globalThis.__DISSONANCE_LOADER__.storedTheme=%@",
                                           [[NSString alloc] initWithData:themeData
                                                                 encoding:NSUTF8StringEncoding]];
            %orig([jsCode dataUsingEncoding:NSUTF8StringEncoding], source, async);
        }
        else
        {
            DissonanceLog(@"Error parsing theme JSON: %@", jsonError);
        }
    }
    else
    {
        DissonanceLog(@"No theme data found at path: %@",
                 [dissonanceDirectory URLByAppendingPathComponent:@"current-theme.json"]);
    }

    NSData *fontData = [NSData
        dataWithContentsOfURL:[dissonanceDirectory URLByAppendingPathComponent:@"fonts.json"]];
    if (fontData)
    {
        NSError      *jsonError;
        NSDictionary *fontDict = [NSJSONSerialization JSONObjectWithData:fontData
                                                                 options:0
                                                                   error:&jsonError];
        if (!jsonError && fontDict[@"main"])
        {
            DissonanceLog(@"Found font configuration, applying...");
            patchFonts(fontDict[@"main"], fontDict[@"name"]);
        }
    }

    if (bundle)
    {
        DissonanceLog(@"Executing JS bundle");
        %orig(bundle, source, async);
    }

    NSURL *preloadsDirectory = [dissonanceDirectory URLByAppendingPathComponent:@"preloads"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:preloadsDirectory.path])
    {
        NSError *error = nil;
        NSArray *contents =
            [[NSFileManager defaultManager] contentsOfDirectoryAtURL:preloadsDirectory
                                          includingPropertiesForKeys:nil
                                                             options:0
                                                               error:&error];
        if (!error)
        {
            for (NSURL *fileURL in contents)
            {
                if ([[fileURL pathExtension] isEqualToString:@"js"])
                {
                    DissonanceLog(@"Executing preload JS file %@", fileURL.absoluteString);
                    NSData *data = [NSData dataWithContentsOfURL:fileURL];
                    if (data)
                    {
                        %orig(data, source, async);
                    }
                }
            }
        }
        else
        {
            DissonanceLog(@"Error reading contents of preloads directory");
        }
    }

    %orig(script, url, async);
}

%end

%hook UIWindow

- (void)motionBegan:(UIEventSubtype)motion withEvent:(UIEvent *)event
{
    if (motion == UIEventSubtypeMotionShake)
    {
        isShaking      = YES;
        shakeStartTime = [[NSDate date] timeIntervalSince1970];
    }
    %orig;
}

- (void)motionEnded:(UIEventSubtype)motion withEvent:(UIEvent *)event
{
    if (motion == UIEventSubtypeMotionShake && isShaking)
    {
        NSTimeInterval currentTime   = [[NSDate date] timeIntervalSince1970];
        NSTimeInterval shakeDuration = currentTime - shakeStartTime;

        if (shakeDuration >= 0.5 && shakeDuration <= 2.0)
        {
            dispatch_async(dispatch_get_main_queue(), ^{ showSettingsSheet(); });
        }
        isShaking = NO;
    }
    %orig;
}

%end

%ctor
{
    @autoreleasepool
    {
        source = [NSURL URLWithString:@"dissonance"];

        NSString *install_prefix = @"/var/jb";
        isJailbroken             = [[NSFileManager defaultManager] fileExistsAtPath:install_prefix];

        NSString *bundlePath =
            [NSString stringWithFormat:@"%@/Library/Application Support/DissonanceResources.bundle",
                                       install_prefix];
        DissonanceLog(@"Is jailbroken: %d", isJailbroken);
        DissonanceLog(@"Bundle path for jailbroken: %@", bundlePath);

        NSString *jailedPath = [[NSBundle mainBundle].bundleURL.path
            stringByAppendingPathComponent:@"DissonanceResources.bundle"];
        DissonanceLog(@"Bundle path for jailed: %@", jailedPath);

        dissonancePatchesBundlePath = isJailbroken ? bundlePath : jailedPath;
        DissonanceLog(@"Selected bundle path: %@", dissonancePatchesBundlePath);

        BOOL bundleExists =
            [[NSFileManager defaultManager] fileExistsAtPath:dissonancePatchesBundlePath];
        DissonanceLog(@"Bundle exists at path: %d", bundleExists);

        NSError *error = nil;
        NSArray *bundleContents =
            [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dissonancePatchesBundlePath
                                                                error:&error];
        if (error)
        {
            DissonanceLog(@"Error listing bundle contents: %@", error);
        }
        else
        {
            DissonanceLog(@"Bundle contents: %@", bundleContents);
        }

        dissonanceDirectory = getDissonanceDirectory();
        loaderConfig      = [[LoaderConfig alloc] init];
        [loaderConfig loadConfig];

        %init;
    }
}
