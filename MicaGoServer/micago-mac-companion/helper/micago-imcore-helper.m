// micago-imcore-helper — MicaGo's own minimal IMCore helper for the advanced
// iMessage actions (edit / unsend / delete).
//
// MicaGo-controlled and bundled with the Companion; users never install
// imsg/imsgbridge. It is a faithful, minimal port of the IMCore action logic in
// Ref/imsg (Sources/IMsgHelper/IMsgInjected.m) — only the pieces needed for
// capability detection + edit/retract/delete.
//
// Protocol (matches internal/imessage/actions.go helperEnvelope): read ONE JSON
// object from stdin, write ONE JSON object to stdout, exit 0.
//
//   status  → {"capabilities":{"edit":bool,"retract":bool,"delete":bool}}
//             (omitted/empty caps ⇒ the backend reports "unsupported")
//   edit    ← {"action":"edit","chatGuid","messageGuid","text","partIndex"}
//   retract ← {"action":"retract","chatGuid","messageGuid","partIndex"}
//   delete  ← {"action":"delete","chatGuid","messageGuid"}
//             → {"ok":true} | {"ok":false,"code":"...","error":"..."}
//
// Error codes the backend understands: not_found, unsupported, not_allowed,
// expired, bad_request, action_failed.
//
// IMPORTANT: edit/unsend/delete go through Apple's PRIVATE IMCore framework via
// the Messages daemon (imagent). They only succeed in an environment that lets
// this process drive IMCore (Full Disk Access / Automation, and on locked-down
// macOS releases the same SIP/entitlement limits imsg documents). Where that is
// not available the helper reports capabilities honestly and returns a clear
// error — never a fake success.

#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <math.h>

// ---- Forward decls (resolved at runtime; no private headers/link needed) ----
@interface NSObject (MicaGoIMCore)
- (id)sharedInstance;
@end

static BOOL gHasEditItem = NO;
static BOOL gHasEditLegacy = NO;
static BOOL gHasRetract = NO;
static BOOL gHasDelete = NO;

static void writeJSONAndExit(NSDictionary *obj) {
    NSError *err = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:obj options:0 error:&err];
    if (data) {
        [[NSFileHandle fileHandleWithStandardOutput] writeData:data];
    }
    exit(0);
}

static NSDictionary *fail(NSString *code, NSString *msg) {
    return @{ @"ok": @NO, @"code": code ?: @"action_failed", @"error": msg ?: @"iMessage action failed" };
}

static NSDictionary *ok(void) { return @{ @"ok": @YES }; }

// Load IMCore. Returns NO when the private framework can't be loaded.
static BOOL loadIMCore(void) {
    if (NSClassFromString(@"IMChat")) return YES;
    const char *paths[] = {
        "/System/Library/PrivateFrameworks/IMCore.framework/IMCore",
        "/System/Library/PrivateFrameworks/IMCore.framework/Versions/Current/IMCore",
    };
    for (size_t i = 0; i < sizeof(paths) / sizeof(paths[0]); i++) {
        if (dlopen(paths[i], RTLD_NOW) != NULL) return YES;
    }
    return NSClassFromString(@"IMChat") != nil;
}

// Best-effort connect to the Messages daemon and spin briefly so IMChatRegistry
// can populate. Returns YES when the controller reports connected (or when we
// cannot tell but the class exists).
static BOOL connectDaemon(void) {
    Class dc = NSClassFromString(@"IMDaemonController");
    if (!dc) return NO;
    id controller = [dc performSelector:@selector(sharedInstance)];
    if (!controller) return NO;
    if ([controller respondsToSelector:@selector(connectToDaemon)]) {
        @try { [controller performSelector:@selector(connectToDaemon)]; }
        @catch (__unused NSException *e) {}
    }
    SEL isConnected = @selector(isConnected);
    for (int i = 0; i < 20; i++) { // up to ~2s
        if ([controller respondsToSelector:isConnected]) {
            BOOL c = ((BOOL (*)(id, SEL))objc_msgSend)(controller, isConnected);
            if (c) return YES;
        }
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    }
    // If the selector is absent we can't prove it; treat the class presence as
    // a soft yes so capability detection still reflects selector availability.
    return ![controller respondsToSelector:isConnected];
}

