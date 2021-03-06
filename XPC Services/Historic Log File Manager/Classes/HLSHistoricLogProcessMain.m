/* ********************************************************************* 
                  _____         _               _
                 |_   _|____  _| |_ _   _  __ _| |
                   | |/ _ \ \/ / __| | | |/ _` | |
                   | |  __/>  <| |_| |_| | (_| | |
                   |_|\___/_/\_\\__|\__,_|\__,_|_|

 Copyright (c) 2010 - 2017 Codeux Software, LLC & respective contributors.
        Please see Acknowledgements.pdf for additional information.

 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions
 are met:

    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above copyright
      notice, this list of conditions and the following disclaimer in the
      documentation and/or other materials provided with the distribution.
    * Neither the name of Textual and/or "Codeux Software, LLC", nor the 
      names of its contributors may be used to endorse or promote products 
      derived from this software without specific prior written permission.

 THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND
 ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 ARE DISCLAIMED. IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
 FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
 OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
 HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
 LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
 OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
 SUCH DAMAGE.

 *********************************************************************** */

#import "HLSHistoricLogProcessMain.h"
#import "HLSHistoricLogChannelContext.h"

#import <CoreData/CoreData.h>

#import <CocoaExtensions/CocoaExtensions.h>

NS_ASSUME_NONNULL_BEGIN

@interface HLSHistoricLogProcessMain ()
@property (nonatomic, assign) BOOL isPerformingSave;
@property (nonatomic, assign) BOOL isNewDatabase;
@property (nonatomic, strong) NSManagedObjectContext *managedObjectContext;
@property (nonatomic, strong) NSManagedObjectModel *managedObjectModel;
@property (nonatomic, strong) NSPersistentStoreCoordinator *persistentStoreCoordinator;
@property (nonatomic, copy) NSString *savePath;
@property (nonatomic, strong) NSCache<NSString *, HLSHistoricLogChannelContext *> *contextObjects;
@property (nonatomic, assign) NSUInteger maximumLineCount;
@property (nonatomic, strong) dispatch_source_t saveTimer;
@end

@implementation HLSHistoricLogProcessMain

- (instancetype)init
{
	if ((self = [super init])) {
		[self prepareInitialState];

		return self;
	}

	return nil;
}

- (void)prepareInitialState
{
	self.contextObjects = [NSCache new];

	self.maximumLineCount = 100;
}

- (void)openDatabaseAtPath:(NSString *)path
{
	NSParameterAssert(path != nil);

	LogToConsoleInfo("Opening database at path: %@", path)

	self.savePath = path;

	[self _createBaseModel];

	[self _performOneTimeMigrationToIdentifiers];

	[self _scheduleSave];
}

- (void)setMaximumLineCount:(NSUInteger)maximumLineCount
{
	NSParameterAssert(maximumLineCount > 0);

	if (self->_maximumLineCount != maximumLineCount) {
		self->_maximumLineCount = maximumLineCount;
	}
}

- (NSFetchRequest *)_fetchRequestForChannel:(NSString *)channelId
								 fetchLimit:(NSUInteger)fetchLimit
								limitToDate:(nullable NSDate *)limitToDate
								 resultType:(NSFetchRequestResultType)resultType
{
	NSParameterAssert(channelId != nil);

	if (limitToDate == nil) {
		limitToDate = [NSDate distantFuture];
	}

	NSDictionary *substitutionVariables = @{
		@"channel_id" : channelId,
		@"creation_date" : @([limitToDate timeIntervalSince1970])
	};

	NSFetchRequest *fetchRequest =
	[self.managedObjectModel fetchRequestFromTemplateWithName:@"LogLineFetchRequest"
										substitutionVariables:substitutionVariables];

	if (fetchLimit > 0) {
		fetchRequest.fetchLimit = fetchLimit;
	}

	fetchRequest.resultType = resultType;

	return fetchRequest;
}

