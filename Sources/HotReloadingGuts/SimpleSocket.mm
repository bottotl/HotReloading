//
//  SimpleSocket.mm
//  InjectionIII
//
//  Created by John Holdsworth on 06/11/2017.
//  Copyright © 2017 John Holdsworth. All rights reserved.
//
//  $Id: //depot/HotReloading/Sources/HotReloadingGuts/SimpleSocket.mm#63 $
//
//  Server and client primitives for networking through sockets
//  more esailly written in Objective-C than Swift. Subclass to
//  implement service or client that runs on a background thread
//  implemented by overriding the "runInBackground" method.
//

#if DEBUG || !SWIFT_PACKAGE
#import "SimpleSocket.h"

#include <sys/socket.h>
#include <netinet/tcp.h>
#include <net/if.h>
#include <ifaddrs.h>
#include <netdb.h>
#import "PTChannel.h"
#import "InjectionClient.h"

#if 0
#define SLog NSLog
#else
#define SLog while(0) NSLog
#endif

#define MAX_PACKET 16384

typedef union {
    struct {
        __uint8_t       sa_len;         /* total length */
        sa_family_t     sa_family;      /* [XSI] address family */
    };
    struct sockaddr_storage any;
    struct sockaddr_in ip4;
    struct sockaddr addr;
} sockaddr_union;


static const int PTExampleProtocolIPv4PortNumber = 2345;
typedef struct _PTExampleTextFrame {
  uint32_t length;
  uint8_t utf8text[0];
} PTExampleTextFrame;

enum {
  PTExampleFrameTypeDeviceInfo = 100,
  PTExampleFrameTypeTextMessage = 101,
  PTExampleFrameTypePing = 102,
  PTExampleFrameTypePong = 103,
};

static const NSTimeInterval PTAppReconnectDelay = 1.0;

@interface SimpleSocket (PT) <PTChannelDelegate>
- (BOOL)connectViaPeerTalk;
@end

@interface SimpleSocket () {
    NSNumber *connectingToDeviceID_;
    NSNumber *connectedDeviceID_;
    NSDictionary *connectedDeviceProperties_;
    NSDictionary *remoteDeviceInfo_;
    dispatch_queue_t notConnectedQueue_;
    BOOL notConnectedQueueSuspended_;
    PTChannel *connectedChannel_;
    NSDictionary *consoleTextAttributes_;
    NSDictionary *consoleStatusTextAttributes_;
    NSMutableDictionary *pings_;
}

@property (nonatomic, weak) PTChannel *serverChannel;
@property (nonatomic, weak) PTChannel *peerChannel;
@property (nonatomic) dispatch_semaphore_t firstConnectSemaphore;

@property (readonly) NSNumber *connectedDeviceID;
@property PTChannel *connectedChannel;

@end

@interface SimpleSocket (PTMac)
- (void)startListeningForDevices;
- (void)didDisconnectFromDevice:(NSNumber*)deviceID;
- (void)disconnectFromCurrentChannel;
- (void)enqueueConnectToLocalIPv4Port;
- (void)connectToLocalIPv4Port;
- (void)connectToUSBDevice;
- (void)ping;
- (void)presentMessage:(NSString*)message isStatus:(BOOL)isStatus;
@end

@implementation SimpleSocket

@synthesize connectedDeviceID = connectedDeviceID_;

+ (int)error:(NSString *)message {
    NSLog([@"%@/" stringByAppendingString:message],
          self, strerror(errno));
    return -1;
}

+ (void)startServer:(NSString *)address {
    [self performSelectorInBackground:@selector(runServer:) withObject:address];
    
#ifdef INJECTION_III_APP
    SimpleSocket *peertalkSocket = [[SimpleSocket alloc] initWithPeertalkMac];
    
#endif
}

