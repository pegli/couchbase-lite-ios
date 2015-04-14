//
//  CBLDatabase+Replication.m
//  CouchbaseLite
//
//  Created by Jens Alfke on 12/27/11.
//  Copyright (c) 2011-2013 Couchbase, Inc. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file
//  except in compliance with the License. You may obtain a copy of the License at
//    http://www.apache.org/licenses/LICENSE-2.0
//  Unless required by applicable law or agreed to in writing, software distributed under the
//  License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
//  either express or implied. See the License for the specific language governing permissions
//  and limitations under the License.

#import "CBLDatabase+Replication.h"
#import "CBLInternal.h"
#import "CBL_Puller.h"
#import "MYBlockUtils.h"


#define kActiveReplicatorCleanupDelay 10.0

#define kLocalCheckpointDocId @"CBL_LocalCheckpoint"


@implementation CBLDatabase (Replication)


- (NSArray*) activeReplicators {
    return _activeReplicators;
}

- (void) addActiveReplicator: (CBL_Replicator*)repl {
    if (!_activeReplicators) {
        _activeReplicators = [[NSMutableArray alloc] init];
        [[NSNotificationCenter defaultCenter] addObserver: self
                                                 selector: @selector(replicatorDidStop:)
                                                     name: CBL_ReplicatorStoppedNotification
                                                   object: nil];
    }
    if (![_activeReplicators containsObject: repl])
        [_activeReplicators addObject: repl];
}


- (CBL_Replicator*) activeReplicatorLike: (CBL_Replicator*)repl {
    for (CBL_Replicator* activeRepl in _activeReplicators) {
        if ([activeRepl hasSameSettingsAs: repl])
            return activeRepl;
    }
    return nil;
}


- (void) stopAndForgetReplicator: (CBL_Replicator*)repl {
    [repl databaseClosing];
    [_activeReplicators removeObjectIdenticalTo: repl];
}


- (void) replicatorDidStop: (NSNotification*)n {
    CBL_Replicator* repl = n.object;
    if (repl.error)     // Leave it around a while so clients can see the error
        MYAfterDelay(kActiveReplicatorCleanupDelay,
                     ^{[_activeReplicators removeObjectIdenticalTo: repl];});
    else
        [_activeReplicators removeObjectIdenticalTo: repl];
}


static NSString* checkpointInfoKey(NSString* checkpointID) {
    return [@"checkpoint/" stringByAppendingString: checkpointID];
}


- (NSString*) lastSequenceWithCheckpointID: (NSString*)checkpointID {
    return [_storage infoForKey: checkpointInfoKey(checkpointID)];
}

- (BOOL) setLastSequence: (NSString*)lastSequence withCheckpointID: (NSString*)checkpointID {
    return [_storage setInfo: lastSequence forKey: checkpointInfoKey(checkpointID)] == kCBLStatusOK;
}


- (BOOL) saveLocalUUIDInLocalCheckpointDocument: (NSError**)outError {
    return [self putLocalCheckpointDocumentWithKey: kCBLDatabaseLocalCheckpoint_LocalUUID
                                             value: self.privateUUID
                                          outError: outError];
}

- (BOOL) putLocalCheckpointDocumentWithKey: (NSString*)key
                                     value:(id)value
                                  outError: (NSError**)outError {
    if (key == nil || value == nil)
        return NO;

    NSMutableDictionary* document = [NSMutableDictionary dictionaryWithDictionary:
                                        [self getLocalCheckpointDocument]];
    document[key] = value;
    BOOL result = [self putLocalDocument: document withID: kLocalCheckpointDocId error: outError];
    if (!result)
        Warn(@"CBLDatabase: Could not create a local checkpoint document with an error: %@", *outError);
    return result;
}


- (NSDictionary*) getLocalCheckpointDocument {
    return [self existingLocalDocumentWithID: kLocalCheckpointDocId];
}


- (id) getLocalCheckpointDocumentPropertyValueForKey: (NSString*)key {
    return [[self getLocalCheckpointDocument] objectForKey: key];
}


@end
