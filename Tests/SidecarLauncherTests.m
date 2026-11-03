//
//  Created by YueRuo on 2026/11/2.
//

#define SIDECAR_LAUNCHER_TEST 1
#import "../Sources/Helpers/SidecarLauncher.m"

static NSUInteger checks = 0;
static void Verify(BOOL condition, NSString *message) {
    checks++;
    if (!condition) { fprintf(stderr,"FAIL Sidecar helper: %s\n",message.UTF8String); exit(1); }
}

@interface TestSidecarDevice : NSObject
@property(nonatomic,copy) NSString *name;
@end
@implementation TestSidecarDevice
@end

@interface BadSidecarDevice : NSObject
- (NSInteger)name;
@end
@implementation BadSidecarDevice
- (NSInteger)name { return 7; }
@end

@interface TestSidecarManager : NSObject
@property(nonatomic,strong) id list;
@property(nonatomic,strong) id selectedDevice;
@property(nonatomic,copy) NSString *operation;
@property(nonatomic,strong) NSError *operationError;
@property(nonatomic) NSUInteger operationCount;
@property(nonatomic) NSUInteger callbackMode;
@property(nonatomic) BOOL throwsOnRead;
@property(nonatomic) BOOL throwsOnOperation;
@end
@implementation TestSidecarManager
- (id)devices {
    if (self.throwsOnRead) @throw [NSException exceptionWithName:@"TestError" reason:@"fake" userInfo:nil];
    return self.list;
}
- (void)complete:(void (^)(NSError *))completion {
    if (self.throwsOnOperation) @throw [NSException exceptionWithName:@"TestError" reason:@"fake" userInfo:nil];
    NSError *error = self.operationError;
    switch (self.callbackMode) {
        case 0: { completion(error); break; }
        case 1: { dispatch_async(dispatch_get_main_queue(), ^{ completion(error); }); break; }
        case 2: { dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0), ^{ completion(error); }); break; }
        case 3: { break; }
        case 4: { completion(error); completion(nil); break; }
        case 5: { completion((id)@"invalid result"); break; }
        case 6: { dispatch_after(dispatch_time(DISPATCH_TIME_NOW,30*NSEC_PER_MSEC),dispatch_get_main_queue(),^{ completion(error); }); break; }
        default: break;
    }
}
- (void)connectToDevice:(id)device completion:(void (^)(NSError *))completion {
    self.selectedDevice=device; self.operation=@"connect"; self.operationCount++;
    [self complete:completion];
}
- (void)disconnectFromDevice:(id)device completion:(void (^)(NSError *))completion {
    self.selectedDevice=device; self.operation=@"disconnect"; self.operationCount++;
    [self complete:completion];
}
@end

@interface WrongABISidecarManager : NSObject
@property(nonatomic,strong) id list;
@property(nonatomic) BOOL called;
@end
@implementation WrongABISidecarManager
- (id)devices { return self.list; }
- (id)connectToDevice:(id)device completion:(id)completion {
    (void)device; (void)completion; self.called=YES; return nil;
}
@end

@interface BlockDeviceSidecarManager : NSObject
@property(nonatomic,strong) id list;
@property(nonatomic) BOOL called;
@end
@implementation BlockDeviceSidecarManager
- (id)devices { return self.list; }
- (void)connectToDevice:(void (^)(void))device completion:(void (^)(NSError *))completion {
    (void)device; (void)completion; self.called=YES;
}
@end

static TestSidecarDevice *Device(NSString *name) {
    TestSidecarDevice *device=[TestSidecarDevice new]; device.name=name; return device;
}
static SCLExit Invoke(NSArray *arguments,id manager,NSMutableArray *output,NSTimeInterval timeout,NSError **error) {
    return SCLRun(arguments,^id(NSError **problem){ (void)problem; return manager; },
        ^(NSString *line){ [output addObject:line]; },timeout,error);
}

