public with sharing class LeadQueueService {
    
    private static final List<String> STATUS_ORDER = LeadQueueConfig.STATUS_ORDER;
    
    private static final Set<String> EXCLUDED_INTAKE_TYPES = new Set<String>{
        'SSD',
        'Civil Rights'
    };
    
    private static final Integer HIGH_PRIORITY_THRESHOLD = 22;
    private static final Integer DEFAULT_PAGE_SIZE = 50;
    private static final Integer MAX_PAGE_SIZE = 200;
    private static final String READY_TO_CALL_ORDER_BY = 'ORDER BY Priority_Score__c ASC, Call_at_Date__c ASC';
    private static final String SCHEDULED_CALL_ORDER_BY = 'ORDER BY Call_at_Date__c ASC';
    private static final String REQUIRED_FIELDS = 'Id, Name, litify_pm__Display_Name__c, Referred_By_Name__c, litify_pm__Status__c, Priority_Score__c, Queue_Case_Type__c, Call_at_Date__c, litify_pm__Phone__c, litify_pm__Sign_Up_Method__c, Test_Record__c, Qualification_Status__c';
    private static final Set<String> REQUIRED_FIELD_SET = buildRequiredFieldSet();
    private static final Set<String> REQUIRED_ACCESS_FIELD_SET = buildRequiredAccessFieldSet();
    
    private static Boolean isSimulatedCacheActive() {
        return LeadQueueCacheRepository.isSimulatedCacheActive();
    }
    
    @TestVisible
    static void resetSimulatedCache() {
        LeadQueueCacheRepository.resetSimulatedCache();
    }
    
    @TestVisible
    static void enableCacheSimulation(Boolean shouldSimulate) {
        LeadQueueCacheRepository.enableCacheSimulation(shouldSimulate);
    }
    
    private static Set<String> buildRequiredFieldSet() {
        Set<String> fields = new Set<String>();
        for (String token : REQUIRED_FIELDS.split(',')) {
            String fieldName = token.trim();
            if (String.isBlank(fieldName)) {
                continue;
            }
            if (fieldName.equalsIgnoreCase('Id') || fieldName.equalsIgnoreCase('Name') || fieldName.equalsIgnoreCase('CreatedDate')) {
                continue;
            }
            fields.add(fieldName);
        }
        return fields;
    }

    private static Set<String> buildRequiredAccessFieldSet() {
        Set<String> fields = new Set<String>();
        fields.addAll(REQUIRED_FIELD_SET);
        fields.add('Type__c');
        return fields;
    }

    private static Integer normalizePageNumber(Integer pageNumber) {
        return pageNumber != null && pageNumber > 0 ? pageNumber : 1;
    }

    private static Integer normalizePageSize(Integer pageSize) {
        if (pageSize == null || pageSize <= 0) {
            return DEFAULT_PAGE_SIZE;
        }
        return Math.min(pageSize, MAX_PAGE_SIZE);
    }

    @AuraEnabled
    public static LeadQueueModels.QueueResponse getQueueData(String statusFilter, String caseTypeFilter, String dueDateFilter, Boolean showScheduledCalls) {
        return getQueueDataPaged(statusFilter, caseTypeFilter, dueDateFilter, showScheduledCalls, null, null, null, false);
    }

    @AuraEnabled
    public static LeadQueueModels.QueueResponse getQueueDataPaged(String statusFilter, String caseTypeFilter, String dueDateFilter, Boolean showScheduledCalls, Integer pageNumber, Integer pageSize, String tileFilter, Boolean bypassCache) {
        try {
            // Security validation
            if (!Schema.sObjectType.litify_pm__Intake__c.isAccessible()) {
                return new LeadQueueModels.QueueResponse('Insufficient permissions to access intake records');
            }
            
            // Field access validation
            try {
                validateFieldAccess();
            } catch (Exception e) {
                return new LeadQueueModels.QueueResponse('Missing required field permissions: ' + e.getMessage());
            }
            
            // Input validation with descriptive errors
            LeadQueueModels.ValidationResult validation = validateFilterInputs(statusFilter, caseTypeFilter, dueDateFilter, showScheduledCalls, tileFilter);
            if (!validation.isValid) {
                return new LeadQueueModels.QueueResponse(validation.errorMessage);
            }

            Integer safePageNumber = normalizePageNumber(pageNumber);
            Integer safePageSize = normalizePageSize(pageSize);
            Integer offset = (safePageNumber - 1) * safePageSize;
            String cacheKey = LeadQueueCacheRepository.buildQueueCacheKey(statusFilter, caseTypeFilter, dueDateFilter, showScheduledCalls, safePageNumber, safePageSize, tileFilter);
            if (bypassCache != true) {
                LeadQueueModels.QueueResponse cached = LeadQueueCacheRepository.getQueueResponse(cacheKey);
                if (cached != null) {
                    return cached;
                }
            }
            
            // Execute business logic
            List<litify_pm__Intake__c> records = queryRecords(statusFilter, caseTypeFilter, dueDateFilter, showScheduledCalls, tileFilter, safePageSize, offset);
            List<LeadQueueModels.QueueRecord> queueRecords = processRecords(records, showScheduledCalls);
            LeadQueueModels.QueueStats stats = calculateStatsForFilters(statusFilter, caseTypeFilter, dueDateFilter, showScheduledCalls);
            Integer listTotalRecords = String.isNotBlank(tileFilter)
                ? calculateListTotalRecords(statusFilter, caseTypeFilter, dueDateFilter, showScheduledCalls, tileFilter)
                : stats.totalRecords;
            
            LeadQueueModels.QueueResponse response = new LeadQueueModels.QueueResponse(queueRecords, stats, getFilterOptions(showScheduledCalls), LeadQueueQueryService.getTileStatusGroups(), listTotalRecords);
            LeadQueueCacheRepository.putQueueResponse(cacheKey, response);
            return response;
            
        } catch (Exception e) {
            // Fallback error handling for unexpected issues
            String userMessage = getUserFriendlyErrorMessage(e);
            return new LeadQueueModels.QueueResponse('An unexpected error occurred: ' + userMessage);
        }
    }
    
    @AuraEnabled
    public static LeadQueueModels.AssignmentResult assignNextAvailableRecord(String statusFilter, String caseTypeFilter, String dueDateFilter, Boolean showScheduledCalls, String tileFilter) {
        try {
            // Query multiple records to handle assignment conflicts based on current view
            List<litify_pm__Intake__c> records = getAvailableRecords(10, 0, statusFilter, caseTypeFilter, dueDateFilter, showScheduledCalls, tileFilter);
            String failureMessage = null;
            
            if (records.isEmpty()) {
                return new LeadQueueModels.AssignmentResult(false, 'No available records in queue');
            }
            
            // Try to assign records in priority order until successful
            for (litify_pm__Intake__c record : records) {
                if (LeadQueueEligibilityService.isValidQueueRecord(record)) {
                    LeadQueueModels.AssignmentResult result = assignRecord(record.Id);
                    if (result.success) {
                        result.recordId = record.Id;
                        result.recordName = record.Name;
                        return result;
                    } else if (!String.isBlank(result.message)) {
                        failureMessage = result.message;
                        if (result.message.contains('Platform Cache')) {
                            return new LeadQueueModels.AssignmentResult(false, failureMessage);
                        }
                    }
                }
            }
            
            return new LeadQueueModels.AssignmentResult(false, failureMessage != null ? failureMessage : 'No available records could be assigned');
        } catch (Exception e) {
            LeadQueueLogging.debug('Assignment next error: ' + e.getMessage());
            return new LeadQueueModels.AssignmentResult(false, 'Assignment failed');
        }
    }
    
    @AuraEnabled(cacheable=true)
    public static Boolean isCacheConfigured() {
        return LeadQueueCacheRepository.isCacheConfigured();
    }
    
    @AuraEnabled
    public static LeadQueueModels.AssignmentResult assignRecord(String recordId) {
        try {
            // Input validation
            if (String.isBlank(recordId)) {
                return new LeadQueueModels.AssignmentResult(false, 'Record ID is required');
            }
            
            if (!isValidSalesforceId(recordId)) {
                return new LeadQueueModels.AssignmentResult(false, 'Invalid record ID format');
            }

            if (!Schema.sObjectType.litify_pm__Intake__c.isAccessible()) {
                return new LeadQueueModels.AssignmentResult(false, 'Insufficient permissions to access intake records');
            }

            try {
                validateFieldAccess();
            } catch (Exception e) {
                return new LeadQueueModels.AssignmentResult(false, 'Missing required field permissions: ' + e.getMessage());
            }
            
            String query = 'SELECT ' + REQUIRED_FIELDS +
                ' FROM litify_pm__Intake__c' +
                ' WHERE Id = :recordId' +
                ' AND (Type__c NOT IN :excludedTypes OR Type__c = null)' +
                ' LIMIT 1';
            Map<String, Object> bindVars = new Map<String, Object>{
                'recordId' => recordId,
                'excludedTypes' => EXCLUDED_INTAKE_TYPES
            };
            List<litify_pm__Intake__c> records = Database.queryWithBinds(query, bindVars, AccessLevel.USER_MODE);
            
            if (records.isEmpty()) {
                return new LeadQueueModels.AssignmentResult(false, 'Record not found or not accessible');
            }
            litify_pm__Intake__c record = records[0];
            
            String userId = UserInfo.getUserId();
            Cache.OrgPartition orgCache = LeadQueueCacheRepository.getPartition();
            Boolean useSimulatedCache = orgCache == null && isSimulatedCacheActive();
            
            // If cache is unavailable, fail fast so users cannot take multiple records
            if (orgCache == null && !useSimulatedCache) {
                LeadQueueLogging.debug('LeadQueueService.assignRecord: Platform Cache unavailable for user ' + userId + ' and record ' + recordId);
                return new LeadQueueModels.AssignmentResult(false, 'Platform Cache not configured. Please contact your administrator.');
            }
            
            // Check if record is already assigned
            if (LeadQueueCacheRepository.isRecordAssigned(recordId)) {
                return new LeadQueueModels.AssignmentResult(false, 'Record already assigned to another user');
            }

            if (!LeadQueueEligibilityService.isEligibleForAssignment(record)) {
                return new LeadQueueModels.AssignmentResult(false, 'Record is not eligible for Lead Queue assignment');
            }
            
            if (LeadQueueCacheRepository.hasUserAssignment(userId)) {
                return new LeadQueueModels.AssignmentResult(false, 'User already has an assigned record. Release current assignment first.');
            }
            
            // Assign the record with timestamp
            Long assignedAt = Datetime.now().getTime();
            LeadQueueCacheRepository.putAssignment(recordId, userId, assignedAt);
            LeadQueueRefreshPublisher.publish('assign');
            return new LeadQueueModels.AssignmentResult(true, 'Record assigned successfully');
            
        } catch (Exception e) {
            LeadQueueLogging.debug('Assignment record error: ' + e.getMessage());
            return new LeadQueueModels.AssignmentResult(false, 'Assignment failed');
        }
    }
    
    @AuraEnabled
    public static Boolean releaseUserAssignments(String recordId) {
        try {
            String userId = UserInfo.getUserId();
            Boolean released = false;
            String normalizedRecordId = null;

            if (String.isNotBlank(recordId)) {
                String trimmedRecordId = recordId.trim();
                if (trimmedRecordId.endsWith('-assigned')) {
                    trimmedRecordId = trimmedRecordId.substring(0, trimmedRecordId.length() - 9);
                }
                if (isValidSalesforceId(trimmedRecordId)) {
                    normalizedRecordId = trimmedRecordId;
                }
            }

            String assignedRecord = LeadQueueCacheRepository.getUserAssignmentId(userId);
            if (assignedRecord != null) {
                LeadQueueCacheRepository.removeRecordAssignment(assignedRecord);
                released = true;
            }
            LeadQueueCacheRepository.removeUserAssignment(userId);
            if (!released && normalizedRecordId != null) {
                Map<String, Object> assignmentData = LeadQueueCacheRepository.getAssignmentData(normalizedRecordId);
                String assignedUserId = assignmentData != null ? (String) assignmentData.get('userId') : null;
                if (assignedUserId == userId) {
                    LeadQueueCacheRepository.removeRecordAssignment(normalizedRecordId);
                    released = true;
                }
            }
            
            if (released) {
                LeadQueueRefreshPublisher.publish('release');
            }
            return true;
            
        } catch (Exception e) {
            LeadQueueLogging.debug('Release assignments error: ' + e.getMessage());
            throw new AuraHandledException('Error releasing assignments');
        }
    }
    
    @AuraEnabled(cacheable=false)
    public static Map<String, Long> getUserAssignmentData() {
        try {
            String userId = UserInfo.getUserId();
            return LeadQueueCacheRepository.getUserAssignmentData(userId);
            
        } catch (Exception e) {
            LeadQueueLogging.debug('User assignments error: ' + e.getMessage());
            return new Map<String, Long>();
        }
    }

    @AuraEnabled(cacheable=true)
    public static LeadQueueModels.AssignedRecordSummary getAssignedRecordSummary(String recordId) {
        try {
            if (String.isBlank(recordId) || !isValidSalesforceId(recordId)) {
                return null;
            }

            if (!Schema.sObjectType.litify_pm__Intake__c.isAccessible()) {
                return null;
            }

            String query = 'SELECT Id, Name, litify_pm__Display_Name__c, litify_pm__Status__c' +
                ' FROM litify_pm__Intake__c WHERE Id = :recordId LIMIT 1';
            Map<String, Object> bindVars = new Map<String, Object>{ 'recordId' => recordId };
            List<litify_pm__Intake__c> records = Database.queryWithBinds(query, bindVars, AccessLevel.USER_MODE);
            if (records.isEmpty()) {
                return null;
            }

            litify_pm__Intake__c record = records[0];
            LeadQueueModels.AssignedRecordSummary summary = new LeadQueueModels.AssignedRecordSummary();
            summary.recordId = record.Id;
            summary.displayName = String.isNotBlank(record.litify_pm__Display_Name__c)
                ? record.litify_pm__Display_Name__c
                : record.Name;
            summary.status = record.litify_pm__Status__c;
            return summary;
        } catch (Exception e) {
            LeadQueueLogging.debug('getAssignedRecordSummary error: ' + e.getMessage());
            return null;
        }
    }
    
    // Keep legacy method for backwards compatibility
    @AuraEnabled(cacheable=false)
    public static List<String> getUserAssignedRecordIds() {
        Map<String, Long> assignmentData = getUserAssignmentData();
        return new List<String>(assignmentData.keySet());
    }
    
    @AuraEnabled
    public static void autoReleaseRecords(List<Id> recordIds) {
        try {
            Boolean didRelease = false;
            if (!LeadQueueCacheRepository.isCacheConfigured()) {
                LeadQueueLogging.debug('LeadQueueService.autoReleaseRecords: Platform Cache unavailable - assignment tracking limited for ' + recordIds.size() + ' records');
                return;
            }

            for (Id recordId : recordIds) {
                Map<String, Object> assignmentData = LeadQueueCacheRepository.getAssignmentData(recordId);
                String assignedUserId = assignmentData != null ? (String) assignmentData.get('userId') : null;
                if (assignmentData != null) {
                    didRelease = true;
                }

                LeadQueueCacheRepository.removeRecordAssignment(recordId);
                
                if (!String.isBlank(assignedUserId)) {
                    LeadQueueCacheRepository.removeUserAssignment(assignedUserId);
                    LeadQueueLogging.debug('Auto-released record: ' + recordId + ' from user: ' + assignedUserId);
                    didRelease = true;
                }
            }
            if (didRelease) {
                LeadQueueRefreshPublisher.publish('auto-release');
            }
        } catch (Exception e) {
            LeadQueueLogging.debug('Auto-release error: ' + e.getMessage());
        }
    }
    
    @AuraEnabled
    public static void handleIntakeFieldChanges(List<litify_pm__Intake__c> newRecords, Map<Id, litify_pm__Intake__c> oldRecordsMap) {
        Set<Id> recordsToRelease = new Set<Id>();
        
        for (litify_pm__Intake__c newRecord : newRecords) {
            litify_pm__Intake__c oldRecord = oldRecordsMap.get(newRecord.Id);
            
            // Check if fields that affect Call_at_Date__c formula have changed
            if (newRecord.Appointment_Date__c != oldRecord.Appointment_Date__c || 
                newRecord.Follow_Up_Date_Time__c != oldRecord.Follow_Up_Date_Time__c) {
                recordsToRelease.add(newRecord.Id);
            }
        }
        
        if (!recordsToRelease.isEmpty()) {
            autoReleaseRecords(new List<Id>(recordsToRelease));
        }
    }
    
    private static List<litify_pm__Intake__c> getAvailableRecords(Integer limitCount, Integer offset, String statusFilter, String caseTypeFilter, String dueDateFilter, Boolean showScheduledCalls, String tileFilter) {
        Boolean allowFutureWindow = 'nextWeek'.equalsIgnoreCase(dueDateFilter);
        String query = LeadQueueQueryService.buildBaseQuery(REQUIRED_FIELDS, showScheduledCalls, allowFutureWindow);
        
        Map<String, Object> bindVars = new Map<String, Object>();
        // Add the datetime bind variables for the base filter
        Datetime nowValue = Datetime.now();
        bindVars.put('now', nowValue);
        bindVars.put('twoHoursFromNow', nowValue.addHours(2));
        bindVars.put('fourHoursAgo', nowValue.addHours(-4));
        bindVars.put('twoWeeksFromNow', nowValue.addDays(14));
        bindVars.put('excludedTypes', EXCLUDED_INTAKE_TYPES);
        List<String> conditions = LeadQueueQueryService.buildFilterConditions(statusFilter, caseTypeFilter, dueDateFilter, tileFilter, bindVars);
        
        if (conditions.size() > 0) {
            query += ' AND ' + String.join(conditions, ' AND ');
        }
        
        query += ' ' + (showScheduledCalls ? SCHEDULED_CALL_ORDER_BY : READY_TO_CALL_ORDER_BY);
        if (limitCount != null) {
            query += ' LIMIT ' + limitCount;
        }
        if (offset != null && offset > 0) {
            query += ' OFFSET ' + offset;
        }
        
        return Database.queryWithBinds(query, bindVars, AccessLevel.USER_MODE);
    }
    
    private static List<litify_pm__Intake__c> queryRecords(String statusFilter, String caseTypeFilter, String dueDateFilter, Boolean showScheduledCalls, String tileFilter, Integer limitCount, Integer offset) {
        return getAvailableRecords(limitCount, offset, statusFilter, caseTypeFilter, dueDateFilter, showScheduledCalls, tileFilter);
    }
    
    private static List<LeadQueueModels.QueueRecord> processRecords(List<litify_pm__Intake__c> records, Boolean showScheduledCalls) {
        List<LeadQueueModels.QueueRecord> queueRecords = new List<LeadQueueModels.QueueRecord>();
        
        // Collect all assigned user IDs for batch query
        Set<Id> assignedUserIds = new Set<Id>();
        Map<Id, String> assignedUserByRecord = new Map<Id, String>();
        Map<Id, Long> assignedTimestampByRecord = new Map<Id, Long>();
        for (litify_pm__Intake__c record : records) {
            if (LeadQueueEligibilityService.isValidQueueRecord(record)) {
                Map<String, Object> assignmentData = LeadQueueCacheRepository.getAssignmentData(record.Id);
                if (assignmentData != null) {
                    String assignedUserId = (String) assignmentData.get('userId');
                    if (String.isNotBlank(assignedUserId)) {
                        assignedUserByRecord.put(record.Id, assignedUserId);
                        assignedUserIds.add(assignedUserId);
                    }
                    Long assignedAt = LeadQueueCacheRepository.parseAssignmentTimestamp(assignmentData.get('assignedAt'));
                    if (assignedAt != null) {
                        assignedTimestampByRecord.put(record.Id, assignedAt);
                    }
                }
            }
        }
        
        // Batch query for all assigned user names
        Map<Id, String> userIdToNameMap = new Map<Id, String>();
        if (!assignedUserIds.isEmpty()) {
            try {
                List<User> users = [SELECT Id, Name FROM User WHERE Id IN :assignedUserIds AND IsActive = true];
                for (User user : users) {
                    userIdToNameMap.put(user.Id, user.Name);
                }
            } catch (Exception e) {
                LeadQueueLogging.debug('Error querying users: ' + e.getMessage());
            }
        }
        
        // Create queue records with batched user names
        for (litify_pm__Intake__c record : records) {
            // Validate record meets business criteria before processing
            if (LeadQueueEligibilityService.isValidQueueRecord(record)) {
                queueRecords.add(createQueueRecord(record, userIdToNameMap, assignedUserByRecord, assignedTimestampByRecord));
            }
        }
        return queueRecords;
    }
    
    private static LeadQueueModels.QueueRecord createQueueRecord(litify_pm__Intake__c record, Map<Id, String> userIdToNameMap, Map<Id, String> assignedUserByRecord, Map<Id, Long> assignedTimestampByRecord) {
        LeadQueueModels.QueueRecord qr = new LeadQueueModels.QueueRecord();
        String assignedUserId = assignedUserByRecord.get(record.Id);
        qr.record = record;
        qr.recordId = String.valueOf(record.Id);
        qr.displayName = record.litify_pm__Display_Name__c;
        qr.referredByName = record.Referred_By_Name__c;
        qr.status = record.litify_pm__Status__c;
        qr.caseType = record.Queue_Case_Type__c;
        qr.qualificationStatus = record.Qualification_Status__c;
        qr.callAtDate = record.Call_at_Date__c;
        qr.phone = record.litify_pm__Phone__c;
        qr.priorityScore = record.Priority_Score__c != null ? record.Priority_Score__c.intValue() : 99;
        qr.isHighPriority = qr.priorityScore <= HIGH_PRIORITY_THRESHOLD;
        qr.isDueToday = isDueToday(record.Call_at_Date__c);
        qr.isOverdue = isOverdue(record.Call_at_Date__c);
        qr.isAssigned = String.isNotBlank(assignedUserId);
        qr.assignedTo = assignedUserId != null ? userIdToNameMap.get(assignedUserId) ?? '' : '';
        qr.assignedTimestamp = assignedTimestampByRecord.get(record.Id);
        return qr;
    }
    
    
    private static LeadQueueModels.QueueStats calculateStats(List<LeadQueueModels.QueueRecord> records) {
        LeadQueueModels.QueueStats stats = new LeadQueueModels.QueueStats();
        stats.totalRecords = records.size();
        
        for (LeadQueueModels.QueueRecord record : records) {
            String status = record.record.litify_pm__Status__c;
            
            // High Priority: Intake Scheduled OR Lead Generated
            if (LeadQueueQueryService.isStatusInGroup('highPriority', status)) {
                stats.highPriorityCount++;
            }
            
            // In Contact: In Contact/Under Review OR Questionnaire OR Missed Appointment
            if (LeadQueueQueryService.isStatusInGroup('inContact', status)) {
                stats.inContactCount++;
            }
            
            // No Contact: Attempting to Contact
            if (LeadQueueQueryService.isStatusInGroup('noContact', status)) {
                stats.noContactCount++;
            }
            
            // Retainer Sent: Intake Package Sent
            if (LeadQueueQueryService.isStatusInGroup('retainerSent', status)) {
                stats.retainerSentCount++;
            }
            
            if (LeadQueueQueryService.isStatusInGroup('referrals', status)) {
                stats.referralCount++;
            }
        }
        
        return stats;
    }

    private static LeadQueueModels.QueueStats calculateStatsForFilters(String statusFilter, String caseTypeFilter, String dueDateFilter, Boolean showScheduledCalls) {
        LeadQueueModels.QueueStats stats = new LeadQueueModels.QueueStats();
        Boolean allowFutureWindow = 'nextWeek'.equalsIgnoreCase(dueDateFilter);
        String whereClause = LeadQueueQueryService.buildBaseWhereClause(showScheduledCalls, allowFutureWindow);

        Map<String, Object> bindVars = new Map<String, Object>();
        Datetime nowValue = Datetime.now();
        bindVars.put('now', nowValue);
        bindVars.put('twoHoursFromNow', nowValue.addHours(2));
        bindVars.put('fourHoursAgo', nowValue.addHours(-4));
        bindVars.put('twoWeeksFromNow', nowValue.addDays(14));
        bindVars.put('excludedTypes', EXCLUDED_INTAKE_TYPES);

        List<String> conditions = LeadQueueQueryService.buildFilterConditions(statusFilter, caseTypeFilter, dueDateFilter, null, bindVars);
        if (!conditions.isEmpty()) {
            whereClause += ' AND ' + String.join(conditions, ' AND ');
        }

        String query = 'SELECT litify_pm__Status__c status, COUNT(Id) total FROM litify_pm__Intake__c WHERE ' +
            whereClause + ' GROUP BY litify_pm__Status__c';
        List<AggregateResult> results = Database.queryWithBinds(query, bindVars, AccessLevel.USER_MODE);
        Integer total = 0;
        for (AggregateResult result : results) {
            String status = (String) result.get('status');
            Integer count = Integer.valueOf(String.valueOf(result.get('total')));
            total += count;
            if (LeadQueueQueryService.isStatusInGroup('highPriority', status)) {
                stats.highPriorityCount += count;
            }
            if (LeadQueueQueryService.isStatusInGroup('inContact', status)) {
                stats.inContactCount += count;
            }
            if (LeadQueueQueryService.isStatusInGroup('noContact', status)) {
                stats.noContactCount += count;
            }
            if (LeadQueueQueryService.isStatusInGroup('retainerSent', status)) {
                stats.retainerSentCount += count;
            }
            if (LeadQueueQueryService.isStatusInGroup('referrals', status)) {
                stats.referralCount += count;
            }
        }
        stats.totalRecords = total;
        return stats;
    }

    private static Integer calculateListTotalRecords(String statusFilter, String caseTypeFilter, String dueDateFilter, Boolean showScheduledCalls, String tileFilter) {
        Boolean allowFutureWindow = 'nextWeek'.equalsIgnoreCase(dueDateFilter);
        String whereClause = LeadQueueQueryService.buildBaseWhereClause(showScheduledCalls, allowFutureWindow);

        Map<String, Object> bindVars = new Map<String, Object>();
        Datetime nowValue = Datetime.now();
        bindVars.put('now', nowValue);
        bindVars.put('twoHoursFromNow', nowValue.addHours(2));
        bindVars.put('fourHoursAgo', nowValue.addHours(-4));
        bindVars.put('twoWeeksFromNow', nowValue.addDays(14));
        bindVars.put('excludedTypes', EXCLUDED_INTAKE_TYPES);

        List<String> conditions = LeadQueueQueryService.buildFilterConditions(statusFilter, caseTypeFilter, dueDateFilter, tileFilter, bindVars);
        if (!conditions.isEmpty()) {
            whereClause += ' AND ' + String.join(conditions, ' AND ');
        }

        String query = 'SELECT COUNT(Id) total FROM litify_pm__Intake__c WHERE ' + whereClause;
        List<AggregateResult> results = Database.queryWithBinds(query, bindVars, AccessLevel.USER_MODE);
        if (!results.isEmpty()) {
            return Integer.valueOf(String.valueOf(results[0].get('total')));
        }
        return 0;
    }

    private static LeadQueueModels.FilterOptions getFilterOptions(Boolean showScheduledCalls) {
        LeadQueueModels.FilterOptions options = new LeadQueueModels.FilterOptions();
        
        options.statusOptions = buildStatusOptions(showScheduledCalls);
        
        options.caseTypeOptions = new List<LeadQueueModels.PicklistOption>();
        options.caseTypeOptions.add(new LeadQueueModels.PicklistOption('All Case Types', ''));
        for (String caseType : getOrderedCaseTypes()) {
            options.caseTypeOptions.add(new LeadQueueModels.PicklistOption(caseType, caseType));
        }
        
        return options;
    }

    private static List<LeadQueueModels.PicklistOption> buildStatusOptions(Boolean showScheduledCalls) {
        List<LeadQueueModels.PicklistOption> options = new List<LeadQueueModels.PicklistOption>();
        options.add(new LeadQueueModels.PicklistOption('All Statuses', ''));
        Set<String> allowedStatuses = showScheduledCalls
            ? LeadQueueEligibilityService.getScheduledCallStatuses()
            : LeadQueueEligibilityService.getReadyToCallStatuses();
        for (String status : STATUS_ORDER) {
            if (allowedStatuses.contains(status)) {
                options.add(new LeadQueueModels.PicklistOption(status, status));
            }
        }
        return options;
    }

    private static List<String> getOrderedCaseTypes() {
        List<String> caseTypes = new List<String>(LeadQueueConfig.CASE_TYPE_PRIORITY.keySet());
        caseTypes.sort(new CaseTypePriorityComparator());
        return caseTypes;
    }

    private class CaseTypePriorityComparator implements Comparator<String> {
        public Integer compare(String a, String b) {
            if (a == null && b == null) {
                return 0;
            }
            if (a == null) {
                return 1;
            }
            if (b == null) {
                return -1;
            }
            Integer aPriority = LeadQueueConfig.CASE_TYPE_PRIORITY.get(a);
            Integer bPriority = LeadQueueConfig.CASE_TYPE_PRIORITY.get(b);
            if (aPriority == null && bPriority == null) {
                return a.toLowerCase().compareTo(b.toLowerCase());
            }
            if (aPriority == null) {
                return 1;
            }
            if (bPriority == null) {
                return -1;
            }
            Integer diff = aPriority - bPriority;
            return diff != 0 ? diff : a.toLowerCase().compareTo(b.toLowerCase());
        }
    }
    
    private static final Date TODAY = Date.today();
    
    private static void validateFieldAccess() {
        Map<String, Schema.SObjectField> fieldMap = Schema.sObjectType.litify_pm__Intake__c.fields.getMap();
        List<String> missingFields = new List<String>();
        
        for (String fieldName : REQUIRED_ACCESS_FIELD_SET) {
            if (!fieldMap.containsKey(fieldName) || !fieldMap.get(fieldName).getDescribe().isAccessible()) {
                missingFields.add(fieldName);
            }
        }
        
        if (!missingFields.isEmpty()) {
            throw new AuraHandledException('Access denied to required field(s): ' + String.join(missingFields, ', ') + '. Please contact your administrator for field permissions.');
        }
    }
    
    private static Boolean isDueToday(Datetime callDateTime) {
        return callDateTime != null && callDateTime.date() == TODAY;
    }
    
    private static Boolean isOverdue(Datetime callDateTime) {
        return callDateTime != null && callDateTime.date() < TODAY;
    }
    
}

