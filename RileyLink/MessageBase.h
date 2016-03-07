//
//  MessageBase.h
//  GlucoseLink
//
//  Created by Pete Schwamb on 5/26/15.
//  Copyright (c) 2015 Pete Schwamb. All rights reserved.
//

#import <Foundation/Foundation.h>

typedef NS_ENUM(unsigned char, PacketType) {
  PacketTypeSentry    = 0xa2,
  PacketTypeMeter     = 0xa5,
  PacketTypeCarelink  = 0xa7,
  PacketTypeSensor    = 0xa8
};

typedef NS_ENUM(unsigned char, MessageType) {
  MESSAGE_TYPE_ALERT = 0x01,
  MESSAGE_TYPE_ALERT_CLEARED = 0x02,
  MESSAGE_TYPE_DEVICE_TEST = 0x03,
  MESSAGE_TYPE_PUMP_STATUS = 0x04,
  MESSAGE_TYPE_ACK = 0x06,
  MESSAGE_TYPE_PUMP_BACKFILL = 0x08,
  MESSAGE_TYPE_FIND_DEVICE = 0x09,
  MESSAGE_TYPE_DEVICE_LINK = 0x0a,
  MESSAGE_TYPE_PUMP_DUMP = 0x0a,
  MESSAGE_TYPE_POWER = 0x5d,
  MESSAGE_TYPE_BUTTON_PRESS = 0x5b,
  MESSAGE_TYPE_GET_PUMP_MODEL = 0x8d,
  MESSAGE_TYPE_GET_BATTERY = 0x72,
  MESSAGE_TYPE_READ_HISTORY = 0x80,
};

@interface MessageBase : NSObject

@property (nonatomic, nonnull, readonly, strong) NSData *data;

- (nonnull instancetype)initWithData:(nonnull NSData*)data NS_DESIGNATED_INITIALIZER;
@property (nonatomic, nonnull, readonly, copy) NSDictionary *bitBlocks;
- (NSInteger) getBits:(nullable NSString*)key;
- (void) setBits:(nonnull NSString*)key toValue:(NSInteger)val;
- (unsigned char) getBitAtIndex:(NSInteger)idx;
@property (NS_NONATOMIC_IOSONLY, readonly) NSInteger bitsOffset;

@property (nonatomic, readonly) PacketType packetType;
@property (nonatomic, readonly) MessageType messageType;
@property (nonatomic, nonnull, readonly, copy) NSString *address;

@end