+ (void)forEachInterface:(void (^)(ifaddrs *ifa, in_addr_t addr, in_addr_t mask))handler {
    ifaddrs *addrs;
    if (getifaddrs(&addrs) < 0) {
        [self error:@"Could not getifaddrs: %s"];
        return;
    }
    for (ifaddrs *ifa = addrs; ifa; ifa = ifa->ifa_next)
        if (ifa->ifa_addr->sa_family == AF_INET)
            handler(ifa, ((struct sockaddr_in *)ifa->ifa_addr)->sin_addr.s_addr,
                    ((struct sockaddr_in *)ifa->ifa_netmask)->sin_addr.s_addr);
    freeifaddrs(addrs);
}

+ (void)runServer:(NSString *)address {
    sockaddr_union serverAddr;
    [self parseV4Address:address into:&serverAddr.any];

    int serverSocket = [self newSocket:serverAddr.sa_family];
    if (serverSocket < 0)
        return;

    if (bind(serverSocket, &serverAddr.addr, serverAddr.sa_len) < 0)
        [self error:@"Could not bind service socket: %s"];
    else if (listen(serverSocket, 5) < 0)
        [self error:@"Service socket would not listen: %s"];
    else
        while (TRUE) {
            sockaddr_union clientAddr;
            socklen_t addrLen = sizeof clientAddr;

            int clientSocket = accept(serverSocket, &clientAddr.addr, &addrLen);
            if (clientSocket > 0) {
                int yes = 1;
                if (setsockopt(clientSocket, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof yes) < 0)
                    [self error:@"Could not set SO_NOSIGPIPE: %s"];
                @autoreleasepool {
                    struct sockaddr_in *v4Addr = &clientAddr.ip4;
                    NSLog(@"Connection from %s:%d\n",
                          inet_ntoa(v4Addr->sin_addr), ntohs(v4Addr->sin_port));
                    SimpleSocket *client = [[self alloc] initSocket:clientSocket];
                    client.isLocalClient =
                        v4Addr->sin_addr.s_addr == htonl(INADDR_LOOPBACK);
                    [self forEachInterface:^(ifaddrs *ifa, in_addr_t addr, in_addr_t mask) {
                        if (v4Addr->sin_addr.s_addr == addr)
                            client.isLocalClient = TRUE;
                    }];
                    [client run];
                }
            }
            else
                [NSThread sleepForTimeInterval:.5];
        }
}

+ (instancetype)connectTo:(NSString *)address {
    if ([address hasPrefix:@"peertalk"]) {
        SimpleSocket *socket = [[self alloc] initWithPeertalk];
        BOOL success = [socket connectViaPeerTalk];
        return success ? socket : nil;
    }
    
    sockaddr_union serverAddr;
    [self parseV4Address:address into:&serverAddr.any];

    int clientSocket = [self newSocket:serverAddr.sa_family];
    if (clientSocket < 0)
        return nil;

    if (connect(clientSocket, &serverAddr.addr, serverAddr.sa_len) < 0) {
        [self error:@"Could not connect: %s"];
        return nil;
    }

    return [[self alloc] initSocket:clientSocket];
}

+ (int)newSocket:(sa_family_t)addressFamily {
    int newSocket, yes = 1;
    if ((newSocket = socket(addressFamily, SOCK_STREAM, 0)) < 0)
        [self error:@"Could not open service socket: %s"];
    else if (setsockopt(newSocket, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof yes) < 0)
        [self error:@"Could not set SO_REUSEADDR: %s"];
    else if (setsockopt(newSocket, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof yes) < 0)
        [self error:@"Could not set SO_NOSIGPIPE: %s"];
    else if (setsockopt(newSocket, IPPROTO_TCP, TCP_NODELAY, &yes, sizeof yes) < 0)
        [self error:@"Could not set TCP_NODELAY: %s"];
    else if (fcntl(newSocket, F_SETFD, FD_CLOEXEC) < 0)
        [self error:@"Could not set FD_CLOEXEC: %s"];
    else
        return newSocket;
    return -1;
}

