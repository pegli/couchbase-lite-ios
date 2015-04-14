//
//  CBLView+Internal.h
//  CouchbaseLite
//
//  Created by Jens Alfke on 12/8/11.
//  Copyright (c) 2011-2013 Couchbase, Inc. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "CBLDatabase+Internal.h"
#import "CBLView.h"
#import "CBLQuery.h"
#import "CBL_ViewStorage.h"
@class CBForestMapReduceIndex;


extern NSString* const kCBLViewChangeNotification;

typedef enum {
    kCBLViewCollationUnicode,
    kCBLViewCollationRaw,
    kCBLViewCollationASCII
} CBLViewCollation;


BOOL CBLRowPassesFilter(CBLDatabase* db, CBLQueryRow* row, const CBLQueryOptions* options);


@interface CBLView () <CBL_ViewStorageDelegate>
{
    @private
    CBLDatabase* __weak _weakDB;
    id<CBL_ViewStorage> _storage;
    NSString* _name;
    uint8_t _collation;
}

- (instancetype) initWithDatabase: (CBLDatabase*)db name: (NSString*)name create: (BOOL)create;

- (void) close;

@property (readonly) NSUInteger totalRows;

/** The map block alredy registered with the view. Unlike the public .mapBlock property, this
    will not look for a design document or compile a function therein. */
@property (readonly) CBLMapBlock registeredMapBlock;

@property (readonly) SequenceNumber lastSequenceChangedAt;

@property (readonly) id<CBL_ViewStorage> storage;

#if DEBUG  // for unit tests only
- (void) setCollation: (CBLViewCollation)collation;
- (void) forgetMapBlock;
#endif

@property (readonly) NSArray* viewsInGroup;

- (CBLStatus) compileFromDesignDoc;

/** Compiles a view (using the registered CBLViewCompiler) from the properties found in a CouchDB-style design document. */
- (CBLStatus) compileFromProperties: (NSDictionary*)viewProps
                           language: (NSString*)language;

/** Updates the view's index (incrementally) if necessary.
    If the index is updated, the other views in the viewGroup will be updated as a bonus.
    @return  200 if updated, 304 if already up-to-date, else an error code */
- (CBLStatus) updateIndex;

/** Updates the view's index (incrementally) if necessary. No other groups will be updated.
    @return  200 if updated, 304 if already up-to-date, else an error code */
- (CBLStatus) updateIndexAlone;

- (CBLStatus) updateIndexes: (NSArray*)views;

@end


@interface CBLView (Querying)

/** Queries the view. Does NOT first update the index.
    @param options  The options to use.
    @return  An array of CBLQueryRow. */
- (CBLQueryIteratorBlock) _queryWithOptions: (CBLQueryOptions*)options
                                     status: (CBLStatus*)outStatus;

@end


@interface CBLQueryEnumerator ()
- (instancetype) initWithDatabase: (CBLDatabase*)database
                             view: (CBLView*)view
                   sequenceNumber: (SequenceNumber)sequenceNumber
                         iterator: (CBLQueryIteratorBlock)iterator;
- (instancetype) initWithDatabase: (CBLDatabase*)database
                             view: (CBLView*)view
                   sequenceNumber: (SequenceNumber)sequenceNumber
                             rows: (NSArray*)rows;
@end


@interface CBLQueryRow ()
- (void) moveToView: (CBLView*)view;
- (void) _clearDatabase;
@end