int main(void) {
    @autoreleasepool {
        TestSidecarDevice *first=Device(@"  小王's iPad $(literal); `name`  ");
        TestSidecarDevice *second=Device(@"Second iPad");
        TestSidecarManager *manager=[TestSidecarManager new]; manager.list=@[first,second];
        NSMutableArray *output=[NSMutableArray array]; NSError *error=nil;
        Verify(Invoke(@[@"devices"],manager,output,0.3,&error)==SCLSuccess &&
            [output isEqual:@[first.name,second.name]] && manager.operationCount==0,
            @"发现设备仅输出原始名称，保留顺序、中文、空格和特殊字符，不执行连接");
        for (NSString *verb in @[@"connect",@"disconnect"]) {
            [output removeAllObjects]; manager.operationCount=0;
            Verify(Invoke(@[verb,first.name],manager,output,0.3,&error)==SCLSuccess &&
                manager.selectedDevice==first && [manager.operation isEqual:verb] && manager.operationCount==1 &&
                [output isEqual:@[[verb isEqual:@"connect"]?@"connected":@"disconnected"]],
                @"连接和断开准确选择指定对象，并等待系统完成后才报告成功");
        }
        [output removeAllObjects];
        Verify(Invoke(@[@"connect",@"SECOND IPAD"],manager,output,0.3,&error)==SCLSuccess &&
            manager.selectedDevice==second, @"名称忽略大小写完整匹配，不作子串匹配");
        NSUInteger before=manager.operationCount;
        [output removeAllObjects];
        Verify(Invoke(@[@"connect",@"Second"],manager,output,0.3,&error)==SCLDeviceNotFound &&
            manager.operationCount==before && output.count==0, @"找不到完整目标时不调用其他设备");

        NSArray *invalidInputs=@[@[],@[@"devices",@"extra"],@[@"connect"],@[@"disconnect"],
            @[@"connect",@"name",@"-wired"],@[@"other"],@[@"connect;evil",@"name"],
            @[@"connect",@""],@[@"connect",@"  "],@[@"connect",@"bad\nname"],
            @[@"disconnect",@"bad\tname"],@[@"connect",@42],@[@12],
            @[@"connect",[@"a" stringByPaddingToLength:257 withString:@"a" startingAtIndex:0]]];
        for(NSArray *arguments in invalidInputs) {
            __block BOOL loaded=NO;
            Verify(SCLRun(arguments,^id(NSError **problem){ (void)problem; loaded=YES; return manager; },nil,0.3,&error)==SCLInvalidInput &&
                !loaded, @"无效、额外、拼接、空名称和过长参数在加载系统框架前拒绝");
        }
        manager.list=@[]; [output removeAllObjects];
        Verify(Invoke(@[@"devices"],manager,output,0.3,&error)==SCLNoDevices && output.count==0,
            @"无设备时保留旧工具退出码 2，输出不混入错误文本");
        for(id bad in @[NSNull.null,@"invalid",@42]) {
            manager.list=bad;
            Verify(Invoke(@[@"devices"],manager,output,0.3,&error)==SCLBackendError && output.count==0,
                @"异常设备列表类型被拒绝");
        }
        for(id badDevice in @[[NSObject new],[BadSidecarDevice new],Device(@"bad\nname"),Device(@"")]) {
            manager.list=@[first,badDevice];
            Verify(Invoke(@[@"devices"],manager,output,0.3,&error)==SCLBackendError && output.count==0,
                @"先验证整个设备列表，缺失 getter、ABI 错误或名称无效时不输出半份结果");
        }
        manager.list=[NSArray arrayWithObjects:first,nil];
        NSMutableArray *many=[NSMutableArray array];
        for(NSUInteger i=0;i<128;i++) [many addObject:Device([NSString stringWithFormat:@"iPad %lu",(unsigned long)i])];
        manager.list=many;
        Verify(Invoke(@[@"devices"],manager,output,0.3,&error)==SCLSuccess && output.count==128,
            @"接受有界数量的有效设备");
        [many addObject:second]; [output removeAllObjects];
        Verify(Invoke(@[@"devices"],manager,output,0.3,&error)==SCLBackendError && output.count==0,
            @"超过 128 台设备时停止，不产生无界输出");
        manager.list=[NSOrderedSet orderedSetWithArray:@[second,first]];
        Verify(Invoke(@[@"devices"],manager,output,0.3,&error)==SCLSuccess && [output isEqual:@[second.name,first.name]],
            @"支持有序集合且保留系统顺序");
        [output removeAllObjects]; manager.list=[NSSet setWithArray:@[second,first]];
        Verify(Invoke(@[@"devices"],manager,output,0.3,&error)==SCLSuccess &&
            [output isEqual:[@[second.name,first.name] sortedArrayUsingSelector:@selector(compare:)]],
            @"无序集合使用确定的名称顺序");

        for(NSUInteger mode=0;mode<=2;mode++) {
            manager.list=@[first]; manager.callbackMode=mode; manager.operationError=nil;
            [output removeAllObjects];
            Verify(Invoke(@[@"connect",first.name],manager,output,0.3,&error)==SCLSuccess && [output isEqual:@[@"connected"]],
                @"同步、主队列及后台回调均能完成，主队列不会死锁");
        }
        manager.callbackMode=3; [output removeAllObjects];
        NSTimeInterval start=NSProcessInfo.processInfo.systemUptime;
        Verify(Invoke(@[@"connect",first.name],manager,output,0.02,&error)==SCLTimeout &&
            NSProcessInfo.processInfo.systemUptime-start<0.3 && output.count==0,
            @"系统不回调时有界退出，不误报连接成功");
        manager.operationError=[NSError errorWithDomain:@"test" code:-203 userInfo:@{NSLocalizedDescriptionKey:@"private details"}];
        manager.callbackMode=4;
        Verify(Invoke(@[@"connect",first.name],manager,output,0.3,&error)==SCLBackendError &&
            [error.localizedDescription containsString:@"-203"] && ![error.localizedDescription containsString:@"private details"] &&
            output.count==0, @"首个失败回调有效，重复成功回调不能覆盖；错误仅保留有界错误码");
        manager.operationError=nil; manager.callbackMode=5;
        Verify(Invoke(@[@"connect",first.name],manager,output,0.3,&error)==SCLBackendError && output.count==0,
            @"异常回调参数不会作为成功或崩溃处理");
        manager.callbackMode=6;
        Verify(Invoke(@[@"disconnect",first.name],manager,output,0.002,&error)==SCLTimeout && output.count==0,
            @"迟到回调不改变已经超时的返回结果");
        CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.06,false);
        Verify(output.count==0,@"迟到和重复回调不会打印成功或污染下一次操作");
        manager.callbackMode=0;
        before=manager.operationCount;
        for(NSNumber *timeout in @[@0,@(-1),@(NAN),@46]) {
            Verify(Invoke(@[@"connect",first.name],manager,output,timeout.doubleValue,&error)==SCLTimeout &&
                manager.operationCount==before, @"无效或无预算时不发起系统操作");
        }
        manager.throwsOnRead=YES;
        Verify(Invoke(@[@"devices"],manager,output,0.3,&error)==SCLBackendError,@"私有 getter 异常转成明确错误");
        manager.throwsOnRead=NO; manager.throwsOnOperation=YES;
        Verify(Invoke(@[@"connect",first.name],manager,output,0.3,&error)==SCLBackendError,@"私有操作异常转成明确错误");
        WrongABISidecarManager *wrong=[WrongABISidecarManager new]; wrong.list=@[first];
        Verify(Invoke(@[@"connect",first.name],wrong,output,0.3,&error)==SCLBackendError && !wrong.called,
            @"操作 ABI 不匹配时拒绝调用，避免跳入错误函数签名");
        BlockDeviceSidecarManager *blockDevice=[BlockDeviceSidecarManager new]; blockDevice.list=@[first];
        Verify(Invoke(@[@"connect",first.name],blockDevice,output,0.3,&error)==SCLBackendError && !blockDevice.called,
            @"设备参数改变为 block 时拒绝将普通设备对象传入");
        Verify(Invoke(@[@"devices"],[NSObject new],output,0.3,&error)==SCLBackendError,
            @"缺失管理方法时安全失败");
        Verify(Invoke(@[@"devices"],nil,output,0.3,&error)==SCLBackendError,
            @"系统框架或管理对象不可用时安全失败");
        printf("PASS: %lu Sidecar helper checks\n",(unsigned long)checks);
        return 0;
    }
}