static void probeSelectors(void) {
    Class chat = NSClassFromString(@"IMChat");
    if (!chat) return;
    gHasEditItem = [chat instancesRespondToSelector:
        @selector(editMessageItem:atPartIndex:withNewPartText:backwardCompatabilityText:)];
    gHasEditLegacy = [chat instancesRespondToSelector:
        @selector(editMessage:atPartIndex:withNewPartText:backwardCompatabilityText:)];
    gHasRetract = [chat instancesRespondToSelector:@selector(retractMessagePart:)];
    gHasDelete = [chat instancesRespondToSelector:@selector(deleteChatItems:)];
}

static id resolveChat(NSString *chatGuid) {
    if (![chatGuid isKindOfClass:[NSString class]] || chatGuid.length == 0) return nil;
    Class registryClass = NSClassFromString(@"IMChatRegistry");
    if (!registryClass) return nil;
    id registry = [registryClass performSelector:@selector(sharedInstance)];
    if (!registry) return nil;
    if ([registry respondsToSelector:@selector(existingChatWithGUID:)]) {
        id chat = [registry performSelector:@selector(existingChatWithGUID:) withObject:chatGuid];
        if (chat) return chat;
    }
    if ([registry respondsToSelector:@selector(existingChatWithChatIdentifier:)]) {
        NSArray *parts = [chatGuid componentsSeparatedByString:@";"];
        NSString *ident = parts.count == 3 ? parts.lastObject : chatGuid;
        id chat = [registry performSelector:@selector(existingChatWithChatIdentifier:) withObject:ident];
        if (chat) return chat;
    }
    return nil;
}

// Find the chat item for a message GUID. Asks IMChatHistoryController to load
// recent items, then polls chat.chatItems for up to ~2s (ported from imsg).
static id findMessageItem(id chat, NSString *messageGuid) {
    if (!chat || messageGuid.length == 0) return nil;
    Class hcClass = NSClassFromString(@"IMChatHistoryController");
    id hc = hcClass ? [hcClass performSelector:@selector(sharedInstance)] : nil;
    SEL loadSel = @selector(loadedChatItemsForChat:beforeDate:limit:loadIfNeeded:);
    if (hc && [hc respondsToSelector:loadSel]) {
        @try {
            NSMethodSignature *sig = [hc methodSignatureForSelector:loadSel];
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setSelector:loadSel];
            [inv setTarget:hc];
            __unsafe_unretained id chatArg = chat;
            [inv setArgument:&chatArg atIndex:2];
            NSDate *now = [NSDate date];
            [inv setArgument:&now atIndex:3];
            NSUInteger limit = 100;
            [inv setArgument:&limit atIndex:4];
            BOOL load = YES;
            [inv setArgument:&load atIndex:5];
            [inv invoke];
        } @catch (__unused NSException *e) {}
    }
    for (int attempt = 0; attempt < 20; attempt++) {
        NSArray *items = [chat respondsToSelector:@selector(chatItems)] ? [chat performSelector:@selector(chatItems)] : nil;
        if (![items isKindOfClass:[NSArray class]]) items = nil;
        for (id item in items) {
            id guid = nil;
            id message = [item respondsToSelector:@selector(message)] ? [item performSelector:@selector(message)] : nil;
            if (message && [message respondsToSelector:@selector(guid)]) {
                guid = [message performSelector:@selector(guid)];
            } else if ([item respondsToSelector:@selector(guid)]) {
                guid = [item performSelector:@selector(guid)];
            }
            if ([guid isKindOfClass:[NSString class]] && [guid isEqualToString:messageGuid]) return item;
        }
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    }
    return nil;
}

static NSAttributedString *buildAttributed(NSString *text, NSInteger partIndex) {
    if (![text isKindOfClass:[NSString class]]) text = @"";
    return [[NSAttributedString alloc] initWithString:text attributes:@{
        @"__kIMMessagePartAttributeName": @(partIndex),
        @"__kIMBaseWritingDirectionAttributeName": @"-1"
    }];
}

