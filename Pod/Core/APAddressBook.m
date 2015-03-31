//
//  APAddressBook.m
//  APAddressBook
//
//  Created by Alexey Belkevich on 1/10/14.
//  Copyright (c) 2014 alterplay. All rights reserved.
//

#import <AddressBook/AddressBook.h>
#import "APAddressBook.h"
#import "APContact.h"
#import "APPhoneWithLabel.h"

void APAddressBookExternalChangeCallback(ABAddressBookRef addressBookRef, CFDictionaryRef info,
                                         void *context);

@interface APAddressBook ()
@property (nonatomic, readonly) ABAddressBookRef addressBook;
@property (nonatomic, readonly) dispatch_queue_t localQueue;
@property (nonatomic, copy) void (^changeCallback)();
@end

@implementation APAddressBook

#pragma mark - life cycle

- (id)init
{
    self = [super init];
    if (self)
    {
        CFErrorRef *error = NULL;
        _addressBook = ABAddressBookCreateWithOptions(NULL, error);
        if (error)
        {
            NSLog(@"%@", (__bridge_transfer NSString *)CFErrorCopyFailureReason(*error));
            return nil;
        }
        NSString *name = [NSString stringWithFormat:@"com.alterplay.addressbook.%ld",
                          (long)self.hash];
        _localQueue = dispatch_queue_create([name cStringUsingEncoding:NSUTF8StringEncoding], NULL);
        self.fieldsMask = APContactFieldDefault;
    }
    return self;
}

- (void)dealloc
{
    [self stopObserveChanges];
    if (_addressBook)
    {
        CFRelease(_addressBook);
    }
#if !OS_OBJECT_USE_OBJC
    dispatch_release(_localQueue);
#endif
}

#pragma mark - public

+ (APAddressBookAccess)access
{
    ABAuthorizationStatus status = ABAddressBookGetAuthorizationStatus();
    switch (status)
    {
        case kABAuthorizationStatusDenied:
        case kABAuthorizationStatusRestricted:
            return APAddressBookAccessDenied;
            
        case kABAuthorizationStatusAuthorized:
            return APAddressBookAccessGranted;
            
        default:
            return APAddressBookAccessUnknown;
    }
}

- (void)loadContacts:(void (^)(NSArray *contacts, NSError *error))callbackBlock
{
    [self loadContactsOnQueue:dispatch_get_main_queue() completion:callbackBlock];
}

- (void)loadContactsOnQueue:(dispatch_queue_t)queue
                 completion:(void (^)(NSArray *contacts, NSError *error))completionBlock
{
    APContactField fieldMask = self.fieldsMask;
    NSArray *descriptors = self.sortDescriptors;
    APContactFilterBlock filterBlock = self.filterBlock;
    
    ABAddressBookRequestAccessWithCompletion(self.addressBook, ^(bool granted, CFErrorRef errorRef) {
         dispatch_async(self.localQueue, ^{
             
            NSArray *array = nil;
            NSError *error = nil;
            if (granted)
            {
                NSMutableSet *included = [[NSMutableSet alloc] init];
                CFArrayRef peopleArrayRef = ABAddressBookCopyArrayOfAllPeople(self.addressBook);
                NSUInteger contactCount = (NSUInteger)CFArrayGetCount(peopleArrayRef);
                NSMutableArray *contacts = [[NSMutableArray alloc] init];
                for (NSUInteger i = 0; i < contactCount; i++)
                {
                    ABRecordRef recordRef = CFArrayGetValueAtIndex(peopleArrayRef, i);
                    APContact *contact = [[APContact alloc] initWithRecordRef:recordRef fieldMask:fieldMask];
                    
                    if (!filterBlock || filterBlock(contact))
                    {
                        // Is this contact already added?
                        
                        if ([included containsObject:contact.recordID]) {
                            continue;
                        }
                        
                        CFArrayRef linkedPeopleArrayRef = ABPersonCopyArrayOfAllLinkedPeople(recordRef);
                        NSUInteger linkedPeopleCount = CFArrayGetCount(linkedPeopleArrayRef);
                        for (NSUInteger j = 0; j < linkedPeopleCount; j++)
                        {
                            ABRecordRef linkedRecordRef = CFArrayGetValueAtIndex(linkedPeopleArrayRef, j);
                            
                            // Merge phones of this linked contact with contact
                            
                            APContact *linkedContact = [[APContact alloc] initWithRecordRef:linkedRecordRef fieldMask:fieldMask];
                            NSMutableArray *phones = [contact.phones mutableCopy];
                            for (NSString *phone in linkedContact.phones) {
                                if ([phones indexOfObject:phone] == NSNotFound) {
                                    [phones addObject:phone];
                                }
                            }
                            contact.phones = [phones copy];
                            
                            
                            // Merge phonesWithLabels of this linked contact with contact
                            
                            NSMutableArray *phonesWithLabels = [contact.phonesWithLabels mutableCopy];
                            
                            for (APPhoneWithLabel *phoneWithLabel in linkedContact.phonesWithLabels) {
                                
                                BOOL isDup = NO;
                                for (APPhoneWithLabel *currentPhonesWithLabel in phonesWithLabels) {
                                    if ([currentPhonesWithLabel.phone isEqualToString:phoneWithLabel.phone]) {
                                        isDup = YES;
                                        break;
                                    }
                                }
                                
                                if (!isDup) {
                                    [phonesWithLabels addObject:phoneWithLabel];
                                }
                            }
                            contact.phonesWithLabels = [phonesWithLabels copy];
                            
                            NSNumber *linkedRecordID = [NSNumber numberWithInteger:ABRecordGetRecordID(linkedRecordRef)];
                            [included addObject:linkedRecordID];
                        }
                        
                        [contacts addObject:contact];
                        
                        CFRelease(linkedPeopleArrayRef);
                    }
                }
                [contacts sortUsingDescriptors:descriptors];
                array = contacts.copy;
                CFRelease(peopleArrayRef);
            }
            else if (errorRef)
            {
                error = (__bridge NSError *)errorRef;
            }
            
            dispatch_async(queue, ^ {
               if (completionBlock)
               {
                   completionBlock(array, error);
               }
           });
        });
     });
}

- (void)startObserveChangesWithCallback:(void (^)())callback
{
    if (callback)
    {
        if (!self.changeCallback)
        {
            ABAddressBookRegisterExternalChangeCallback(self.addressBook,
                                                        APAddressBookExternalChangeCallback,
                                                        (__bridge void *)(self));
        }
        self.changeCallback = callback;
    }
}

- (void)stopObserveChanges
{
    if (self.changeCallback)
    {
        self.changeCallback = nil;
        ABAddressBookUnregisterExternalChangeCallback(self.addressBook,
                                                      APAddressBookExternalChangeCallback,
                                                      (__bridge void *)(self));
    }
}

#pragma mark - external change callback

void APAddressBookExternalChangeCallback(ABAddressBookRef __unused addressBookRef,
                                         CFDictionaryRef __unused info,
                                         void *context)
{
    APAddressBook *addressBook = (__bridge APAddressBook *)(context);
    addressBook.changeCallback ? addressBook.changeCallback() : nil;
}

@end
