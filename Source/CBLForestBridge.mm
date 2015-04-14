//
//  CBLForestBridge.mm
//  CouchbaseLite
//
//  Created by Jens Alfke on 5/1/14.
//  Copyright (c) 2014-2015 Couchbase, Inc. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file
//  except in compliance with the License. You may obtain a copy of the License at
//    http://www.apache.org/licenses/LICENSE-2.0
//  Unless required by applicable law or agreed to in writing, software distributed under the
//  License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
//  either express or implied. See the License for the specific language governing permissions
//  and limitations under the License.

#import "CBLForestBridge.h"

using namespace forestdb;


@implementation CBLForestBridge


static NSData* dataOfNode(const Revision* rev) {
    if (rev->inlineBody().buf)
        return rev->inlineBody().uncopiedNSData();
    try {
        return rev->readBody().copiedNSData();
    } catch (...) {
        return nil;
    }
}


+ (CBL_MutableRevision*) revisionObjectFromForestDoc: (VersionedDocument&)doc
                                               revID: (NSString*)revID
                                            withBody: (BOOL)withBody
{
    CBL_MutableRevision* rev;
    NSString* docID = (NSString*)doc.docID();
    if (doc.revsAvailable()) {
        const Revision* revNode;
        if (revID)
            revNode = doc.get(revID);
        else {
            revNode = doc.currentRevision();
            if (revNode)
                revID = (NSString*)revNode->revID;
        }
        if (!revNode)
            return nil;
        rev = [[CBL_MutableRevision alloc] initWithDocID: docID
                                                   revID: revID
                                                 deleted: revNode->isDeleted()];
        rev.sequence = revNode->sequence;
    } else {
        Assert(revID == nil || $equal(revID, (NSString*)doc.revID()));
        rev = [[CBL_MutableRevision alloc] initWithDocID: docID
                                                   revID: (NSString*)doc.revID()
                                                 deleted: doc.isDeleted()];
        rev.sequence = doc.sequence();
    }
    if (withBody && ![self loadBodyOfRevisionObject: rev doc: doc])
        return nil;
    return rev;
}


+ (CBL_MutableRevision*) revisionObjectFromForestDoc: (VersionedDocument&)doc
                                            sequence: (forestdb::sequence)sequence
                                            withBody: (BOOL)withBody
{
    const Revision* revNode = doc.getBySequence(sequence);
    if (!revNode)
        return nil;
    CBL_MutableRevision* rev = [[CBL_MutableRevision alloc] initWithDocID: (NSString*)doc.docID()
                                                                    revID: (NSString*)revNode->revID
                                                                  deleted: revNode->isDeleted()];
    if (withBody && ![self loadBodyOfRevisionObject: rev doc: doc])
        return nil;
    rev.sequence = sequence;
    return rev;
}


+ (BOOL) loadBodyOfRevisionObject: (CBL_MutableRevision*)rev
                              doc: (VersionedDocument&)doc
{
    const Revision* revNode = doc.get(rev.revID);
    if (!revNode)
        return NO;
    NSData* json = dataOfNode(revNode);
    if (!json)
        return NO;
    rev.sequence = revNode->sequence;
    rev.asJSON = json;
    return YES;
}


+ (NSMutableDictionary*) bodyOfNode: (const Revision*)rev {
    NSData* json = dataOfNode(rev);
    if (!json)
        return nil;
    NSMutableDictionary* properties = [CBLJSON JSONObjectWithData: json
                                                          options: NSJSONReadingMutableContainers
                                                            error: NULL];
    Assert(properties, @"Unable to parse doc from db: %@", json.my_UTF8ToString);
    NSString* revID = (NSString*)rev->revID;
    Assert(revID);

    const VersionedDocument* doc = (const VersionedDocument*)rev->owner;
    properties[@"_id"] = (NSString*)doc->docID();
    properties[@"_rev"] = revID;
    if (rev->isDeleted())
        properties[@"_deleted"] = $true;
    return properties;
}


+ (NSArray*) getCurrentRevisionIDs: (VersionedDocument&)doc {
    NSMutableArray* currentRevIDs = $marray();
    auto revs = doc.currentRevisions();
    for (auto rev = revs.begin(); rev != revs.end(); ++rev)
        if (!(*rev)->isDeleted())
            [currentRevIDs addObject: (NSString*)(*rev)->revID];
    return currentRevIDs;
}


+ (NSArray*) mapHistoryOfNode: (const Revision*)rev
                      through: (id(^)(const Revision*))block
{
    NSMutableArray* history = $marray();
    for (; rev; rev = rev->parent())
        [history addObject: block(rev)];
    return history;
}


+ (NSArray*) getRevisionHistory: (const Revision*)revNode {
    const VersionedDocument* doc = (const VersionedDocument*)revNode->owner;
    NSString* docID = (NSString*)doc->docID();
    return [self mapHistoryOfNode: revNode
                          through: ^id(const Revision *ancestor)
    {
        CBL_MutableRevision* rev = [[CBL_MutableRevision alloc] initWithDocID: docID
                                                                revID: (NSString*)ancestor->revID
                                                              deleted: ancestor->isDeleted()];
        rev.missing = !ancestor->isBodyAvailable();
        return rev;
    }];
}


+ (NSDictionary*) getRevisionHistoryOfNode: (const Revision*)rev
                         startingFromAnyOf: (NSArray*)ancestorRevIDs
{
    NSArray* history = [self getRevisionHistory: rev]; // (this is in reverse order, newest..oldest
    if (ancestorRevIDs.count > 0) {
        NSUInteger n = history.count;
        for (NSUInteger i = 0; i < n; ++i) {
            if ([ancestorRevIDs containsObject: [history[i] revID]]) {
                history = [history subarrayWithRange: NSMakeRange(0, i+1)];
                break;
            }
        }
    }
    return [self makeRevisionHistoryDict: history];
}


+ (NSDictionary*) makeRevisionHistoryDict: (NSArray*)history {
    if (!history)
        return nil;

    // Try to extract descending numeric prefixes:
    NSMutableArray* suffixes = $marray();
    id start = nil;
    int lastRevNo = -1;
    for (CBL_Revision* rev in history) {
        int revNo;
        NSString* suffix;
        if ([CBL_Revision parseRevID: rev.revID intoGeneration: &revNo andSuffix: &suffix]) {
            if (!start)
                start = @(revNo);
            else if (revNo != lastRevNo - 1) {
                start = nil;
                break;
            }
            lastRevNo = revNo;
            [suffixes addObject: suffix];
        } else {
            start = nil;
            break;
        }
    }

    NSArray* revIDs = start ? suffixes : [history my_map: ^(id rev) {return [rev revID];}];
    return $dict({@"ids", revIDs}, {@"start", start});
}
    

@end



CBLStatus CBLStatusFromForestDBStatus(int fdbStatus) {
    switch (fdbStatus) {
        case FDB_RESULT_SUCCESS:
            return kCBLStatusOK;
        case FDB_RESULT_KEY_NOT_FOUND:
        case FDB_RESULT_NO_SUCH_FILE:
            return kCBLStatusNotFound;
        case FDB_RESULT_RONLY_VIOLATION:
            return kCBLStatusForbidden;
        case FDB_RESULT_CHECKSUM_ERROR:
        case FDB_RESULT_FILE_CORRUPTION:
        case error::CorruptRevisionData:
            return kCBLStatusCorruptError;
        case error::BadRevisionID:
            return kCBLStatusBadID;
        default:
            return kCBLStatusDBError;
    }
}