- (void)resetDataForChannel:(NSString *)channelId
{
	LogToConsoleDebug("Resetting the contents of channel: %@", channelId)

	[self cancelResizeForChannel:channelId];

	NSManagedObjectContext *context = self.managedObjectContext;

	[context performBlockAndWait:^{
		NSFetchRequest *fetchRequest = [self _fetchRequestForChannel:channelId
														  fetchLimit:0
														 limitToDate:nil
														  resultType:NSManagedObjectResultType];

		[self _deleteDataForFetchRequest:fetchRequest];
	}];
}

- (void)fetchEntriesForChannel:(NSString *)channelId
					fetchLimit:(NSUInteger)fetchLimit
				   limitToDate:(nullable NSDate *)limitToDate
		   withCompletionBlock:(void (^)(NSArray<TVCLogLineXPC *> *entries))completionBlock
{
	NSParameterAssert(channelId != nil);
	NSParameterAssert(completionBlock != nil);

	NSManagedObjectContext *context = self.managedObjectContext;

	[context performBlockAndWait:^{
		NSFetchRequest *fetchRequest = [self _fetchRequestForChannel:channelId
														  fetchLimit:fetchLimit
														 limitToDate:limitToDate
														  resultType:NSManagedObjectResultType];

		fetchRequest.includesPropertyValues = YES;

		fetchRequest.sortDescriptors = @[[[NSSortDescriptor alloc] initWithKey:@"creationDate" ascending:YES]];

		NSError *fetchRequestError = nil;

		NSArray<NSManagedObject *> *fetchedObjects = [context executeFetchRequest:fetchRequest error:&fetchRequestError];

		if (fetchedObjects == nil) {
			LogToConsoleError("Error occurred fetching objects: %@",
				fetchRequestError.localizedDescription)

			return;
		}

		LogToConsoleDebug("%ld results fetched for channel %@",
			fetchedObjects.count, channelId)

		@autoreleasepool {
			NSMutableArray<TVCLogLineXPC *> *fetchedEntries = [NSMutableArray arrayWithCapacity:fetchedObjects.count];

			for (NSManagedObject *fetchedObject in fetchedObjects) {
				TVCLogLineXPC *fetchedEntry = [[TVCLogLineXPC alloc] initWithManagedObject:fetchedObject];

				[fetchedEntries addObject:fetchedEntry];
			}

			completionBlock([fetchedEntries copy]);
		}
	}];
}

- (void)writeLogLine:(TVCLogLineXPC *)logLine
{
	NSParameterAssert(logLine != nil);

	NSManagedObjectContext *context = self.managedObjectContext;

	[context performBlockAndWait:^{
		NSEntityDescription *entity = [NSEntityDescription entityForName:@"LogLine" inManagedObjectContext:context];

		NSManagedObject *newEntry = [[NSManagedObject alloc] initWithEntity:entity insertIntoManagedObjectContext:context];

		NSString *channelId = logLine.channelId;

		NSUInteger newestIdentifier = [self _incrementNewestIdentifierForChannel:channelId];

		[newEntry setValue:@(newestIdentifier) forKey:@"id"];

		[newEntry setValue:channelId forKey:@"channelId"];

		[newEntry setValue:logLine.creationDate forKey:@"creationDate"];

		[newEntry setValue:logLine.data forKey:@"data"];

		[self scheduleResizeForChannel:channelId];
	}];
}

- (void)_createBaseModel
{
	[self _createBaseModelWithRecursion:0];
}

