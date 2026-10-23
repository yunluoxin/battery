// In-process tests never open the privileged state directory or call power services.
static BOOL fails(void (^operation)(void)) {
    @try { operation(); return NO; } @catch (NSException *error) { (void)error; return YES; }
}
static int selfTests(void) {
    // Keep the production entry points referenced without invoking their side effects.
    (void)openStore; (void)daemonMain; (void)clientMain;
    NSString *token = @"B239631C-A9C4-46C4-9047-461C4511DC09";
    NSDictionary *initial = @{@"bootSessionUUID":@"boot", @"policies":encode(emptyArchive()), @"unrelated":@"preserve"};
    BOOL changed = NO;
    NSData *off = updatedPolicies(initial, @"off", token, 456, @"boot", &changed);
    require(changed, @"Off must create a policy");
    NSDictionary *domain = @{@"bootSessionUUID":@"boot", @"policies":off};
    updatedPolicies(domain, @"off", token, 456, @"boot", &changed);
    require(!changed, @"Identical requests must not restart powerd");
    NSData *on = updatedPolicies(domain, @"on", token, 456, @"boot", &changed);
    require(changed, @"On must change its own policy");
    NSMutableDictionary *archive = decodeDictionary(on);
    NSDictionary *policy = resolve(archive[@"$objects"], archiveItems(archive).firstObject);
    require([policy[@"soclimit"] isEqual:@101] && ![policy[@"drain"] boolValue], @"On must use the no-limit sentinel without drain");
    NSDictionary *onDomain = @{@"bootSessionUUID":@"boot", @"policies":on};
    NSData *reset = updatedPolicies(onDomain, @"reset", token, 456, @"boot", &changed);
    require(changed && archiveItems(decodeDictionary(reset)).count == 0, @"Reset must remove its root reference");
    require(fails(^{ BOOL c; updatedPolicies(domain, @"off", @"7FB48A62-F077-4872-A8A4-6CC9D62D7267", 456, @"boot", &c); }), @"Foreign tokens must be rejected");
    NSMutableDictionary *foreignArchive = decodeDictionary(off);
    NSMutableArray *objects = foreignArchive[@"$objects"];
    NSMutableDictionary *foreign = resolve(objects, archiveItems(foreignArchive).firstObject);
    foreign[@"reason"] = uid(objects.count); [objects addObject:@"thermal-protection"];
    foreign[@"drain"] = @YES; foreign[@"terminated"] = @YES;
    foreign[@"futureField"] = @[@"preserve", @42];
    NSDictionary *conflict = @{@"bootSessionUUID":@"boot", @"policies":encode(foreignArchive)};
    require(fails(^{ BOOL c; updatedPolicies(conflict, @"off", token, 456, @"boot", &c); }), @"Terminated drain policies must also conflict");
    foreign[@"drain"] = @NO;
    NSDictionary *safe = @{@"bootSessionUUID":@"boot", @"policies":encode(foreignArchive)};
    NSMutableDictionary *preserved = decodeDictionary(updatedPolicies(safe, @"off", token, 456, @"boot", &changed));
    NSDictionary *first = resolve(preserved[@"$objects"], archiveItems(preserved).firstObject);
    require([first[@"futureField"] isEqual:foreign[@"futureField"]] && archiveItems(preserved).count == 2, @"Unrelated policy fields must survive");
    require(fails(^{ BOOL c; updatedPolicies(safe, @"on", token, 456, @"boot", &c); }), @"An external lower limit must not be reported as charging enabled");
    require(archiveItems(decodeDictionary(updatedPolicies(safe, @"off", token, 456, @"new-boot", &changed))).count == 1,
        @"A new boot must not revive old system policies");
    NSString *output = @"Battery level limits:\n({chargeSocLimitOwner=456; chargeSocLimitReason=BatteryKeeper; chargeSocLimitSoc=10; chargeSocLimitDrain=0; chargeSocLimitNoChargeToFull=1; chargeSocLimitIsEOC=1; Terminated=0;}, {chargeSocLimitOwner=0; chargeSocLimitReason=BatteryKeeper; chargeSocLimitSoc=10; chargeSocLimitDrain=0; chargeSocLimitNoChargeToFull=1; chargeSocLimitIsEOC=1; Terminated=0;})";
    NSArray *limits = parseLimits(output); verifyLimits(limits, @"off", 456);
    require(fails(^{ verifyLimits(limits, @"off", 999); }), @"Stale owner must fail verification");
    NSMutableArray *draining = [limits mutableCopy]; NSMutableDictionary *aggregate = [draining.lastObject mutableCopy];
    aggregate[@"chargeSocLimitDrain"] = @1; draining[1] = aggregate;
    require(fails(^{ verifyLimits(draining, @"off", 456); }), @"Aggregate drain must fail verification");
    verifyLimits(parseLimits(@"No battery level limits set\n"), @"reset", 456);
    require(fails(^{ parseLimits([output stringByReplacingOccurrencesOfString:@"chargeSocLimitOwner=456;" withString:@""]); }), @"Missing owner must not become a zero-owner aggregate");
    require(fails(^{ parseLimits([output stringByReplacingOccurrencesOfString:@"chargeSocLimitDrain=0;" withString:@"chargeSocLimitDrain=invalid;"]); }), @"Malformed flags must not become false");
    NSArray *onLimits = parseLimits([output stringByReplacingOccurrencesOfString:@"chargeSocLimitSoc=10;" withString:@"chargeSocLimitSoc=101;"]);
    verifyLimits(@[onLimits.firstObject], @"on", 456);
    require(fails(^{ verifyLimits(@[onLimits.firstObject, limits.lastObject], @"on", 456); }), @"A stale lower aggregate must fail on verification");
    require(fails(^{ verifyLimits(@[onLimits.firstObject, @{@"chargeSocLimitOwner":@77, @"chargeSocLimitReason":@"another-app", @"chargeSocLimitSoc":@60, @"chargeSocLimitDrain":@0}], @"on", 456); }), @"Live external charge limits must fail on verification");
    require(fails(^{ parseLimits(@"Battery limits unavailable"); }), @"Unavailable status must not become enabled");
    puts("charge-control: archive preservation, conflict detection, idempotence and applied-status tests passed");
    return 0;
}