/**
 * Available formats
 * @"<host>[:<port>]"
 * where <host> can be NNN.NNN.NNN.NNN or hostname, empty for localhost or * for all interfaces
 * The default port is 80 or a specific number to bind or an empty string to allocate any port
 */
+ (BOOL)parseV4Address:(NSString *)address into:(struct sockaddr_storage *)serverAddr {
    NSArray<NSString *> *parts = [address componentsSeparatedByString:@":"];

    struct sockaddr_in *v4Addr = (struct sockaddr_in *)serverAddr;
    bzero(v4Addr, sizeof *v4Addr);

    v4Addr->sin_family = AF_INET;
    v4Addr->sin_len = sizeof *v4Addr;
    v4Addr->sin_port = htons(parts.count > 1 ? parts[1].intValue : 80);

    const char *host = parts[0].UTF8String;

    if (!host[0])
        v4Addr->sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    else if (host[0] == '*')
        v4Addr->sin_addr.s_addr = htonl(INADDR_ANY);
    else if (isdigit(host[0]))
        v4Addr->sin_addr.s_addr = inet_addr(host);
    else if (struct hostent *hp = gethostbyname2(host, v4Addr->sin_family))
        memcpy(&v4Addr->sin_addr, hp->h_addr, hp->h_length);
    else {
        [self error:[NSString stringWithFormat:@"Unable to look up host for %@", address]];
        return FALSE;
    }

    return TRUE;
}

- (instancetype)initSocket:(int)socket {
    if ((self = [super init])) {
        clientSocket = socket;
    }
    return self;
}


- (instancetype)initWithPeertalkMac {
    if ((self = [super init])) {
        // Start listening for device attached/detached notifications on mac
        [self startListeningForDevices];
        
        // Start trying to connect to local IPv4 port (defined in PTExampleProtocol.h)
        [self enqueueConnectToLocalIPv4Port];
        
        // Put a little message in the UI
        [self presentMessage:@"Ready for action — connecting at will." isStatus:YES];
        
        // Start pinging
        [self ping];
    }
    return self;
}

- (instancetype)initWithPeertalk {
    if (self = [super init]) {
        _firstConnectSemaphore = dispatch_semaphore_create(0);
        PTChannel *channel = [PTChannel channelWithDelegate:self];
        [channel listenOnPort:PTProtocolIPv4PortNumber IPv4Address:INADDR_LOOPBACK callback:^(NSError *error) {
            if (error) {
            } else {
                self.serverChannel = channel;
            }
        }];
    }
    return self;
}

- (void)run {
    [self performSelectorInBackground:@selector(runInBackground) withObject:nil];
}

- (void)runInBackground {
    [[self class] error:@"-[SimpleSocket runInBackground] not implemented in subclass"];
}

typedef ssize_t (*io_func)(int, void *, size_t);

- (BOOL)perform:(io_func)io ofBytes:(const void *)buffer
         length:(size_t)length cmd:(SEL)cmd {
    size_t bytes, ptr = 0;
    SLog(@"#%d %s %lu [%p] %s", clientSocket, io == read ?
         "<-" : "->", length, buffer, sel_getName(cmd));
    while (ptr < length && (bytes = io(clientSocket,
        (char *)buffer+ptr, MIN(length-ptr, MAX_PACKET))) > 0)
        ptr += bytes;
    if (ptr < length) {
        NSLog(@"[%@ %s:%p length:%lu] error: %lu %s",
              self, sel_getName(cmd), buffer, length, ptr, strerror(errno));
        return FALSE;
    }
    return TRUE;
}

- (BOOL)readBytes:(void *)buffer length:(size_t)length cmd:(SEL)cmd {
    return [self perform:read ofBytes:buffer length:length cmd:cmd];
}

- (int)readInt {
    int32_t anint = ~0;
    if (![self readBytes:&anint length:sizeof anint cmd:_cmd])
        return ~0;
    SLog(@"#%d <- %d", clientSocket, anint);
    return anint;
}