static NSDictionary *doEdit(NSString *chatGuid, NSString *messageGuid, NSString *text, NSInteger partIndex) {
    if (![text isKindOfClass:[NSString class]] || text.length == 0) return fail(@"bad_request", @"edited text is required");
    if (partIndex < 0) return fail(@"bad_request", @"partIndex must be non-negative");
    if (!gHasEditItem && !gHasEditLegacy) return fail(@"unsupported", @"editing is not available on this macOS");
    id chat = resolveChat(chatGuid);
    if (!chat) return fail(@"not_found", [NSString stringWithFormat:@"chat not found: %@", chatGuid]);
    id item = findMessageItem(chat, messageGuid);
    if (!item) return fail(@"not_found", [NSString stringWithFormat:@"message not found: %@", messageGuid]);

    NSAttributedString *newBody = buildAttributed(text, partIndex);
    NSAttributedString *bcBody = [[NSAttributedString alloc] initWithString:text];
    @try {
        if (gHasEditItem) {
            id messageItem = [item respondsToSelector:@selector(messageItem)] ? [item performSelector:@selector(messageItem)] : item;
            SEL sel = @selector(editMessageItem:atPartIndex:withNewPartText:backwardCompatabilityText:);
            NSMethodSignature *sig = [chat methodSignatureForSelector:sel];
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setSelector:sel];
            [inv setTarget:chat];
            __unsafe_unretained id ci = messageItem; [inv setArgument:&ci atIndex:2];
            [inv setArgument:&partIndex atIndex:3];
            __unsafe_unretained NSAttributedString *nb = newBody; [inv setArgument:&nb atIndex:4];
            __unsafe_unretained NSAttributedString *bc = bcBody; [inv setArgument:&bc atIndex:5];
            [inv invoke];
        } else {
            id message = [item respondsToSelector:@selector(message)] ? [item performSelector:@selector(message)] : nil;
            if (!message) return fail(@"not_found", @"message object not found");
            SEL sel = @selector(editMessage:atPartIndex:withNewPartText:backwardCompatabilityText:);
            NSMethodSignature *sig = [chat methodSignatureForSelector:sel];
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setSelector:sel];
            [inv setTarget:chat];
            __unsafe_unretained id msg = message; [inv setArgument:&msg atIndex:2];
            [inv setArgument:&partIndex atIndex:3];
            __unsafe_unretained NSAttributedString *nb = newBody; [inv setArgument:&nb atIndex:4];
            __unsafe_unretained NSAttributedString *bc = bcBody; [inv setArgument:&bc atIndex:5];
            [inv invoke];
        }
    } @catch (NSException *ex) {
        return fail(@"action_failed", ex.reason ?: @"edit failed");
    }
    return ok();
}

static NSDictionary *doRetract(NSString *chatGuid, NSString *messageGuid, NSInteger partIndex) {
    if (!gHasRetract) return fail(@"unsupported", @"unsend is not available on this macOS");
    id chat = resolveChat(chatGuid);
    if (!chat) return fail(@"not_found", [NSString stringWithFormat:@"chat not found: %@", chatGuid]);
    id item = findMessageItem(chat, messageGuid);
    if (!item) return fail(@"not_found", [NSString stringWithFormat:@"message not found: %@", messageGuid]);
    @try {
        id target = item;
        SEL ncSel = NSSelectorFromString(@"_newChatItems");
        if ([item respondsToSelector:ncSel]) {
            id parts = ((id (*)(id, SEL))objc_msgSend)(item, ncSel);
            if ([parts isKindOfClass:[NSArray class]]) {
                NSArray *arr = parts;
                if (arr.count == 1) target = arr.firstObject;
                else if (arr.count > 1) {
                    for (id sub in arr) {
                        if ([sub respondsToSelector:@selector(index)] &&
                            ((NSInteger (*)(id, SEL))objc_msgSend)(sub, @selector(index)) == partIndex) {
                            target = sub; break;
                        }
                    }
                }
            } else if (parts) {
                target = parts;
            }
        }
        [chat performSelector:@selector(retractMessagePart:) withObject:target];
    } @catch (NSException *ex) {
        return fail(@"action_failed", ex.reason ?: @"unsend failed");
    }
    return ok();
}

static NSDictionary *doDelete(NSString *chatGuid, NSString *messageGuid) {
    if (!gHasDelete) return fail(@"unsupported", @"delete is not available on this macOS");
    id chat = resolveChat(chatGuid);
    if (!chat) return fail(@"not_found", [NSString stringWithFormat:@"chat not found: %@", chatGuid]);
    id item = findMessageItem(chat, messageGuid);
    if (!item) return fail(@"not_found", [NSString stringWithFormat:@"message not found: %@", messageGuid]);
    @try {
        [chat performSelector:@selector(deleteChatItems:) withObject:@[item]];
    } @catch (NSException *ex) {
        return fail(@"action_failed", ex.reason ?: @"delete failed");
    }
    return ok();
}

