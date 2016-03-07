//
//  MinimedPacket.m
//  GlucoseLink
//
//  Created by Pete Schwamb on 8/5/14.
//  Copyright (c) 2014 Pete Schwamb. All rights reserved.
//

#import "MinimedPacket.h"
#import "NSData+Conversion.h"
#import "CRC8.h"
#import "PumpStatusMessage.h"
#import "DeviceLinkMessage.h"
#import "FindDeviceMessage.h"
#import "MeterMessage.h"


@implementation MinimedPacket

- (instancetype)init NS_UNAVAILABLE
{
    return nil;
}

- (nonnull instancetype)initWithRFPacket:(nonnull RFPacket*)packet {
  self = [super init];
  if (self) {
    if (packet.data.length <= 2) {
      return nil;
    }
    _data = packet.data;
    _rssi = packet.rssi;
  }
  return self;
}

- (instancetype)initWithData:(NSData*)data
{
  self = [super init];
  if (self) {
    _data = data;
  }
  return self;
}

- (unsigned char)byteAt:(NSInteger)index {
  if (_data && index < [_data length]) {
    return ((unsigned char*)[_data bytes])[index];
  } else {
    return 0;
  }
}

- (PacketType) packetType {
  return [self byteAt:0];
}

- (MessageType) messageType {
  return [self byteAt:4];
}

- (NSString*) address {
  return [NSString stringWithFormat:@"%02x%02x%02x", [self byteAt:1], [self byteAt:2], [self byteAt:3]];
}

- (MessageBase*)toMessage {
  if (self.packetType == PacketTypeSentry) {
    switch (self.messageType) {
      case MESSAGE_TYPE_PUMP_STATUS:
        return [[PumpStatusMessage alloc] initWithData:_data];
      case MESSAGE_TYPE_DEVICE_LINK:
        return [[DeviceLinkMessage alloc] initWithData:_data];
      case MESSAGE_TYPE_FIND_DEVICE:
        return [[FindDeviceMessage alloc] initWithData:_data];
    }
  } else if (self.packetType == PacketTypeMeter) {
    return [[MeterMessage alloc] initWithData:_data];
  }
  return nil;
}



@end