- (void *)readPointer {
    void *aptr = (void *)~0;
    if (![self readBytes:&aptr length:sizeof aptr cmd:_cmd])
        return aptr;
    SLog(@"#%d <- %p", clientSocket, aptr);
    return aptr;
}

- (NSData *)readData {
    size_t length = [self readInt];
    void *bytes = malloc(length);
    if (!bytes || ![self readBytes:bytes length:length cmd:_cmd])
        return nil;
    return [NSData dataWithBytesNoCopy:bytes length:length freeWhenDone:YES];
}

- (NSString *)readString {
    NSString *str = [[NSString alloc] initWithData:[self readData]
                                          encoding:NSUTF8StringEncoding];
    SLog(@"#%d <- %d '%@'", clientSocket, (int)str.length, str);
    return str;
}

- (BOOL)writeBytes:(const void *)buffer length:(size_t)length cmd:(SEL)cmd {
    return [self perform:(io_func)write ofBytes:buffer length:length cmd:cmd];
}

- (BOOL)writeInt:(int)length {
    SLog(@"#%d %d ->", clientSocket, length);
    return [self writeBytes:&length length:sizeof length cmd:_cmd];
}

- (BOOL)writePointer:(void *)ptr {
    SLog(@"#%d %p ->", clientSocket, ptr);
    return [self writeBytes:&ptr length:sizeof ptr cmd:_cmd];
}

- (BOOL)writeData:(NSData *)data {
    uint32_t length = (uint32_t)data.length;
    SLog(@"#%d [%d] ->", clientSocket, length);
    return [self writeInt:length] &&
        [self writeBytes:data.bytes length:length cmd:_cmd];
}

- (BOOL)writeString:(NSString *)string {
    NSData *data = [string dataUsingEncoding:NSUTF8StringEncoding];
    SLog(@"#%d %d '%@' ->", clientSocket, (int)data.length, string);
    return [self writeData:data];
}

- (BOOL)writeCommand:(int)command withString:(NSString *)string {
    return [self writeInt:command] &&
        (!string || [self writeString:string]);
}

- (void)dealloc {
    close(clientSocket);
}

/// Hash used to differentiate HotReloading users on network.
/// Derived from path to source file in project's DerivedData.
+ (int)multicastHash {
    #ifdef INJECTION_III_APP
    const char *key = [[NSBundle bundleForClass:self]
        .infoDictionary[@"UserHome"] UTF8String] ?:
        NSHomeDirectory().UTF8String;
    #else
    NSString *file = [NSString stringWithUTF8String:__FILE__];
    const char *key = [file
       stringByReplacingOccurrencesOfString: @"(/Users/[^/]+).*"
           withString: @"$1" options: NSRegularExpressionSearch
               range: NSMakeRange(0, file.length)].UTF8String;
    #endif
    int hash = 0;
    for (size_t i=0, len = strlen(key); i<len; i++)
        hash = hash*5 ^ (i+3)%15*key[i];
    return hash;
}

struct multicast_socket_packet {
    int version, hash;
    char host[256];
};

/// Used for HotReloading clients to find their controlling Mac.
/// @param multicast MULTICAST address to use
/// @param port Port identifier of form ":NNNN"
+ (void)multicastServe:(const char *)multicast port:(const char *)port {
    #ifdef DEVELOPER_HOST
    if (isdigit(DEVELOPER_HOST[0]))
        return;
    #endif

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof addr);
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY); /* N.B.: differs from sender */
    if (const char *colon = index(port, ':'))
        port = colon+1;
    addr.sin_port = htons(atoi(port));

    /* create what looks like an ordinary UDP socket */
    int multicastSocket, yes = 1;
    if ((multicastSocket = socket(AF_INET, SOCK_DGRAM, 0)) < 0)
        [self error:@"Could not get mutlicast socket: %s"];
    else if (fcntl(multicastSocket, F_SETFD, FD_CLOEXEC) < 0)
        [self error:@"Could not set close exec: %s"];
    else if (setsockopt(multicastSocket, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof yes) < 0)
        [self error:@"Could not reuse mutlicast socket addr: %s"];
    else if (bind(multicastSocket, (struct sockaddr *)&addr, sizeof addr) < 0)
        [self error:@"Could not bind mutlicast socket addr: %s. "
         "Once this starts occuring, a reboot may be necessary. "
         "Or, you can hardcode the IP address of your Mac as the "
         "the value for 'hostname' in HotReloading/Package.swift."];
    else
        [self performSelectorInBackground:@selector(multicastListen:)
                               withObject:[NSNumber numberWithInt:multicastSocket]];
}