int main(int argc, const char *argv[]) {
    (void)argc;
    (void)argv;
    @autoreleasepool {
        NSData *input = [[NSFileHandle fileHandleWithStandardInput] readDataToEndOfFile];
        NSDictionary *req = nil;
        if (input.length) {
            req = [NSJSONSerialization JSONObjectWithData:input options:0 error:NULL];
        }
        if (![req isKindOfClass:[NSDictionary class]]) {
            writeJSONAndExit(fail(@"bad_request", @"expected a JSON request object on stdin"));
        }
        id rawAction = req[@"action"];
        if (![rawAction isKindOfClass:[NSString class]] || [(NSString *)rawAction length] == 0) {
            writeJSONAndExit(fail(@"bad_request", @"action must be a non-empty string"));
        }
        NSString *action = (NSString *)rawAction;
        BOOL isStatus = [action isEqualToString:@"status"];
        BOOL isEdit = [action isEqualToString:@"edit"];
        BOOL isRetract = [action isEqualToString:@"retract"];
        BOOL isDelete = [action isEqualToString:@"delete"];
        if (!isStatus && !isEdit && !isRetract && !isDelete) {
            writeJSONAndExit(fail(@"bad_request", [NSString stringWithFormat:@"unknown action: %@", action]));
        }

        NSString *chatGuid = nil;
        NSString *messageGuid = nil;
        NSString *text = nil;
        NSInteger partIndex = 0;
        if (!isStatus) {
            id rawChatGuid = req[@"chatGuid"];
            if (![rawChatGuid isKindOfClass:[NSString class]] || [(NSString *)rawChatGuid length] == 0) {
                writeJSONAndExit(fail(@"bad_request", @"chatGuid must be a non-empty string"));
            }
            chatGuid = (NSString *)rawChatGuid;

            id rawMessageGuid = req[@"messageGuid"];
            if (![rawMessageGuid isKindOfClass:[NSString class]] || [(NSString *)rawMessageGuid length] == 0) {
                writeJSONAndExit(fail(@"bad_request", @"messageGuid must be a non-empty string"));
            }
            messageGuid = (NSString *)rawMessageGuid;

            id rawPartIndex = req[@"partIndex"];
            if (rawPartIndex != nil) {
                if (![rawPartIndex isKindOfClass:[NSNumber class]] ||
                    CFGetTypeID((__bridge CFTypeRef)rawPartIndex) == CFBooleanGetTypeID()) {
                    writeJSONAndExit(fail(@"bad_request", @"partIndex must be a non-negative integer"));
                }
                double d = [(NSNumber *)rawPartIndex doubleValue];
                if (!isfinite(d) || floor(d) != d || d < 0 || d > (double)NSIntegerMax) {
                    writeJSONAndExit(fail(@"bad_request", @"partIndex must be a non-negative integer"));
                }
                partIndex = (NSInteger)d;
            }

            if (isEdit) {
                id rawText = req[@"text"];
                if (![rawText isKindOfClass:[NSString class]] || [(NSString *)rawText length] == 0) {
                    writeJSONAndExit(fail(@"bad_request", @"edited text is required"));
                }
                text = (NSString *)rawText;
            }
        }

        if (!loadIMCore()) {
            if (isStatus) {
                writeJSONAndExit(@{ @"capabilities": @{} }); // ⇒ unsupported_selectors
            }
            writeJSONAndExit(fail(@"unsupported", @"IMCore is not available on this Mac"));
        }
        BOOL connected = connectDaemon();
        probeSelectors();

        if (isStatus) {
            // Capabilities reflect real selector availability AND a live daemon
            // connection — without the daemon the actions can't run, so we report
            // them unavailable rather than promising an action that would fail.
            BOOL edit = connected && (gHasEditItem || gHasEditLegacy);
            BOOL retract = connected && gHasRetract;
            BOOL del = connected && gHasDelete;
            writeJSONAndExit(@{ @"capabilities": @{ @"edit": @(edit), @"retract": @(retract), @"delete": @(del) } });
        }

        if (!connected) {
            writeJSONAndExit(fail(@"not_allowed",
                @"could not connect to the Messages daemon — grant Full Disk Access / Automation to the helper"));
        }

        if (isEdit) {
            writeJSONAndExit(doEdit(chatGuid, messageGuid, text, partIndex));
        } else if (isRetract) {
            writeJSONAndExit(doRetract(chatGuid, messageGuid, partIndex));
        } else if (isDelete) {
            writeJSONAndExit(doDelete(chatGuid, messageGuid));
        }
        writeJSONAndExit(fail(@"bad_request", [NSString stringWithFormat:@"unknown action: %@", action]));
    }
    return 0;
}