- (void)_createBaseModelWithRecursion:(NSUInteger)recursionDepth
{
	NSURL *modelPath = [[NSBundle mainBundle] URLForResource:@"HistoricLogFileStorageModel" withExtension:@"momd"];

	NSManagedObjectModel *managedObjectModel = [[NSManagedObjectModel alloc] initWithContentsOfURL:modelPath];

	NSPersistentStoreCoordinator *persistentStoreCoordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:managedObjectModel];

	NSDictionary *pragmaOptions = @{
		@"synchronous" : @"FULL",
		@"journal_mode" : @"DELETE"
	};

	NSDictionary *persistentStoreOptions = @{
		NSMigratePersistentStoresAutomaticallyOption : @(YES),
		NSInferMappingModelAutomaticallyOption : @(YES),
		NSSQLitePragmasOption : pragmaOptions
	};

	NSURL *persistentStorePath = [NSURL fileURLWithPath:self.savePath];

	/* Assigning a value to self.isNewDatabase allows us to know whether we 
	 can skip certain migration steps, thus reducing overhead. */
	self.isNewDatabase = ([[NSFileManager defaultManager] fileExistsAtPath:persistentStorePath.path] == NO);

	NSError *addPersistentStoreError = nil;

	NSPersistentStore *persistentStore =
	[persistentStoreCoordinator addPersistentStoreWithType:NSSQLiteStoreType
											 configuration:nil
													   URL:persistentStorePath
												   options:persistentStoreOptions
													 error:&addPersistentStoreError];

	if (persistentStore == nil)
	{
		LogToConsoleError("Error Creating Persistent Store: %@",
			addPersistentStoreError.localizedDescription)

		if (recursionDepth == 0) {
			LogToConsoleInfo("Attempting to create a new persistent store")

			/* If we failed to load our store, we create a brand new one at a new path
			 incase the old one is corrupted. We also erase the old database to not allow
			 the file to just hang on the OS. */
			[self resetDatabase]; // Destroy any data that may exist

			[self _createBaseModelWithRecursion:1];
		}

		return;
	}
	else
	{
		NSManagedObjectContext *managedObjectContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];

		managedObjectContext.persistentStoreCoordinator = persistentStoreCoordinator;

		managedObjectContext.retainsRegisteredObjects = YES;

		managedObjectContext.undoManager = nil;

		self.managedObjectContext = managedObjectContext;
		self.managedObjectModel = managedObjectModel;

		self.persistentStoreCoordinator = persistentStoreCoordinator;
	}
}