/// Listens for clients looking to connect and if the hash matches, replies.
/// @param socket Multicast socket as NSNumber
+ (void)multicastListen:(NSNumber *)socket {
    int multicastSocket = [socket intValue];
    while (multicastSocket) {
        struct sockaddr_in addr;
        socklen_t addrlen = sizeof addr;
        struct multicast_socket_packet msgbuf;

        if (recvfrom(multicastSocket, &msgbuf, sizeof msgbuf, 0,
                     (struct sockaddr *)&addr, &addrlen) < sizeof msgbuf) {
            [self error:@"Could not receive from multicast: %s"];
            sleep(1);
            continue;
        }

        NSLog(@"%@: Multicast recvfrom %s (%s) %u c.f. %u\n",
              self, msgbuf.host, inet_ntoa(addr.sin_addr),
              [self multicastHash], msgbuf.hash);

        gethostname(msgbuf.host, sizeof msgbuf.host);
        if ([self multicastHash] == msgbuf.hash &&
            sendto(multicastSocket, &msgbuf, sizeof msgbuf, 0,
                   (struct sockaddr *)&addr, addrlen) < sizeof msgbuf) {
            [self error:@"Could not send to multicast: %s"];
            sleep(1);
        }
    }
}

/// Client end of multicast means of determining address of server
/// @param multicast Multicast IP address to use.
/// @param port Port number as string.
/// @param format Format for connecting message.
+ (NSString *)getMulticastService:(const char *)multicast
    port:(const char *)port message:(const char *)format {
    #ifdef DEVELOPER_HOST
    if (isdigit(DEVELOPER_HOST[0]))
        return @DEVELOPER_HOST;
    #else
    #define DEVELOPER_HOST "127.0.0.1"
    #endif

    static struct sockaddr_in addr;
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    if (const char *colon = index(port, ':'))
        port = colon+1;
    addr.sin_port = 0;

    // For a real device, we have to use multicast
    // to locate the developer's Mac to connect to.
    int multicastSocket, yes = 1;
    if ((multicastSocket = socket(addr.sin_family, SOCK_DGRAM, 0)) < 0) {
        [self error:@"Could not get broadcast socket: %s"];
        return @DEVELOPER_HOST;
    }
    if (setsockopt(multicastSocket, SOL_SOCKET, SO_BROADCAST, &yes, sizeof yes) < 0) {
        [self error:@"Could not setsockopt: %s"];
        close(multicastSocket);
        return @DEVELOPER_HOST;
    }

    struct multicast_socket_packet msgbuf;
    msgbuf.version = 1;
    msgbuf.hash = [self multicastHash];
    gethostname(msgbuf.host, sizeof msgbuf.host);

    addr.sin_port = htons(atoi(port));
    [self forEachInterface:^(ifaddrs *ifa, in_addr_t laddr, in_addr_t nmask) {
        switch (ntohl(laddr) >> 24) {
            case 10: // mobile network
//            case 172: // hotspot
            case 127: // loopback
                return;
        }
        int idx = if_nametoindex(ifa->ifa_name);
        setsockopt(multicastSocket, IPPROTO_IP, IP_BOUND_IF, &idx, sizeof idx);
        addr.sin_addr.s_addr = laddr | ~nmask;
        printf("Broadcasting to %s.%d:%s to locate InjectionIII host...\n",
               ifa->ifa_name, idx, inet_ntoa(addr.sin_addr));
        if (sendto(multicastSocket, &msgbuf, sizeof msgbuf, 0,
                   (struct sockaddr *)&addr, sizeof addr) < 0)
            [self error:@"Could not send broadcast ping: %s"];
    }];

    socklen_t addrlen = sizeof addr;
    while (recvfrom(multicastSocket, &msgbuf, sizeof msgbuf, 0,
                    (struct sockaddr *)&addr, &addrlen) < sizeof msgbuf) {
        [self error:@"%s: Error receiving from broadcast: %s"];
        sleep(1);
    }

    const char *ipaddr = inet_ntoa(addr.sin_addr);
    printf(format, msgbuf.host, ipaddr);
    close(multicastSocket);
    return [NSString stringWithUTF8String:ipaddr];
}

