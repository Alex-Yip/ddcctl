//
//  ddcctl.m
//  query and control monitors through their on-wire data channels and OSD microcontrollers
//  http://en.wikipedia.org/wiki/Display_Data_Channel#DDC.2FCI
//  http://en.wikipedia.org/wiki/Monitor_Control_Command_Set
//
//  Copyright Joey Korkames 2014 http://github.com/kfix
//  Licensed under GPLv3, full text at http://www.gnu.org/licenses/gpl-3.0.txt
//
//

#ifdef NDEBUG
#define MyLog(...) (void)printf("%s\n",[[NSString stringWithFormat:__VA_ARGS__] UTF8String])
#else
#define MyLog NSLog
#endif

#import <Foundation/Foundation.h>
#import <AppKit/NSScreen.h>
#import "DDC.h"

NSString *EDIDString(char *string)
{
    NSString *temp = [[NSString alloc] initWithBytes:string length:13 encoding:NSASCIIStringEncoding];
    return ([temp rangeOfString:@"\n"].location != NSNotFound)
    ? [[temp componentsSeparatedByString:@"\n"] objectAtIndex:0]
    : temp;
}

uint get_control(CGDirectDisplayID cdisplay, uint control_id)
{
   struct DDCReadCommand command;
   command.control_id = control_id;
   command.max_value = 0;
   command.current_value = 0;

   MyLog(@"D: querying VCP control: #%u =?", command.control_id);
   if (!DDCRead(cdisplay, &command)){
       MyLog(@"E: DDC send command failed!");
       MyLog(@"E: VCP control #%u = current: %u, max: %u", command.control_id, command.current_value, command.max_value);
   } else {
       MyLog(@"I: VCP control #%u = current: %u, max: %u", command.control_id, command.current_value, command.max_value);
   }
   return command.current_value;
}

void set_control(CGDirectDisplayID cdisplay, uint control_id, uint new_value)
{
   struct DDCWriteCommand command;
   command.control_id = control_id;
   command.new_value = new_value;

   MyLog(@"D: setting VCP control #%u => %u", command.control_id, command.new_value);
   if (!DDCWrite(cdisplay, &command)){
       MyLog(@"E: Failed to send DDC command!");
   }
}

int main(int argc, const char * argv[])
{

    @autoreleasepool {
        
        NSPointerArray *_displayIDs = [NSPointerArray pointerArrayWithOptions:NSPointerFunctionsOpaqueMemory | NSPointerFunctionsIntegerPersonality];
        
        for (NSScreen *screen in NSScreen.screens) {
            if ([screen.deviceDescription objectForKey:@"NSDeviceIsScreen"]) {
               CGDirectDisplayID new = [[screen.deviceDescription objectForKey:@"NSScreenNumber"] unsignedIntValue];
              [_displayIDs addPointer:(void *)(UInt64)new];
            }
        }
        MyLog(@"I: found %lu displays",[_displayIDs count]);
        
        NSDictionary *argpairs = [[NSUserDefaults standardUserDefaults] volatileDomainForName:NSArgumentDomain];
        NSDictionary *switches = @{ // @MCCS:VCP codes we support from http://wenku.baidu.com/view/9a94824c767f5acfa1c7cd80.html
                                   @"b": @BRIGHTNESS,
                                   @"c": @CONTRAST,
                                   @"d": @-1, //set_display consumed by app
                                   @"i": @INPUT_SOURCE, //pg85
                                   @"m": @AUDIO_MUTE,
                                   @"s": @AUDIO_SPEAKER_VOLUME, //pg94
                                   }; //should test against http://www.entechtaiwan.com/lib/softmccs.shtm
        
        NSUInteger set_display = [[NSUserDefaults standardUserDefaults] integerForKey:@"d"];
        if (0 < set_display && set_display <= [_displayIDs count])
        {
            MyLog(@"I: polling display %lu's EDID", set_display);
            CGDirectDisplayID cdisplay = (CGDirectDisplayID)[_displayIDs pointerAtIndex:set_display - 1];
            struct EDID edid = {};
            if (EDIDTest(cdisplay, &edid)) {
                for (NSValue *value in @[[NSValue valueWithPointer:&edid.descriptor1], [NSValue valueWithPointer:&edid.descriptor2], [NSValue valueWithPointer:&edid.descriptor3], [NSValue valueWithPointer:&edid.descriptor4]]) {
                    union descriptor *des = value.pointerValue;
                    switch (des->text.type) {
                        case 0xFF:
                            MyLog(@"I: got edid.serial: %@",EDIDString(des->text.data));
                            break;
                        case 0xFC:
                            MyLog(@"I: got edid.name: %@",EDIDString(des->text.data));
                            break;
                    }
                }
                [argpairs enumerateKeysAndObjectsUsingBlock:^(id argname, NSString* argval, BOOL *stop) {
                    MyLog(@"D: command arg-pair: %@: %@", argname, argval);

                    NSInteger control_id = [[switches valueForKey:argname] intValue];
                    if (control_id > -1){ //this is a valid monitor control from switches
                        
                        sleep(0.1); //stagger comms to these wimpy I2C mcu's

                        NSString *argval_num = [argval stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"-+"]]; //look for relative setting ops
                        if (argval != argval_num) { //relative setting: read, calculate, then write

                           NSString *formula = [NSString stringWithFormat:@"%lu %@ %@", 
                               get_control(cdisplay, control_id), //current
                               [argval substringFromIndex:argval.length - 1], //OP
                               argval_num //new
                           ];
                           NSExpression *exp = [NSExpression expressionWithFormat:formula];
                           NSNumber *set_value = [exp expressionValueWithObject:nil context:nil];
                           MyLog(@"D: relative setting: %@ = %d", formula, set_value.intValue);

                           if (set_value.intValue >= 0) {
                              set_control(cdisplay, control_id, set_value.unsignedIntValue);
                           }

                        } else if ([argval hasPrefix:@"?"])  { //read current setting
                           get_control(cdisplay, control_id);

                        } else { //write fixed setting
                           set_control(cdisplay, control_id, [argval intValue]);
                        }

                    }
                }];

            } else {
                MyLog(@"E: Failed to poll display!");
                return -1;
            }
        } else { //no display id given
            MyLog(@"Usage:\n ddcctl -d <1-..> [display#]\n\t-b <1-..> [brightness]\n\t-c <1-..> [contrast]\n\t-m <1|2> [mute speaker OFF/ON]\n\t-v <1-254> [speaker volume]\n\t-i <1-12> [select input source]\n -X ? (queries setting X)\n -X <NN>- (decreases setting X by NN)\n -X <NN>+ (increases setting X by NN)");
        }
    }
    return 0;
}
