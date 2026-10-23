// MIT. BatteryKeeper's macOS 27 charge actuator. The CLI owns all charge thresholds.
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/wait.h>
#include <unistd.h>

static NSString *const Domain = @"com.apple.powerd.charging";
static NSString *const Reason = @"BatteryKeeper";
static const char *const StorePath = "/var/db/batterykeeper-charge-control";
static const double ReloadInterval = 11.0;
static int storeFD = -1;
static volatile sig_atomic_t stopping;
static CFTypeRef (*UIDCreate)(CFAllocatorRef, uint32_t);
static uint32_t (*UIDValue)(CFTypeRef);
static CFTypeID (*UIDType)(void);

@interface NSObject (NativeChargeClient)
- (instancetype)initWithClientName:(NSString *)name;
- (BOOL)isMCLSupported;
- (NSUInteger)isMCLCurrentlyEnabled:(NSError **)error;
- (unsigned char)getMCLLimitWithError:(NSError **)error;
- (BOOL)disableMCL:(NSError **)error;
- (BOOL)enableMCL:(NSError **)error;
@end

static void require(BOOL condition, NSString *message) {
    if (!condition) @throw [NSException exceptionWithName:@"ChargeControlError" reason:message userInfo:nil];
}
static void stopSignal(int value) { stopping = value; }
static double now(void) { return NSDate.date.timeIntervalSince1970; }
static double uptime(void) { return NSProcessInfo.processInfo.systemUptime; }
static void waitUntil(double deadline) {
    while (uptime() < deadline) usleep(50000);
}
static NSString *bootUUID(void) {
    char buffer[128] = {0}; size_t length = sizeof(buffer);
    require(sysctlbyname("kern.bootsessionuuid", buffer, &length, NULL, 0) == 0, @"Cannot read boot session");
    return [NSString stringWithUTF8String:buffer];
}
static BOOL validMode(id value) {
    return [value isKindOfClass:NSString.class] && [@[@"on", @"off", @"reset"] containsObject:value];
}
static void initializeUIDs(void) {
    UIDCreate = dlsym(RTLD_DEFAULT, "_CFKeyedArchiverUIDCreate");
    UIDValue = dlsym(RTLD_DEFAULT, "_CFKeyedArchiverUIDGetValue");
    UIDType = dlsym(RTLD_DEFAULT, "_CFKeyedArchiverUIDGetTypeID");
    require(UIDCreate && UIDValue && UIDType, @"Native policy archive support is unavailable");
}
static id uid(NSUInteger index) {
    require(index <= UINT32_MAX, @"Policy archive is too large");
    return CFBridgingRelease(UIDCreate(kCFAllocatorDefault, (uint32_t)index));
}
static NSUInteger uidIndex(id ref) {
    require(ref && CFGetTypeID((__bridge CFTypeRef)ref) == UIDType(), @"Invalid policy archive reference");
    return UIDValue((__bridge CFTypeRef)ref);
}
static id resolve(NSArray *objects, id ref) {
    NSUInteger index = uidIndex(ref);
    require(index < objects.count, @"Policy archive reference is out of bounds");
    return objects[index];
}
static NSData *encode(id value) {
    NSError *error = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:value format:NSPropertyListBinaryFormat_v1_0 options:0 error:&error];
    require(data != nil, error.localizedDescription ?: @"Cannot encode state");
    return data;
}
static NSMutableDictionary *decodeDictionary(NSData *data) {
    NSError *error = nil;
    id result = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListMutableContainersAndLeaves format:NULL error:&error];
    require([result isKindOfClass:NSMutableDictionary.class], error.localizedDescription ?: @"Invalid property list");
    return result;
}
static void checkFile(int fd, BOOL directory) {
    struct stat info;
    require(fstat(fd, &info) == 0 && info.st_uid == 0 && !(info.st_mode & 0077)
        && (directory ? S_ISDIR(info.st_mode) : (S_ISREG(info.st_mode) && info.st_nlink == 1)),
        @"Unsafe charge-control state ownership, permissions, or file type");
}
static void openStore(void) {
    require(geteuid() == 0, @"Charge control requires administrator privileges");
    umask(0077);
    require(mkdir(StorePath, 0700) == 0 || errno == EEXIST, @"Cannot create charge-control state directory");
    storeFD = open(StorePath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    require(storeFD >= 0, @"Cannot open charge-control state directory");
    checkFile(storeFD, YES);
}
static int lockFile(const char *name) {
    int fd = openat(storeFD, name, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0600);
    require(fd >= 0, @"Cannot open charge-control lock");
    checkFile(fd, NO);
    return fd;
}
static NSMutableDictionary *readFile(const char *name) {
    int fd = openat(storeFD, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0 && errno == ENOENT) return nil;
    require(fd >= 0, @"Cannot read charge-control state");
    @try {
        checkFile(fd, NO);
        NSMutableData *data = [NSMutableData data]; uint8_t buffer[4096];
        for (;;) {
            ssize_t count = read(fd, buffer, sizeof(buffer));
            if (count < 0 && errno == EINTR) continue;
            require(count >= 0, @"Cannot read charge-control state");
            if (count == 0) break;
            [data appendBytes:buffer length:(NSUInteger)count];
            require(data.length <= 4 * 1024 * 1024, @"Charge-control state exceeds size limit");
        }
        return decodeDictionary(data);
    } @finally { close(fd); }
}
static void writeFile(const char *name, NSDictionary *value) {
    NSData *data = encode(value);
    NSString *temporary = [@".write-" stringByAppendingString:NSUUID.UUID.UUIDString];
    int fd = openat(storeFD, temporary.UTF8String, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    require(fd >= 0, @"Cannot create charge-control state file");
    @try {
        const uint8_t *bytes = data.bytes; NSUInteger remaining = data.length;
        while (remaining) {
            ssize_t count = write(fd, bytes, remaining);
            if (count < 0 && errno == EINTR) continue;
            require(count > 0, @"Cannot persist charge-control state");
            bytes += count; remaining -= (NSUInteger)count;
        }
        require(fsync(fd) == 0, @"Cannot sync charge-control state");
        require(renameat(storeFD, temporary.UTF8String, storeFD, name) == 0, @"Cannot commit charge-control state");
        require(fsync(storeFD) == 0, @"Cannot sync charge-control directory");
    } @finally { close(fd); unlinkat(storeFD, temporary.UTF8String, 0); }
}

static NSString *runTool(const char *path, NSArray<NSString *> *arguments, double timeout) {
    int pipes[2]; require(pipe(pipes) == 0, @"Cannot create process pipe");
    fcntl(pipes[0], F_SETFD, FD_CLOEXEC); fcntl(pipes[1], F_SETFD, FD_CLOEXEC);
    posix_spawn_file_actions_t actions; posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, pipes[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, pipes[1], STDERR_FILENO);
    posix_spawn_file_actions_addclose(&actions, pipes[0]);
    char *argv[8] = {(char *)path, NULL};
    require(arguments.count < 7, @"Invalid internal process arguments");
    for (NSUInteger index = 0; index < arguments.count; index++) argv[index + 1] = (char *)arguments[index].UTF8String;
    char *environment[] = {"PATH=/usr/bin:/bin:/usr/sbin:/sbin", "LANG=C", "LC_ALL=C", NULL};
    pid_t child = -1;
    int error = posix_spawn(&child, path, &actions, NULL, argv, environment);
    posix_spawn_file_actions_destroy(&actions); close(pipes[1]);
    if (error) { close(pipes[0]); require(NO, @"Cannot launch system power tool"); }
    fcntl(pipes[0], F_SETFL, O_NONBLOCK);
    NSMutableData *output = [NSMutableData data]; double deadline = NSProcessInfo.processInfo.systemUptime + timeout;
    int status = 0; BOOL exited = NO;
    @try {
        for (;;) {
            uint8_t buffer[4096]; ssize_t count;
            while ((count = read(pipes[0], buffer, sizeof(buffer))) > 0) {
                [output appendBytes:buffer length:(NSUInteger)count];
                require(output.length < 1024 * 1024, @"System power tool output is too large");
            }
            if (!exited) {
                pid_t result = waitpid(child, &status, WNOHANG);
                require(result >= 0 || errno == EINTR, @"Cannot wait for system power tool");
                exited = result == child;
            }
            if (exited && count == 0) break;
            require(NSProcessInfo.processInfo.systemUptime < deadline, @"System power tool timed out");
            usleep(10000);
        }
        NSString *text = [[NSString alloc] initWithData:output encoding:NSUTF8StringEncoding];
        require(WIFEXITED(status) && WEXITSTATUS(status) == 0, text ?: @"System power tool failed");
        require(text != nil, @"Invalid system power tool output");
        return text;
    } @finally {
        if (!exited) { kill(child, SIGKILL); while (waitpid(child, &status, 0) < 0 && errno == EINTR) {} }
        close(pipes[0]);
    }
}
static NSArray *parseLimits(NSString *text) {
    if ([[text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
            isEqual:@"No battery level limits set"]) return @[];
    NSRange start = [text rangeOfString:@"("];
    require(start.location != NSNotFound, @"System charge-limit status is unavailable");
    NSData *data = [[text substringFromIndex:start.location] dataUsingEncoding:NSUTF8StringEncoding];
    id values = [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:NULL];
    require([values isKindOfClass:NSArray.class], @"Unrecognized system charge-limit status");
    for (id item in values) {
        require([item isKindOfClass:NSDictionary.class], @"Invalid system charge-limit entry");
        require([item[@"chargeSocLimitReason"] isKindOfClass:NSString.class], @"Invalid system charge-limit reason");
        for (NSString *key in @[@"chargeSocLimitOwner", @"chargeSocLimitSoc", @"chargeSocLimitDrain",
                @"chargeSocLimitNoChargeToFull", @"chargeSocLimitIsEOC", @"Terminated"]) {
            id value = item[key];
            require([value isKindOfClass:NSString.class] || [value isKindOfClass:NSNumber.class], @"Missing system charge-limit field");
            NSString *number = [value description];
            require(number.length > 0 && [number rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location == NSNotFound,
                @"Invalid system charge-limit number");
        }
    }
    return values;
}
static NSArray *systemLimits(double timeout) {
    return parseLimits(runTool("/usr/bin/pmset", @[@"-g", @"battlimit"], timeout));
}
static NSDictionary *readDomain(void) {
    require(CFPreferencesSynchronize((__bridge CFStringRef)Domain, kCFPreferencesAnyUser, kCFPreferencesCurrentHost), @"Cannot synchronize native charge policies");
    CFDictionaryRef value = CFPreferencesCopyMultiple(NULL, (__bridge CFStringRef)Domain, kCFPreferencesAnyUser, kCFPreferencesCurrentHost);
    return value ? CFBridgingRelease(value) : @{};
}
static NSMutableDictionary *emptyArchive(void) {
    return [@{@"$archiver":@"NSKeyedArchiver", @"$version":@100000,
        @"$top":[@{@"root":uid(1)} mutableCopy], @"$objects":[@[@"$null",
            [@{@"NS.objects":[NSMutableArray array], @"$class":uid(2)} mutableCopy],
            @{@"$classname":@"NSMutableArray", @"$classes":@[@"NSMutableArray", @"NSArray", @"NSObject"]}] mutableCopy]} mutableCopy];
}
static NSMutableArray *archiveItems(NSDictionary *archive) {
    require([archive[@"$archiver"] isEqual:@"NSKeyedArchiver"] && [archive[@"$objects"] isKindOfClass:NSMutableArray.class], @"Unrecognized native policy archive");
    id root = resolve(archive[@"$objects"], archive[@"$top"][@"root"]);
    require([root isKindOfClass:NSDictionary.class] && [root[@"NS.objects"] isKindOfClass:NSMutableArray.class], @"Invalid native policy array");
    return root[@"NS.objects"];
}
static NSUInteger archiveClass(NSMutableArray *objects, NSString *name) {
    for (NSUInteger index = 0; index < objects.count; index++) {
        id object = objects[index];
        if ([object isKindOfClass:NSDictionary.class] && [object[@"$classname"] isEqual:name]) return index;
    }
    NSUInteger index = objects.count;
    [objects addObject:@{@"$classname":name, @"$classes":@[name, @"NSObject"]}];
    return index;
}
static BOOL setField(NSMutableDictionary *object, NSString *key, id value) {
    if ([object[key] isEqual:value]) return NO;
    object[key] = value; return YES;
}
// Change only our graph nodes; unrelated fields, classes, UIDs and policy references stay intact.
static NSData *updatedPolicies(NSDictionary *domain, NSString *mode, NSString *token, pid_t owner, NSString *boot, BOOL *changed) {
    BOOL sameBoot = [domain[@"bootSessionUUID"] isEqual:boot];
    NSData *data = domain[@"policies"];
    require(!data || [data isKindOfClass:NSData.class], @"Invalid native policy archive data");
    NSMutableDictionary *archive = sameBoot && data ? decodeDictionary(data) : emptyArchive();
    NSMutableArray *objects = archive[@"$objects"], *items = archiveItems(archive);
    NSMutableDictionary *own = nil; BOOL modified = !sameBoot && ![mode isEqual:@"reset"];
    for (id ref in [items copy]) {
        id policy = resolve(objects, ref);
        require([policy isKindOfClass:NSMutableDictionary.class], @"Invalid native policy object");
        NSDictionary *type = resolve(objects, policy[@"$class"]);
        require([type[@"$classname"] isEqual:@"ChargeCtrlPolicy"], @"Unknown native policy class; refusing to change it");
        id reason = resolve(objects, policy[@"reason"]);
        require([reason isKindOfClass:NSString.class], @"Invalid native policy reason");
        if ([reason isEqual:Reason]) {
            NSDictionary *uuidObject = resolve(objects, policy[@"token"]);
            NSData *bytes = uuidObject[@"NS.uuidbytes"];
            require([bytes isKindOfClass:NSData.class] && bytes.length == 16, @"Invalid BatteryKeeper policy token");
            NSString *existing = [[NSUUID alloc] initWithUUIDBytes:bytes.bytes].UUIDString;
            require([existing isEqual:token], @"A different BatteryKeeper policy exists; recovery is required");
            require(own == nil, @"Duplicate BatteryKeeper policies require recovery");
            own = policy;
            if ([mode isEqual:@"reset"]) { [items removeObjectIdenticalTo:ref]; modified = YES; }
        } else if (![mode isEqual:@"reset"]) {
            require([policy[@"soclimit"] isKindOfClass:NSNumber.class] && [policy[@"drain"] isKindOfClass:NSNumber.class], @"Invalid native policy fields");
            // Terminated entries still contribute to powerd's aggregate until unplug/replug cleanup.
            require([policy[@"soclimit"] unsignedLongLongValue] >= 100 || ![policy[@"drain"] boolValue],
                [NSString stringWithFormat:@"System policy '%@' requests battery drain; refusing to override it", reason]);
            require(![mode isEqual:@"on"] || [policy[@"soclimit"] unsignedLongLongValue] >= 100,
                [NSString stringWithFormat:@"System policy '%@' still limits charging; refusing to report charging enabled", reason]);
        }
    }
    if (![mode isEqual:@"reset"]) {
        if (!own) {
            NSUInteger policyClass = archiveClass(objects, @"ChargeCtrlPolicy");
            NSUInteger uuidClass = archiveClass(objects, @"NSUUID");
            NSUInteger reasonIndex = objects.count; [objects addObject:Reason];
            uuid_t bytes; NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:token];
            require(uuid != nil, @"Invalid state token"); [uuid getUUIDBytes:bytes];
            NSUInteger tokenIndex = objects.count;
            [objects addObject:@{@"NS.uuidbytes":[NSData dataWithBytes:bytes length:16], @"$class":uid(uuidClass)}];
            own = [@{@"$class":uid(policyClass), @"reason":uid(reasonIndex), @"token":uid(tokenIndex)} mutableCopy];
            [items addObject:uid(objects.count)]; [objects addObject:own]; modified = YES;
        }
        NSDictionary *fields = @{@"owner":@(owner), @"soclimit":[mode isEqual:@"off"] ? @10 : @101,
            @"drain":@NO, @"terminated":@NO, @"noChargeToFull":@YES, @"isEndOfCharge":@YES};
        for (NSString *key in fields) modified = setField(own, key, fields[key]) || modified;
    }
    *changed = modified;
    return modified ? encode(archive) : data;
}
static id nativeClient(void) {
    static id client;
    if (!client) {
        require(dlopen("/System/Library/PrivateFrameworks/PowerUI.framework/PowerUI", RTLD_LAZY) != NULL, @"Native charge framework is unavailable");
        Class type = NSClassFromString(@"PowerUISmartChargeClient");
        for (NSString *selector in @[@"initWithClientName:", @"isMCLSupported", @"isMCLCurrentlyEnabled:", @"getMCLLimitWithError:", @"disableMCL:", @"enableMCL:"])
            require([type instancesRespondToSelector:NSSelectorFromString(selector)], @"Native charge interface has changed");
        client = [[type alloc] initWithClientName:@"BatteryKeeper"];
        require(client != nil, @"Cannot connect to native charge service");
    }
    return client;
}
static NSUInteger nativeMode(void) {
    id client = nativeClient(); NSError *error = nil;
    require([client isMCLSupported], @"This Mac does not support native charge control");
    NSUInteger value = [client isMCLCurrentlyEnabled:&error];
    require(error == nil, error.localizedDescription ?: @"Cannot read native charge-limit state");
    require(value == 0 || value == 1, @"The system charge limit is temporarily overridden; finish that override before enabling BatteryKeeper");
    return value;
}
static void setNativeMode(NSUInteger mode) {
    NSError *error = nil;
    BOOL success = mode ? [nativeClient() enableMCL:&error] : [nativeClient() disableMCL:&error];
    require(success && !error, error.localizedDescription ?: @"Cannot update native charge-limit state");
    require(nativeMode() == mode, @"Native charge-limit state did not change");
}
static void saveState(NSMutableDictionary *state) { writeFile("state.plist", state); }
static void pauseNative(NSMutableDictionary *state) {
    NSUInteger mode = nativeMode();
    if (!state[@"originalMCLState"]) {
        NSError *error = nil; unsigned char limit = [nativeClient() getMCLLimitWithError:&error];
        require(error == nil, error.localizedDescription ?: @"Cannot preserve native charge limit");
        state[@"originalMCLState"] = @(mode); state[@"originalMCLLimit"] = @(limit);
        saveState(state); // Preserve recovery information before the first system change.
    }
    if (mode) setNativeMode(0);
}
static void restoreNative(NSMutableDictionary *state) {
    NSNumber *original = state[@"originalMCLState"];
    if (!original) return;
    if (nativeMode() != original.unsignedIntegerValue) setNativeMode(original.unsignedIntegerValue);
    [state removeObjectForKey:@"originalMCLState"]; [state removeObjectForKey:@"originalMCLLimit"];
    saveState(state);
}
static void waitForReload(NSDictionary *state) {
    double elapsed = MAX(0, now() - [state[@"lastReload"] doubleValue]);
    if (elapsed < ReloadInterval) waitUntil(uptime() + ReloadInterval - elapsed);
}
static void reloadPowerd(NSMutableDictionary *state) {
    waitForReload(state);
    state[@"lastReload"] = @(now()); saveState(state);
    runTool("/usr/bin/killall", @[@"-HUP", @"powerd"], 3);
}
static BOOL changePolicies(NSMutableDictionary *state, NSString *mode) {
    NSString *boot = bootUUID();
    for (NSUInteger attempt = 0; attempt < 3; attempt++) {
        NSDictionary *before = readDomain(); BOOL changed = NO;
        NSData *after = updatedPolicies(before, mode, state[@"token"], getpid(), boot, &changed);
        if (!changed) return NO;
        waitForReload(state);
        before = readDomain(); after = updatedPolicies(before, mode, state[@"token"], getpid(), boot, &changed);
        if (!changed) return NO;
        writeFile("recovery.plist", @{@"before":before, @"boot":boot, @"token":state[@"token"], @"created":NSDate.date});
        if (![readDomain() isEqual:before]) continue;
        CFPreferencesSetMultiple((__bridge CFDictionaryRef)@{@"policies":after, @"bootSessionUUID":boot}, NULL,
            (__bridge CFStringRef)Domain, kCFPreferencesAnyUser, kCFPreferencesCurrentHost);
        require(CFPreferencesSynchronize((__bridge CFStringRef)Domain, kCFPreferencesAnyUser, kCFPreferencesCurrentHost), @"Cannot save native charge policy");
        require([readDomain()[@"policies"] isEqual:after], @"Native charge policy changed concurrently");
        reloadPowerd(state);
        return YES;
    }
    require(NO, @"System charge policies are changing; try again");
    return NO;
}
static void verifyLimits(NSArray *limits, NSString *mode, pid_t owner) {
    NSUInteger found = 0; NSDictionary *aggregate = nil;
    for (NSDictionary *item in limits) {
        NSInteger pid = [item[@"chargeSocLimitOwner"] integerValue];
        if (pid == 0) { aggregate = item; continue; }
        BOOL ours = [item[@"chargeSocLimitReason"] isEqual:Reason];
        if (ours) {
            found++;
            require(![mode isEqual:@"reset"] && pid == owner && ![item[@"Terminated"] boolValue]
                && [item[@"chargeSocLimitSoc"] integerValue] == ([mode isEqual:@"off"] ? 10 : 101)
                && ![item[@"chargeSocLimitDrain"] boolValue] && [item[@"chargeSocLimitNoChargeToFull"] boolValue]
                && [item[@"chargeSocLimitIsEOC"] boolValue], @"BatteryKeeper's native charge policy has not been applied");
        } else if (![mode isEqual:@"reset"]) {
            require([item[@"chargeSocLimitSoc"] integerValue] >= 100 || ![item[@"chargeSocLimitDrain"] boolValue], @"A system policy is requesting battery drain");
            require(![mode isEqual:@"on"] || [item[@"chargeSocLimitSoc"] integerValue] >= 100, @"Another system policy still limits charging");
        }
    }
    require(found == ([mode isEqual:@"reset"] ? 0U : 1U), @"BatteryKeeper's native charge policy is missing or duplicated");
    if ([mode isEqual:@"off"]) {
        require(aggregate && [aggregate[@"chargeSocLimitSoc"] integerValue] > 0 && [aggregate[@"chargeSocLimitSoc"] integerValue] <= 10
            && ![aggregate[@"chargeSocLimitDrain"] boolValue] && [aggregate[@"chargeSocLimitNoChargeToFull"] boolValue], @"The system has not confirmed charging is disabled without battery drain");
    } else if (![mode isEqual:@"reset"] && aggregate) {
        require(![aggregate[@"chargeSocLimitDrain"] boolValue], @"The system aggregate still requests battery drain");
        NSInteger target = [aggregate[@"chargeSocLimitSoc"] integerValue];
        require(target == 0 || target >= 100, @"The system aggregate still limits charging");
    }
}
static void applyMode(NSMutableDictionary *state, NSString *mode) {
    if (![mode isEqual:@"reset"]) pauseNative(state);
    BOOL reloaded = changePolicies(state, mode);
    NSException *lastError = nil;
    double deadline = uptime() + 8;
    do {
        NSArray *limits = nil;
        @try { limits = systemLimits(2); verifyLimits(limits, mode, getpid()); lastError = nil; break; }
        @catch (NSException *error) {
            lastError = error;
            // A previous process may have saved preferences before powerd was reloaded.
            // Reconcile that partial operation instead of mistaking an unchanged archive for success.
            if (!reloaded && limits) {
                BOOL runtimeOwn = NO;
                for (NSDictionary *item in limits) if ([item[@"chargeSocLimitReason"] isEqual:Reason]) runtimeOwn = YES;
                if (![mode isEqual:@"reset"] || runtimeOwn) {
                    if (!changePolicies(state, mode)) reloadPowerd(state);
                    reloaded = YES; deadline = uptime() + 8;
                }
            }
            usleep(200000);
        }
    } while (uptime() < deadline);
    if (lastError) @throw lastError;
    if ([mode isEqual:@"reset"]) restoreNative(state);
}
static void health(NSString *mode, NSString *error) {
    NSMutableDictionary *value = [@{@"pid":@(getpid()), @"boot":bootUUID(), @"checked":@(now()), @"mode":mode} mutableCopy];
    if (error) value[@"error"] = error;
    writeFile("health.plist", value);
}
static NSMutableDictionary *loadState(void) {
    NSMutableDictionary *state = readFile("state.plist");
    if (!state) state = [@{@"version":@1, @"mode":@"reset", @"token":NSUUID.UUID.UUIDString} mutableCopy];
    require([state[@"version"] isEqual:@1] && validMode(state[@"mode"]) && [state[@"token"] isKindOfClass:NSString.class]
        && [[NSUUID alloc] initWithUUIDString:state[@"token"]] != nil, @"Invalid charge-control state; recovery is required");
    require(!state[@"originalMCLState"] || [@[@0, @1] containsObject:state[@"originalMCLState"]], @"Invalid saved native charge-limit state");
    return state;
}
static int daemonMain(void) {
    int lock = lockFile("daemon.lock");
    require(flock(lock, LOCK_EX | LOCK_NB) == 0, @"The charge-control service is already running");
    struct sigaction action = {0}; action.sa_handler = stopSignal; sigemptyset(&action.sa_mask);
    sigaction(SIGTERM, &action, NULL); sigaction(SIGINT, &action, NULL);
    NSMutableDictionary *state = loadState(); saveState(state);
    double nextCheck = 0;
    NSString *processed = state[@"processedRequest"];
    NSString *processedQuery = nil;
    @try {
        while (!stopping) { @autoreleasepool {
            NSMutableDictionary *request = readFile("request.plist");
            BOOL pending = request && ![request[@"id"] isEqual:processed];
            BOOL query = NO;
            if (!pending) {
                NSMutableDictionary *queryRequest = readFile("query.plist");
                if (queryRequest && ![queryRequest[@"id"] isEqual:processedQuery]) {
                    request = queryRequest; pending = YES; query = YES;
                }
            }
            if (!pending && now() < nextCheck) { usleep(200000); continue; }
            NSString *mode = pending && !query ? request[@"command"] : state[@"mode"];
            NSString *failure = nil;
            @try {
                require(validMode(mode), @"Invalid charge-control request");
                if (pending) {
                    require([request[@"id"] isKindOfClass:NSString.class]
                        && [[NSUUID alloc] initWithUUIDString:request[@"id"]] != nil, @"Invalid request identifier");
                    require(query ? [request[@"command"] isEqual:@"status"] : validMode(request[@"command"]), @"Invalid charge-control request");
                    if (!query) { state[@"mode"] = mode; saveState(state); }
                }
                if (query) {
                    verifyLimits(systemLimits(1), mode, getpid());
                    NSUInteger systemMode = nativeMode();
                    if (![mode isEqual:@"reset"]) require(systemMode == 0, @"The system charge limit is no longer paused");
                } else {
                    health(mode, @"Applying charge-control change");
                    applyMode(state, mode);
                }
                health(mode, nil);
            } @catch (NSException *error) {
                failure = error.reason ?: @"Charge control failed";
                fprintf(stderr, "charge-control: %s\n", failure.UTF8String);
                // A failed takeover must not leave the native limit paused indefinitely.
                if (!query && ![mode isEqual:@"reset"]) {
                    state[@"mode"] = @"reset"; saveState(state);
                    @try { applyMode(state, @"reset"); }
                    @catch (NSException *cleanup) { failure = [failure stringByAppendingFormat:@"; recovery pending: %@", cleanup.reason]; }
                }
                health(state[@"mode"], failure);
            }
            if (pending) {
                NSMutableDictionary *response = [@{@"id":request[@"id"] ?: @"invalid", @"mode":mode ?: @"invalid", @"ok":@(failure == nil)} mutableCopy];
                if (failure) response[@"error"] = failure;
                if (query) processedQuery = request[@"id"] ?: @"invalid";
                else { processed = request[@"id"] ?: @"invalid"; state[@"processedRequest"] = processed; saveState(state); }
                writeFile(query ? "query-response.plist" : "response.plist", response);
            }
            if (!query) nextCheck = now() + 5;
        } }
    } @finally {
        @try { applyMode(state, @"reset"); health(@"reset", @"Charge-control service stopped"); }
        @catch (NSException *error) { fprintf(stderr, "charge-control cleanup: %s\n", error.reason.UTF8String); }
        close(lock);
    }
    return 0;
}
static void requireLiveDaemon(void) {
    int fd = lockFile("daemon.lock");
    int result = flock(fd, LOCK_EX | LOCK_NB), error = errno;
    close(fd);
    require(result != 0 && error == EWOULDBLOCK, @"Charge-control service is unavailable");
}
static int clientMain(NSString *command) {
    BOOL query = [command isEqual:@"status"];
    double deadline = uptime() + (query ? 3 : 45);
    int lock = lockFile(query ? "query.lock" : "command.lock");
    @try {
        // GUI refreshes and a newly started CLI worker can query concurrently.
        // Keep the request/response pair locked through verification, with room to queue.
        double lockDeadline = uptime() + (query ? 2 : 5);
        while (flock(lock, LOCK_EX | LOCK_NB) != 0) {
            require(errno == EWOULDBLOCK && uptime() < lockDeadline, @"Another charge-control command is in progress");
            usleep(50000);
        }
        requireLiveDaemon();
        NSString *identifier = NSUUID.UUID.UUIDString;
        writeFile(query ? "query.plist" : "request.plist", @{@"id":identifier, @"command":command});
        while (uptime() < deadline) {
            NSDictionary *response = readFile(query ? "query-response.plist" : "response.plist");
            if ([response[@"id"] isEqual:identifier]) {
                require([response[@"ok"] boolValue], response[@"error"] ?: @"Charge-control request failed");
                require(validMode(response[@"mode"]), @"Invalid confirmed charge-control mode");
                if (query) puts([response[@"mode"] isEqual:@"off"] ? "disabled" : "enabled");
                return 0;
            }
            usleep(100000);
        }
        require(NO, @"Charge-control request timed out; the service has not confirmed it");
    } @finally { close(lock); }
    return 1;
}

#ifdef CHARGE_CONTROL_TEST
#include "tests/self-test.inc"
#endif
int main(int argc, const char *argv[]) { @autoreleasepool {
    @try {
        initializeUIDs();
#ifdef CHARGE_CONTROL_TEST
        (void)argc; (void)argv;
        return selfTests();
#else
        require(argc == 2, @"Usage: charge-control on|off|reset|status");
        NSString *command = [NSString stringWithUTF8String:argv[1]];
        require(validMode(command) || [command isEqual:@"status"] || [command isEqual:@"daemon"], @"Unknown charge-control command");
        require(NSProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27, @"Native charge control requires macOS 27 or later");
        openStore();
        return [command isEqual:@"daemon"] ? daemonMain() : clientMain(command);
#endif
    } @catch (NSException *error) {
        fprintf(stderr, "charge-control: %s\n", (error.reason ?: @"Unknown failure").UTF8String);
        return 1;
    }
} }