@end

@implementation SimpleSocket (PT)

- (BOOL)connectViaPeerTalk {
    NSAssert(![NSThread isMainThread], @"should not call in main thread, peertalk will dispatch msg on main thread");
    intptr_t result = dispatch_semaphore_wait(_firstConnectSemaphore, DISPATCH_TIME_FOREVER);
    return result;
}

- (void)ioFrameChannel:(PTChannel*)channel didAcceptConnection:(PTChannel*)otherChannel fromAddress:(PTAddress*)address {
    // Cancel any other connection. We are FIFO, so the last connection
    // established will cancel any previous connection and "take its place".
    if (self.peerChannel) {
        [self.peerChannel cancel];
    }
    
    self.peerChannel = otherChannel;
    self.peerChannel.userInfo = address;
    NSLog(@"[peertalk] Connected to %@", address);
    
    dispatch_semaphore_signal(self.firstConnectSemaphore);
}

- (void)ioFrameChannel:(PTChannel *)channel didReceiveFrameOfType:(uint32_t)type tag:(uint32_t)tag payload:(nullable NSData *)payload {
    
}

@end

@implementation SimpleSocket (PTMac)

- (PTChannel*)connectedChannel {
  return connectedChannel_;
}

- (void)setConnectedChannel:(PTChannel*)connectedChannel {
  connectedChannel_ = connectedChannel;
  
  // Toggle the notConnectedQueue_ depending on if we are connected or not
  if (!connectedChannel_ && notConnectedQueueSuspended_) {
    dispatch_resume(notConnectedQueue_);
    notConnectedQueueSuspended_ = NO;
  } else if (connectedChannel_ && !notConnectedQueueSuspended_) {
    dispatch_suspend(notConnectedQueue_);
    notConnectedQueueSuspended_ = YES;
  }
  
  if (!connectedChannel_ && connectingToDeviceID_) {
    [self enqueueConnectToUSBDevice];
  }
}


#pragma mark - Ping

- (void)pongWithTag:(uint32_t)tagno error:(NSError*)error {
  NSNumber *tag = [NSNumber numberWithUnsignedInt:tagno];
  NSMutableDictionary *pingInfo = [pings_ objectForKey:tag];
  if (pingInfo) {
    NSDate *now = [NSDate date];
    [pingInfo setObject:now forKey:@"date ended"];
    [pings_ removeObjectForKey:tag];
    NSLog(@"Ping total roundtrip time: %.3f ms", [now timeIntervalSinceDate:[pingInfo objectForKey:@"date created"]]*1000.0);
  }
}


- (void)ping {
  if (connectedChannel_) {
    if (!pings_) {
      pings_ = [NSMutableDictionary dictionary];
    }
    uint32_t tagno = [connectedChannel_.protocol newTag];
    NSNumber *tag = [NSNumber numberWithUnsignedInt:tagno];
    NSMutableDictionary *pingInfo = [NSMutableDictionary dictionaryWithObjectsAndKeys:[NSDate date], @"date created", nil];
    [pings_ setObject:pingInfo forKey:tag];
    [connectedChannel_ sendFrameOfType:PTExampleFrameTypePing tag:tagno withPayload:nil callback:^(NSError *error) {
      [self performSelector:@selector(ping) withObject:nil afterDelay:1.0];
      [pingInfo setObject:[NSDate date] forKey:@"date sent"];
      if (error) {
        [self->pings_ removeObjectForKey:tag];
      }
    }];
  } else {
    [self performSelector:@selector(ping) withObject:nil afterDelay:1.0];
  }
}