- (void)resetDatabase
{
	NSString *path = self.savePath;

	[[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
	[[NSFileManager defaultManager] removeItemAtPath:[path stringByAppendingString:@"-shm"] error:NULL];
	[[NSFileManager defaultManager] removeItemAtPath:[path stringByAppendingString:@"-wal"] error:NULL];
}

- (void)_scheduleSave
{
	if (self.saveTimer) {
		XRCancelScheduledBlock(self.saveTimer);
	}

	static NSTimeInterval saveTimerInterval = (60 * 2); // 2 minutes

	dispatch_source_t saveTimer =
	XRScheduleBlockOnQueue(dispatch_get_main_queue(), ^{
		[self saveDataWithCompletionBlock:nil];
	}, saveTimerInterval, YES);

	XRResumeScheduledBlock(saveTimer);

	self.saveTimer = saveTimer;
}

- (void)_quickSave
{
	[self _scheduleSave];

	NSManagedObjectContext *context = self.managedObjectContext;

	if ([context commitEditing] == NO)
	{
		LogToConsoleError("Failed to commit editing")
	}

	if ([context hasChanges])
	{
		NSError *saveError = nil;

		if ([context save:&saveError] == NO) {
			LogToConsoleError("Failed to perform save: %@",
							  saveError.localizedDescription)
		} else {
			LogToConsoleInfo("Performed save")
		}
	} else {
		LogToConsoleInfo("Did not perform save because nothing has changed")
	}
}

- (void)saveDataWithCompletionBlock:(void (^ _Nullable)(void))completionBlock
{
	if (self.isPerformingSave == NO) {
		self.isPerformingSave = YES;
	} else {
		return;
	}

	NSManagedObjectContext *context = self.managedObjectContext;

	[context performBlock:^{
		[self _quickSave];

		self.isPerformingSave = NO;

		if (completionBlock) {
			completionBlock();
		}
	}];
}

- (void)cancelResizeForChannel:(NSString *)channelId
{
	NSParameterAssert(channelId != nil);

	HLSHistoricLogChannelContext *context = [self _contextForChannel:channelId];

	if (context.resizeTimer == nil) {
		return;
	}

	XRCancelScheduledBlock(context.resizeTimer);

	context.resizeTimer = nil;
}

- (void)scheduleResizeForChannel:(NSString *)channelId
{
	NSParameterAssert(channelId != nil);

	HLSHistoricLogChannelContext *channel = [self _contextForChannel:channelId];

	if (channel.resizeTimer != nil) {
		return;
	}

	if (channel.lineCount < self.maximumLineCount) {
		return;
	}

	NSTimeInterval resizeTimerInterval = (NSTimeInterval)arc4random_uniform(60); // Somewhere in 30 minutes

	dispatch_source_t resizeTimer =
	XRScheduleBlockOnQueue(dispatch_get_main_queue(), ^{
		[self resizeChannel:channelId];
	}, resizeTimerInterval, NO);

	XRResumeScheduledBlock(resizeTimer);

	channel.resizeTimer = resizeTimer;

	LogToConsoleDebug("Scheduled to resize %@ in %f seconds",
		channelId, resizeTimerInterval)
}

- (void)resizeChannel:(NSString *)channelId
{
	NSParameterAssert(channelId != nil);

	NSManagedObjectContext *context = self.managedObjectContext;

	[context performBlock:^{
		HLSHistoricLogChannelContext *channel = [self _contextForChannel:channelId];

		[self _resizeChannel:channel];
	}];
}

- (void)_resizeChannel:(HLSHistoricLogChannelContext *)channel
{
	NSParameterAssert(channel != nil);

	channel.resizeTimer = nil;

	NSString *channelId = channel.channelId;

	NSInteger lowestIdentifier = (channel.newestIdentifier - self.maximumLineCount);

	NSDictionary *substitutionVariables = @{
		@"channel_id" : channelId,
		@"lowest_id" : @(lowestIdentifier)
	};

	NSFetchRequest *fetchRequest =
	[self.managedObjectModel fetchRequestFromTemplateWithName:@"LogLineFetchRequestTruncate"
										substitutionVariables:substitutionVariables];

	NSUInteger rowsDeleted = [self _deleteDataForFetchRequest:fetchRequest];

	channel.lineCount = (channel.lineCount - rowsDeleted);

	LogToConsoleDebug("Deleted %ld rows in %@", rowsDeleted, channelId)
}

#pragma mark -
#pragma mark Migration

/* A 'id' column now exists in the database. The 'id' column is a non-unique 64-bit number.
 It starts at 0 and increments by 1. It acts as an index on a per-channel basis.

 For example:

 | id |   channel   |
 --------------------
 | 0  |  #textual   |
 | 1  |  #textual   |
 | 2  |  #textual   |
 | 0  |  #freenode  |

 This allows us to batch delete by taking last 'id' value for a channel,
 subtracting by a specific amount, and deleting all rows that meet that
 condition.

 A better solution would to use raw sqlite quries. That is the end goal
 if this design proves to be ineffecient. */
/* This migration method is in itself terribly ineffecient since it 
 enumerates the entire database, but the trade off is believed to be
 worth it, since it is only performed one time. */
- (void)_performOneTimeMigrationToIdentifiers
{
#define _defaultsKey		@"Migration -> Migrated to Model 2"

	LogToConsoleDebug("Performing one time migration to identifiers")

	if (self.isNewDatabase) {
		LogToConsoleDebug("Migration cancelled becase this is a new database")

		[[NSUserDefaults standardUserDefaults] setBool:YES forKey:_defaultsKey];

		return;
	}

	BOOL performedMigration = [[NSUserDefaults standardUserDefaults] boolForKey:_defaultsKey];

	if (performedMigration != NO) {
		LogToConsoleDebug("Migration cancelled becase it has already been performed")

		return;
	}

	NSManagedObjectContext *context = self.managedObjectContext;

	[context performBlockAndWait:^{
		NSFetchRequest *fetchRequest =
		[[self.managedObjectModel fetchRequestTemplateForName:@"LogLineFetchRequestAll"] copy];

		fetchRequest.sortDescriptors =
		@[[[NSSortDescriptor alloc] initWithKey:@"channelId" ascending:NO],
		  [[NSSortDescriptor alloc] initWithKey:@"creationDate" ascending:YES]];

		NSManagedObjectContext *context = self.managedObjectContext;

		NSError *fetchRequestError = nil;

		NSArray *fetchedObjects = [context executeFetchRequest:fetchRequest error:&fetchRequestError];

		if (fetchedObjects == nil) {
			LogToConsoleError("Error occurred fetching objects: %@",
				fetchRequestError.localizedDescription)

			return;
		}

		__block NSString *currentChannelId = nil;

		__block NSInteger currentIdentifier = 0;

		[fetchedObjects enumerateObjectsUsingBlock:^(NSManagedObject *object, NSUInteger index, BOOL *stop) {
			NSString *channelId = [object valueForKey:@"channelId"];

			if (currentChannelId == nil) {
				currentChannelId = channelId;
			} else {
				if ([currentChannelId isEqualToString:channelId] == NO) {
					currentChannelId = channelId;

					currentIdentifier = 0;
				}
			}

			[object setValue:@(currentIdentifier) forKey:@"id"];

			currentIdentifier += 1;
		}];

		[self _quickSave];

		[[NSUserDefaults standardUserDefaults] setBool:YES forKey:_defaultsKey];

		LogToConsoleDebug("Migration completed")
	}];

#undef _defaultsKey
}

#pragma mark -
#pragma mark Batch Delete Logic

- (NSUInteger)_deleteDataForFetchRequest:(NSFetchRequest *)fetchRequest
{
	/* This method is expected to be performed in a queue. */
	NSParameterAssert(fetchRequest != nil);

	//	if ([XRSystemInformation isUsingOSXElCapitanOrLater]) {
	//		return [self __deleteDataForFetchRequestUsingBatch:fetchRequest];
	//	} else {
		return [self __deleteDataForFetchRequestUsingEnumeration:fetchRequest];
	//	}
}

- (NSUInteger)__deleteDataForFetchRequestUsingBatch:(NSFetchRequest *)fetchRequest
{
	NSParameterAssert(fetchRequest != nil);

	NSManagedObjectContext *context = self.managedObjectContext;

	NSBatchDeleteRequest *batchDeleteRequest = [[NSBatchDeleteRequest alloc] initWithFetchRequest:fetchRequest];

	batchDeleteRequest.resultType = NSBatchDeleteResultTypeCount;

	NSError *batchDeleteError = nil;

	NSBatchDeleteResult *batchDeleteResult =
	[context executeRequest:batchDeleteRequest error:&batchDeleteError];

	if (batchDeleteResult == nil) {
		LogToConsoleError("Failed to perform batch delete: %@",
			batchDeleteError.localizedDescription)

		return 0;
	}

	NSUInteger rowsDeleted = ((NSNumber *)batchDeleteResult.result).unsignedIntegerValue;

	if (rowsDeleted > 0) {
		[self _quickSave];
	}

	return rowsDeleted;
}

- (NSUInteger)__deleteDataForFetchRequestUsingEnumeration:(NSFetchRequest *)fetchRequest
{
	NSParameterAssert(fetchRequest != nil);

	NSManagedObjectContext *context = self.managedObjectContext;

	NSError *fetchRequestError = nil;

	NSArray *fetchedObjects = [context executeFetchRequest:fetchRequest error:&fetchRequestError];

	if (fetchedObjects == nil) {
		LogToConsoleError("Error occurred fetching objects: %@",
			fetchRequestError.localizedDescription)

		return 0;
	}

	for (NSManagedObject *object in fetchedObjects) {
		[context deleteObject:object];
	}

	NSUInteger rowsDeleted = fetchedObjects.count;

	if (rowsDeleted > 0) {
		[self _quickSave];
	}

	return rowsDeleted;
}

#pragma mark -
#pragma mark Identifier Cache Management

- (HLSHistoricLogChannelContext *)_contextForChannel:(NSString *)channelId
{
	NSParameterAssert(channelId != nil);

	HLSHistoricLogChannelContext *channel = [self.contextObjects objectForKey:channelId];

	if (channel != nil) {
		return channel;
	}

	channel = [HLSHistoricLogChannelContext new];

	channel.channelId = channelId;

	channel.lineCount = [self _lineCountForChannelFromDatabase:channelId];

	channel.newestIdentifier = [self _newestIdentifierForChannelFromDatabase:channelId];

	LogToConsoleDebug("Context created for %@ - Line count: %ld, Newest identifier: %ld",
		channel.channelId, channel.lineCount, channel.newestIdentifier)

	[self.contextObjects setObject:channel forKey:channelId];

	return channel;
}

- (NSUInteger)_incrementNewestIdentifierForChannel:(NSString *)channelId
{
	NSParameterAssert(channelId != nil);

	HLSHistoricLogChannelContext *channel = [self _contextForChannel:channelId];

	channel.lineCount = (channel.lineCount + 1);

	channel.newestIdentifier = (channel.newestIdentifier + 1);

	return channel.newestIdentifier;
}

- (NSUInteger)_newestIdentifierForChannel:(NSString *)channelId
{
	NSParameterAssert(channelId != nil);

	HLSHistoricLogChannelContext *channel = [self _contextForChannel:channelId];

	return channel.newestIdentifier;
}

- (NSUInteger)_newestIdentifierForChannelFromDatabase:(NSString *)channelId
{
	NSParameterAssert(channelId != nil);

	NSManagedObjectContext *context = self.managedObjectContext;

	NSFetchRequest *fetchRequest = [self _fetchRequestForChannel:channelId
													  fetchLimit:1
													 limitToDate:nil
													  resultType:NSManagedObjectResultType];

	fetchRequest.includesPropertyValues = YES;

	fetchRequest.sortDescriptors = @[[[NSSortDescriptor alloc] initWithKey:@"creationDate" ascending:NO]];

	NSError *fetchRequestError = nil;

	NSArray<NSManagedObject *> *fetchedObjects = [context executeFetchRequest:fetchRequest error:&fetchRequestError];

	if (fetchedObjects == nil) {
		NSAssert1(NO, @"Error occurred fetching objects: %@",
			fetchRequestError.localizedDescription);
	}

	NSManagedObject *fetchedObject = fetchedObjects.firstObject;

	if (fetchedObject == nil) {
		return 0;
	}

	NSNumber *newestIdentifier = [fetchedObject valueForKey:@"id"];

	return newestIdentifier.unsignedIntegerValue;
}

- (NSUInteger)_lineCountForChannelFromDatabase:(NSString *)channelId
{
	NSParameterAssert(channelId != nil);

	NSManagedObjectContext *context = self.managedObjectContext;

	NSFetchRequest *fetchRequest = [self _fetchRequestForChannel:channelId
													  fetchLimit:0
													 limitToDate:nil
													  resultType:NSCountResultType];

	NSError *fetchRequestError = nil;

	NSUInteger objectCount = [context countForFetchRequest:fetchRequest error:&fetchRequestError];

	if (objectCount == NSNotFound) {
		NSAssert1(NO, @"Error occurred fetching objects: %@",
			fetchRequestError.localizedDescription);
	}

	return objectCount;
}

@end

NS_ASSUME_NONNULL_END