#pragma mark - PTChannelDelegate
- (BOOL)ioFrameChannel:(PTChannel*)channel shouldAcceptFrameOfType:(uint32_t)type tag:(uint32_t)tag payloadSize:(uint32_t)payloadSize {
  if (   type != PTExampleFrameTypeDeviceInfo
      && type != PTExampleFrameTypeTextMessage
      && type != PTExampleFrameTypePing
      && type != PTExampleFrameTypePong
      && type != PTFrameTypeEndOfStream) {
    NSLog(@"Unexpected frame of type %u", type);
    [channel close];
    return NO;
  } else {
    return YES;
  }
}

- (void)ioFrameChannel:(PTChannel*)channel didReceiveFrameOfType:(uint32_t)type tag:(uint32_t)tag payload:(NSData *)payload {
  //NSLog(@"received %@, %u, %u, %@", channel, type, tag, payload);
  if (type == PTExampleFrameTypeDeviceInfo) {
        NSDictionary *deviceInfo = [NSData dictionaryWithContentsOfData:payload];
    [self presentMessage:[NSString stringWithFormat:@"Connected to %@", deviceInfo.description] isStatus:YES];
  } else if (type == PTExampleFrameTypeTextMessage) {
    PTExampleTextFrame *textFrame = (PTExampleTextFrame*)payload.bytes;
    textFrame->length = ntohl(textFrame->length);
    NSString *message = [[NSString alloc] initWithBytes:textFrame->utf8text length:textFrame->length encoding:NSUTF8StringEncoding];
    [self presentMessage:[NSString stringWithFormat:@"[%@]: %@", channel.userInfo, message] isStatus:NO];
  } else if (type == PTExampleFrameTypePong) {
    [self pongWithTag:tag error:nil];
  }
}

- (void)ioFrameChannel:(PTChannel*)channel didEndWithError:(NSError*)error {
  if (connectedDeviceID_ && [connectedDeviceID_ isEqualToNumber:channel.userInfo]) {
    [self didDisconnectFromDevice:connectedDeviceID_];
  }
  
  if (connectedChannel_ == channel) {
    [self presentMessage:[NSString stringWithFormat:@"Disconnected from %@", channel.userInfo] isStatus:YES];
    self.connectedChannel = nil;
  }
}

- (void)presentMessage:(NSString*)message isStatus:(BOOL)isStatus {
  NSLog(@">> %@", message);
}

#pragma mark - Wired device connections


- (void)startListeningForDevices {
  NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
  
  [nc addObserverForName:PTUSBDeviceDidAttachNotification object:PTUSBHub.sharedHub queue:nil usingBlock:^(NSNotification *note) {
    NSNumber *deviceID = [note.userInfo objectForKey:PTUSBHubNotificationKeyDeviceID];
    //NSLog(@"PTUSBDeviceDidAttachNotification: %@", note.userInfo);
    NSLog(@"PTUSBDeviceDidAttachNotification: %@", deviceID);

    dispatch_async(self->notConnectedQueue_, ^{
      if (!self->connectingToDeviceID_ || ![deviceID isEqualToNumber:self->connectingToDeviceID_]) {
        [self disconnectFromCurrentChannel];
                self->connectingToDeviceID_ = deviceID;
                self->connectedDeviceProperties_ = [note.userInfo objectForKey:PTUSBHubNotificationKeyProperties];
        [self enqueueConnectToUSBDevice];
      }
    });
  }];
  
  [nc addObserverForName:PTUSBDeviceDidDetachNotification object:PTUSBHub.sharedHub queue:nil usingBlock:^(NSNotification *note) {
    NSNumber *deviceID = [note.userInfo objectForKey:PTUSBHubNotificationKeyDeviceID];
    //NSLog(@"PTUSBDeviceDidDetachNotification: %@", note.userInfo);
    NSLog(@"PTUSBDeviceDidDetachNotification: %@", deviceID);
    
    if ([self->connectingToDeviceID_ isEqualToNumber:deviceID]) {
            self->connectedDeviceProperties_ = nil;
            self->connectingToDeviceID_ = nil;
      if (self->connectedChannel_) {
        [self->connectedChannel_ close];
      }
    }
  }];
}


- (void)didDisconnectFromDevice:(NSNumber*)deviceID {
  NSLog(@"Disconnected from device");
  if ([connectedDeviceID_ isEqualToNumber:deviceID]) {
    [self willChangeValueForKey:@"connectedDeviceID"];
    connectedDeviceID_ = nil;
    [self didChangeValueForKey:@"connectedDeviceID"];
  }
}


- (void)disconnectFromCurrentChannel {
  if (connectedDeviceID_ && connectedChannel_) {
    [connectedChannel_ close];
    self.connectedChannel = nil;
  }
}


- (void)enqueueConnectToLocalIPv4Port {
  dispatch_async(notConnectedQueue_, ^{
    dispatch_async(dispatch_get_main_queue(), ^{
      [self connectToLocalIPv4Port];
    });
  });
}


- (void)connectToLocalIPv4Port {
  PTChannel *channel = [PTChannel channelWithDelegate:self];
  channel.userInfo = [NSString stringWithFormat:@"127.0.0.1:%d", PTExampleProtocolIPv4PortNumber];
  [channel connectToPort:PTExampleProtocolIPv4PortNumber IPv4Address:INADDR_LOOPBACK callback:^(NSError *error, PTAddress *address) {
    if (error) {
      if (error.domain == NSPOSIXErrorDomain && (error.code == ECONNREFUSED || error.code == ETIMEDOUT)) {
        // this is an expected state
      } else {
        NSLog(@"Failed to connect to 127.0.0.1:%d: %@", PTExampleProtocolIPv4PortNumber, error);
      }
    } else {
      [self disconnectFromCurrentChannel];
      self.connectedChannel = channel;
      channel.userInfo = address;
      NSLog(@"Connected to %@", address);
    }
    [self performSelector:@selector(enqueueConnectToLocalIPv4Port) withObject:nil afterDelay:PTAppReconnectDelay];
  }];
}


- (void)enqueueConnectToUSBDevice {
  dispatch_async(notConnectedQueue_, ^{
    dispatch_async(dispatch_get_main_queue(), ^{
      [self connectToUSBDevice];
    });
  });
}


- (void)connectToUSBDevice {
  PTChannel *channel = [PTChannel channelWithDelegate:self];
  channel.userInfo = connectingToDeviceID_;
  channel.delegate = self;
  
  [channel connectToPort:PTExampleProtocolIPv4PortNumber overUSBHub:PTUSBHub.sharedHub deviceID:connectingToDeviceID_ callback:^(NSError *error) {
    if (error) {
      if (error.domain == PTUSBHubErrorDomain && error.code == PTUSBHubErrorConnectionRefused) {
        NSLog(@"Failed to connect to device #%@: %@", channel.userInfo, error);
      } else {
        NSLog(@"Failed to connect to device #%@: %@", channel.userInfo, error);
      }
      if (channel.userInfo == self->connectingToDeviceID_) {
        [self performSelector:@selector(enqueueConnectToUSBDevice) withObject:nil afterDelay:PTAppReconnectDelay];
      }
    } else {
            self->connectedDeviceID_ = self->connectingToDeviceID_;
      self.connectedChannel = channel;
    }
  }];
}

@end
#endif
