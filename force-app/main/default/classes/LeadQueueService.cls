public with sharing class LeadQueueService {
    
    private static final List<String> STATUS_ORDER = LeadQueueConfig.STATUS_ORDER;
    
    private static final Set<String> ALL_QUEUE_STATUSES = new Set<String>(STATUS_ORDER);
    private static final Set<String> READY_TO_CALL_STATUSES = ALL_QUEUE_STATUSES;
    private static final Set<String> SCHEDULED_CALL_STATUSES = buildScheduledCallStatuses();
    
    private static final Map<String, Set<String>> TILE_STATUS_GROUPS = new Map<String, Set<String>>{
        'highPriority' => new Set<String>{'Intake Scheduled', 'Lead Generated'},
        'inContact' => new Set<String>{'In Contact/Under Review', 'Questionnaire', 'Missed Appointment'},
        'noContact' => new Set<String>{'Attempting to Contact'},
        'retainerSent' => new Set<String>{'Intake Package Sent'},
        'referrals' => new Set<String>{'Referral Pending'}
    };
    
    private static final Set<String> EXCLUDED_INTAKE_TYPES = new Set<String>{
        'SSD',
        'Civil Rights'
    };
    
    private static final Integer ASSIGNMENT_TTL = 1800; // 30 minutes
    private static final String CACHE_PARTITION = 'local.LeadQueueCache';
    private static final Integer HIGH_PRIORITY_THRESHOLD = 22;
    private static final String READY_TO_CALL_ORDER_BY = 'ORDER BY Priority_Score__c ASC, Call_at_Date__c ASC';
    private static final String SCHEDULED_CALL_ORDER_BY = 'ORDER BY Call_at_Date__c ASC';
    private static final String REQUIRED_FIELDS = 'Id, Name, litify_pm__Display_Name__c, Referred_By_Name__c, litify_pm__Status__c, Priority_Score__c, CreatedDate, Queue_Case_Type__c, Type__c, Call_at_Date__c, litify_pm__Phone__c, litify_pm__Sign_Up_Method__c, Test_Record__c, Qualification_Status__c';
    private static final Set<String> REQUIRED_FIELD_SET = buildRequiredFieldSet();
    private static final String ASSIGNMENT_CACHE_PREFIX = 'assign';
    private static final String USER_CACHE_PREFIX = 'user';

    @TestVisible private static Boolean simulateCacheAvailability = false;
    @TestVisible private static Map<String, String> simulatedRecordAssignments = new Map<String, String>();
    @TestVisible private static Map<String, String> simulatedUserAssignments = new Map<String, String>();
    @TestVisible private static Map<String, Long> simulatedAssignmentTimestamps = new Map<String, Long>();
    
    private static Boolean isSimulatedCacheActive() {
        return Test.isRunningTest() && simulateCacheAvailability;
    }
    
    @TestVisible
    static void resetSimulatedCache() {
        simulatedRecordAssignments.clear();
        simulatedUserAssignments.clear();
        simulatedAssignmentTimestamps.clear();
    }
    
    @TestVisible
    static void enableCacheSimulation(Boolean shouldSimulate) {
        System.assert(Test.isRunningTest(), 'Cache simulation can only be enabled during tests');
        simulateCacheAvailability = shouldSimulate;
        if (!shouldSimulate) {
            resetSimulatedCache();
        }
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

    private static Set<String> buildScheduledCallStatuses() {
        Set<String> result = new Set<String>(STATUS_ORDER);
        result.remove('Referral Pending');
        return result;
    }
    
    @AuraEnabled
    public static QueueResponse getQueueData(String statusFilter, String caseTypeFilter, String dueDateFilter, Boolean showScheduledCalls) {
        try {
            // Security validation
            if (!Schema.sObjectType.litify_pm__Intake__c.isAccessible()) {
                return new QueueResponse('Insufficient permissions to access intake records');
            }
            
            // Field access validation
            try {
                validateFieldAccess();
            } catch (Exception e) {
                return new QueueResponse('Missing required field permissions: ' + e.getMessage());
            }
            
            // Input validation with descriptive errors
            ValidationResult validation = validateFilterInputs(statusFilter, caseTypeFilter, dueDateFilter, showScheduledCalls);
            if (!validation.isValid) {
                return new QueueResponse(validation.errorMessage);
            }
            
            // Execute business logic
            List<litify_pm__Intake__c> records = queryRecords(statusFilter, caseTypeFilter, dueDateFilter, showScheduledCalls);
            List<QueueRecord> queueRecords = processRecords(records, showScheduledCalls);
            QueueStats stats = calculateStats(queueRecords);
            
            return new QueueResponse(queueRecords, stats, getFilterOptions(showScheduledCalls), buildTileStatusGroups());
            
        } catch (Exception e) {
            // Fallback error handling for unexpected issues
            String userMessage = getUserFriendlyErrorMessage(e);
            return new QueueResponse('An unexpected error occurred: ' + userMessage);
        }
    }
    
    @AuraEnabled
    public static AssignmentResult assignNextAvailableRecord(String statusFilter, String caseTypeFilter, String dueDateFilter, Boolean showScheduledCalls) {
        try {
            // Query multiple records to handle assignment conflicts based on current view
            List<litify_pm__Intake__c> records = getAvailableRecords(10, statusFilter, caseTypeFilter, dueDateFilter, showScheduledCalls);
            String failureMessage = null;
            
            if (records.isEmpty()) {
                return new AssignmentResult(false, 'No available records in queue');
            }
            
            // Try to assign records in priority order until successful
            for (litify_pm__Intake__c record : records) {
                if (isValidQueueRecord(record)) {
                    AssignmentResult result = assignRecord(record.Id);
                    if (result.success) {
                        result.recordId = record.Id;
                        result.recordName = record.Name;
                        return result;
                    } else if (!String.isBlank(result.message)) {
                        failureMessage = result.message;
                        if (result.message.contains('Platform Cache')) {
                            return new AssignmentResult(false, failureMessage);
                        }
                    }
                }
            }
            
            return new AssignmentResult(false, failureMessage != null ? failureMessage : 'No available records could be assigned');
        } catch (Exception e) {
            System.debug('Assignment next error: ' + e.getMessage());
            return new AssignmentResult(false, 'Assignment failed');
        }
    }
    
    @AuraEnabled(cacheable=true)
    public static Boolean isCacheConfigured() {
        return getCachePartition() != null || isSimulatedCacheActive();
    }
    
    @AuraEnabled
    public static AssignmentResult assignRecord(String recordId) {
        try {
            // Input validation
            if (String.isBlank(recordId)) {
                return new AssignmentResult(false, 'Record ID is required');
            }
            
            if (!isValidSalesforceId(recordId)) {
                return new AssignmentResult(false, 'Invalid record ID format');
            }

            if (!Schema.sObjectType.litify_pm__Intake__c.isAccessible()) {
                return new AssignmentResult(false, 'Insufficient permissions to access intake records');
            }

            try {
                validateFieldAccess();
            } catch (Exception e) {
                return new AssignmentResult(false, 'Missing required field permissions: ' + e.getMessage());
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
                return new AssignmentResult(false, 'Record not found or not accessible');
            }
            litify_pm__Intake__c record = records[0];
            
            String userId = UserInfo.getUserId();
            Cache.OrgPartition orgCache = getCachePartition();
            Boolean useSimulatedCache = orgCache == null && isSimulatedCacheActive();
            
            // If cache is unavailable, fail fast so users cannot take multiple records
            if (orgCache == null && !useSimulatedCache) {
                System.debug('LeadQueueService.assignRecord: Platform Cache unavailable for user ' + userId + ' and record ' + recordId);
                return new AssignmentResult(false, 'Platform Cache not configured. Please contact your administrator.');
            }
            
            // Check if record is already assigned
            if (isRecordAssigned(recordId)) {
                return new AssignmentResult(false, 'Record already assigned to another user');
            }

            if (!isEligibleForAssignment(record)) {
                return new AssignmentResult(false, 'Record is not eligible for Lead Queue assignment');
            }
            
            if (useSimulatedCache) {
                if (simulatedUserAssignments.containsKey(userId)) {
                    return new AssignmentResult(false, 'User already has an assigned record. Release current assignment first.');
                }
                Long assignedAt = Datetime.now().getTime();
                simulatedRecordAssignments.put(recordId, userId);
                simulatedUserAssignments.put(userId, recordId);
                simulatedAssignmentTimestamps.put(recordId, assignedAt);
                return new AssignmentResult(true, 'Record assigned successfully');
            }
            
            // Check if user already has an assignment to prevent multiple assignments
            String existingAssignment = (String) orgCache.get(USER_CACHE_PREFIX + userId);
            if (existingAssignment != null) {
                return new AssignmentResult(false, 'User already has an assigned record. Release current assignment first.');
            }
            
            // Assign the record with timestamp
            Map<String, Object> assignmentData = new Map<String, Object>{
                'userId' => userId,
                'assignedAt' => Datetime.now().getTime()
            };
            orgCache.put(ASSIGNMENT_CACHE_PREFIX + recordId, JSON.serialize(assignmentData), ASSIGNMENT_TTL);
            orgCache.put(USER_CACHE_PREFIX + userId, recordId, ASSIGNMENT_TTL);
            return new AssignmentResult(true, 'Record assigned successfully');
            
        } catch (Exception e) {
            System.debug('Assignment record error: ' + e.getMessage());
            return new AssignmentResult(false, 'Assignment failed');
        }
    }
    
    @AuraEnabled
    public static Boolean releaseUserAssignments() {
        try {
            String userId = UserInfo.getUserId();
            Cache.OrgPartition orgCache = getCachePartition();
            Boolean useSimulatedCache = orgCache == null && isSimulatedCacheActive();
            
            if (useSimulatedCache) {
                String assignedRecord = simulatedUserAssignments.get(userId);
                if (assignedRecord != null) {
                    simulatedRecordAssignments.remove(assignedRecord);
                    simulatedAssignmentTimestamps.remove(assignedRecord);
                }
                simulatedUserAssignments.remove(userId);
                return true;
            }
            
            if (orgCache != null) {
                String assignedRecord = (String) orgCache.get(USER_CACHE_PREFIX + userId);
                
                if (assignedRecord != null) {
                    orgCache.remove(ASSIGNMENT_CACHE_PREFIX + assignedRecord);
                }
                orgCache.remove(USER_CACHE_PREFIX + userId);
            }
            
            return true;
            
        } catch (Exception e) {
            System.debug('Release assignments error: ' + e.getMessage());
            throw new AuraHandledException('Error releasing assignments');
        }
    }
    
    @AuraEnabled(cacheable=false)
    public static Map<String, Long> getUserAssignmentData() {
        try {
            String userId = UserInfo.getUserId();
            Cache.OrgPartition orgCache = getCachePartition();
            Boolean useSimulatedCache = orgCache == null && isSimulatedCacheActive();
            String assignedRecordId = null;
            if (useSimulatedCache) {
                assignedRecordId = simulatedUserAssignments.get(userId);
            } else if (orgCache != null) {
                assignedRecordId = (String) orgCache.get(USER_CACHE_PREFIX + userId);
            }
            
            Map<String, Long> result = new Map<String, Long>();
            if (assignedRecordId != null) {
                Long timestamp = getAssignmentTimestamp(assignedRecordId);
                result.put(assignedRecordId, timestamp);
            }
            return result;
            
        } catch (Exception e) {
            System.debug('User assignments error: ' + e.getMessage());
            return new Map<String, Long>();
        }
    }

    @AuraEnabled(cacheable=true)
    public static AssignedRecordSummary getAssignedRecordSummary(String recordId) {
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
            AssignedRecordSummary summary = new AssignedRecordSummary();
            summary.recordId = record.Id;
            summary.displayName = String.isNotBlank(record.litify_pm__Display_Name__c)
                ? record.litify_pm__Display_Name__c
                : record.Name;
            summary.status = record.litify_pm__Status__c;
            return summary;
        } catch (Exception e) {
            System.debug('getAssignedRecordSummary error: ' + e.getMessage());
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
            Cache.OrgPartition orgCache = getCachePartition();
            Boolean useSimulatedCache = orgCache == null && isSimulatedCacheActive();
            if (orgCache == null && !useSimulatedCache) {
                System.debug('LeadQueueService.autoReleaseRecords: Platform Cache unavailable - assignment tracking limited for ' + recordIds.size() + ' records');
                return;
            }
            
            if (useSimulatedCache) {
                for (Id recordId : recordIds) {
                    String assignedUserId = simulatedRecordAssignments.remove(recordId);
                    simulatedAssignmentTimestamps.remove(recordId);
                    if (!String.isBlank(assignedUserId)) {
                        simulatedUserAssignments.remove(assignedUserId);
                        System.debug('Auto-released record (simulated cache): ' + recordId + ' from user: ' + assignedUserId);
                    }
                }
                return;
            }
            
            for (Id recordId : recordIds) {
                String assignedUserId = null;
                String assignmentJson = (String) orgCache.get(ASSIGNMENT_CACHE_PREFIX + recordId);
                
                if (!String.isBlank(assignmentJson)) {
                    try {
                        Map<String, Object> assignmentData = (Map<String, Object>) JSON.deserializeUntyped(assignmentJson);
                        assignedUserId = assignmentData != null ? (String) assignmentData.get('userId') : null;
                    } catch (Exception parseError) {
                        System.debug('Auto-release parse error for record ' + recordId + ': ' + parseError.getMessage());
                    }
                }

                orgCache.remove(ASSIGNMENT_CACHE_PREFIX + recordId);
                
                if (!String.isBlank(assignedUserId)) {
                    orgCache.remove(USER_CACHE_PREFIX + assignedUserId);
                    System.debug('Auto-released record: ' + recordId + ' from user: ' + assignedUserId);
                }
            }
        } catch (Exception e) {
            System.debug('Auto-release error: ' + e.getMessage());
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
    
    private static String buildBaseQuery(Boolean showScheduledCalls, Boolean allowFutureWindow) {
        String baseConditions = '(Test_Record__c = false OR Test_Record__c = null) AND (Type__c NOT IN :excludedTypes OR Type__c = null)';
        
        if (showScheduledCalls == true) {
            // Scheduled calls: show future appointments
            String scheduledStandardStatuses = buildStatusInClause(getScheduledCallStandardStatuses());
            String statusCondition = '(litify_pm__Status__c IN ' + scheduledStandardStatuses +
                ' OR (litify_pm__Status__c = \'Intake Scheduled\' AND (litify_pm__Sign_Up_Method__c = \'E-Sign\' OR (litify_pm__Sign_Up_Method__c = \'Office\' AND Call_at_Date__c >= :twoHoursFromNow))))';
            String timeClause = allowFutureWindow
                ? 'Call_at_Date__c >= :now AND Call_at_Date__c <= :twoWeeksFromNow'
                : 'Call_at_Date__c >= :now';
            String whereClause = baseConditions + ' AND ' + statusCondition + ' AND ' + timeClause;
            return 'SELECT ' + REQUIRED_FIELDS + ' FROM litify_pm__Intake__c WHERE ' + whereClause;
        } else {
            if (allowFutureWindow) {
                String readyStandardStatuses = buildStatusInClause(getReadyToCallStandardStatuses());
                String futureCondition = '(' +
                    '(litify_pm__Status__c IN ' + readyStandardStatuses + ')' +
                    ' OR ' +
                    '(litify_pm__Status__c = \'Questionnaire\')' +
                    ' OR ' +
                    '(litify_pm__Status__c = \'Intake Scheduled\')' +
                ')';
                
                String whereClause = baseConditions + ' AND ' + futureCondition;
                return 'SELECT ' + REQUIRED_FIELDS + ' FROM litify_pm__Intake__c WHERE ' + whereClause;
            }
            
            // Ready to call: different time criteria per status
            String readyStandardStatuses = buildStatusInClause(getReadyToCallStandardStatuses());
            String complexCondition = '(' +
                // Standard statuses: show if Call_at_Date__c <= now
                '(litify_pm__Status__c IN ' + readyStandardStatuses + ' AND Call_at_Date__c <= :now)' +
                ' OR ' +
                // Questionnaire: show only if Call_at_Date__c <= 4 hours ago (exclude recent)
                '(litify_pm__Status__c = \'Questionnaire\' AND Call_at_Date__c <= :fourHoursAgo)' +
                ' OR ' +
                // Intake Scheduled: show if Call_at_Date__c <= now (no 4-hour restriction)
                '(litify_pm__Status__c = \'Intake Scheduled\' AND (' +
                    '(litify_pm__Sign_Up_Method__c = \'E-Sign\' AND Call_at_Date__c <= :now)' +
                    ' OR ' +
                    '(litify_pm__Sign_Up_Method__c = \'Office\' AND Call_at_Date__c <= :now)' +
                '))' +
                ')';
            
            String whereClause = baseConditions + ' AND ' + complexCondition;
            return 'SELECT ' + REQUIRED_FIELDS + ' FROM litify_pm__Intake__c WHERE ' + whereClause;
        }
    }

    private static String buildStatusInClause(List<String> statuses) {
        if (statuses == null || statuses.isEmpty()) {
            return '(\'\')';
        }
        List<String> quoted = new List<String>();
        for (String status : statuses) {
            quoted.add('\'' + String.escapeSingleQuotes(status) + '\'');
        }
        return '(' + String.join(quoted, ', ') + ')';
    }

    private static List<String> getReadyToCallStandardStatuses() {
        return getStatusesMinus(READY_TO_CALL_STATUSES, new Set<String>{'Questionnaire', 'Intake Scheduled'});
    }

    private static List<String> getScheduledCallStandardStatuses() {
        return getStatusesMinus(SCHEDULED_CALL_STATUSES, new Set<String>{'Intake Scheduled'});
    }

    private static List<String> getStatusesMinus(Set<String> source, Set<String> exclude) {
        List<String> result = new List<String>();
        for (String status : STATUS_ORDER) {
            if (source.contains(status) && !exclude.contains(status)) {
                result.add(status);
            }
        }
        return result;
    }

    private static Set<String> getStatusesForView(Boolean showScheduledCalls) {
        return showScheduledCalls ? SCHEDULED_CALL_STATUSES : READY_TO_CALL_STATUSES;
    }

    private static Set<String> getAllQueueStatuses() {
        return ALL_QUEUE_STATUSES;
    }
    
    private static List<litify_pm__Intake__c> getAvailableRecords(Integer limitCount, String statusFilter, String caseTypeFilter, String dueDateFilter, Boolean showScheduledCalls) {
        Boolean allowFutureWindow = 'nextWeek'.equalsIgnoreCase(dueDateFilter);
        String query = buildBaseQuery(showScheduledCalls, allowFutureWindow);
        
        Map<String, Object> bindVars = new Map<String, Object>();
        // Add the datetime bind variables for the base filter
        Datetime nowValue = Datetime.now();
        bindVars.put('now', nowValue);
        bindVars.put('twoHoursFromNow', nowValue.addHours(2));
        bindVars.put('fourHoursAgo', nowValue.addHours(-4));
        bindVars.put('twoWeeksFromNow', nowValue.addDays(14));
        bindVars.put('excludedTypes', EXCLUDED_INTAKE_TYPES);
        
        List<String> conditions = new List<String>();
        
        if (String.isNotBlank(statusFilter)) {
            conditions.add('litify_pm__Status__c = :statusFilter');
            bindVars.put('statusFilter', statusFilter);
        }
        
        if (String.isNotBlank(caseTypeFilter)) {
            conditions.add('Queue_Case_Type__c = :caseTypeFilter');
            bindVars.put('caseTypeFilter', caseTypeFilter);
        }
        
        if (String.isNotBlank(dueDateFilter)) {
            String dateCondition = getDateCondition(dueDateFilter);
            if (dateCondition != null) {
                conditions.add(dateCondition);
            }
        }
        
        if (conditions.size() > 0) {
            query += ' AND ' + String.join(conditions, ' AND ');
        }
        
        query += ' ' + (showScheduledCalls ? SCHEDULED_CALL_ORDER_BY : READY_TO_CALL_ORDER_BY);
        if (limitCount != null) {
            query += ' LIMIT ' + limitCount;
        }
        
        return Database.queryWithBinds(query, bindVars, AccessLevel.USER_MODE);
    }
    
    private static List<litify_pm__Intake__c> queryRecords(String statusFilter, String caseTypeFilter, String dueDateFilter, Boolean showScheduledCalls) {
        return getAvailableRecords(1000, statusFilter, caseTypeFilter, dueDateFilter, showScheduledCalls);
    }
    
    private static List<QueueRecord> processRecords(List<litify_pm__Intake__c> records, Boolean showScheduledCalls) {
        List<QueueRecord> queueRecords = new List<QueueRecord>();
        
        // Collect all assigned user IDs for batch query
        Set<Id> assignedUserIds = new Set<Id>();
        Map<Id, String> assignedUserByRecord = new Map<Id, String>();
        Map<Id, Long> assignedTimestampByRecord = new Map<Id, Long>();
        for (litify_pm__Intake__c record : records) {
            if (isValidQueueRecord(record)) {
                Map<String, Object> assignmentData = getAssignmentData(record.Id);
                if (assignmentData != null) {
                    String assignedUserId = (String) assignmentData.get('userId');
                    if (String.isNotBlank(assignedUserId)) {
                        assignedUserByRecord.put(record.Id, assignedUserId);
                        assignedUserIds.add(assignedUserId);
                    }
                    Long assignedAt = parseAssignmentTimestamp(assignmentData.get('assignedAt'));
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
                System.debug('Error querying users: ' + e.getMessage());
            }
        }
        
        // Create queue records with batched user names
        for (litify_pm__Intake__c record : records) {
            // Validate record meets business criteria before processing
            if (isValidQueueRecord(record)) {
                queueRecords.add(createQueueRecord(record, userIdToNameMap, assignedUserByRecord, assignedTimestampByRecord));
            }
        }
        return queueRecords;
    }
    
    private static Boolean isValidQueueRecord(litify_pm__Intake__c record) {
        return record.Call_at_Date__c != null
            && String.isNotBlank(record.litify_pm__Status__c)
            && getAllQueueStatuses().contains(record.litify_pm__Status__c)
            && (String.isBlank(record.Queue_Case_Type__c)
                || LeadQueueConfig.CASE_TYPE_PRIORITY.containsKey(record.Queue_Case_Type__c));
    }

    private static Boolean isEligibleForAssignment(litify_pm__Intake__c record) {
        if (!isValidQueueRecord(record)) {
            return false;
        }
        if (record.Test_Record__c == true) {
            return false;
        }
        Datetime nowValue = Datetime.now();
        return isEligibleForReadyToCall(record, nowValue)
            || isEligibleForScheduledCalls(record, nowValue);
    }

    private static Boolean isEligibleForReadyToCall(litify_pm__Intake__c record, Datetime nowValue) {
        if (record.Call_at_Date__c == null || String.isBlank(record.litify_pm__Status__c)) {
            return false;
        }
        String status = record.litify_pm__Status__c;
        if (getReadyToCallStandardStatuses().contains(status)) {
            return record.Call_at_Date__c <= nowValue;
        }
        if (status == 'Questionnaire') {
            return record.Call_at_Date__c <= nowValue.addHours(-4);
        }
        if (status == 'Intake Scheduled') {
            Boolean validMethod = record.litify_pm__Sign_Up_Method__c == 'E-Sign'
                || record.litify_pm__Sign_Up_Method__c == 'Office';
            return validMethod && record.Call_at_Date__c <= nowValue;
        }
        return false;
    }

    private static Boolean isEligibleForScheduledCalls(litify_pm__Intake__c record, Datetime nowValue) {
        if (record.Call_at_Date__c == null || String.isBlank(record.litify_pm__Status__c)) {
            return false;
        }
        String status = record.litify_pm__Status__c;
        if (getScheduledCallStandardStatuses().contains(status)) {
            return record.Call_at_Date__c >= nowValue;
        }
        if (status == 'Intake Scheduled') {
            if (record.litify_pm__Sign_Up_Method__c == 'E-Sign') {
                return record.Call_at_Date__c >= nowValue;
            }
            if (record.litify_pm__Sign_Up_Method__c == 'Office') {
                return record.Call_at_Date__c >= nowValue.addHours(2);
            }
        }
        return false;
    }
    
    private static QueueRecord createQueueRecord(litify_pm__Intake__c record, Map<Id, String> userIdToNameMap, Map<Id, String> assignedUserByRecord, Map<Id, Long> assignedTimestampByRecord) {
        QueueRecord qr = new QueueRecord();
        String assignedUserId = assignedUserByRecord.get(record.Id);
        qr.record = record;
        qr.priorityScore = record.Priority_Score__c != null ? Integer.valueOf(record.Priority_Score__c) : 99;
        qr.isHighPriority = qr.priorityScore <= HIGH_PRIORITY_THRESHOLD;
        qr.isDueToday = isDueToday(record.Call_at_Date__c);
        qr.isOverdue = isOverdue(record.Call_at_Date__c);
        qr.isAssigned = String.isNotBlank(assignedUserId);
        qr.assignedTo = assignedUserId != null ? userIdToNameMap.get(assignedUserId) ?? '' : '';
        qr.assignedTimestamp = assignedTimestampByRecord.get(record.Id);
        return qr;
    }
    
    
    private static QueueStats calculateStats(List<QueueRecord> records) {
        QueueStats stats = new QueueStats();
        stats.totalRecords = records.size();
        
        for (QueueRecord record : records) {
            String status = record.record.litify_pm__Status__c;
            
            // High Priority: Intake Scheduled OR Lead Generated
            if (isStatusInGroup('highPriority', status)) {
                stats.highPriorityCount++;
            }
            
            // In Contact: In Contact/Under Review OR Questionnaire OR Missed Appointment
            if (isStatusInGroup('inContact', status)) {
                stats.inContactCount++;
            }
            
            // No Contact: Attempting to Contact
            if (isStatusInGroup('noContact', status)) {
                stats.noContactCount++;
            }
            
            // Retainer Sent: Intake Package Sent
            if (isStatusInGroup('retainerSent', status)) {
                stats.retainerSentCount++;
            }
            
            if (isStatusInGroup('referrals', status)) {
                stats.referralCount++;
            }
        }
        
        return stats;
    }

    private static Boolean isStatusInGroup(String groupKey, String status) {
        Set<String> statusGroup = TILE_STATUS_GROUPS.get(groupKey);
        return statusGroup != null && statusGroup.contains(status);
    }
    
    private static FilterOptions getFilterOptions(Boolean showScheduledCalls) {
        FilterOptions options = new FilterOptions();
        
        options.statusOptions = buildStatusOptions(showScheduledCalls);
        
        options.caseTypeOptions = new List<PicklistOption>();
        options.caseTypeOptions.add(new PicklistOption('All Case Types', ''));
        for (String caseType : getOrderedCaseTypes()) {
            options.caseTypeOptions.add(new PicklistOption(caseType, caseType));
        }
        
        return options;
    }

    private static List<PicklistOption> buildStatusOptions(Boolean showScheduledCalls) {
        List<PicklistOption> options = new List<PicklistOption>();
        options.add(new PicklistOption('All Statuses', ''));
        Set<String> allowedStatuses = getStatusesForView(showScheduledCalls);
        for (String status : STATUS_ORDER) {
            if (allowedStatuses.contains(status)) {
                options.add(new PicklistOption(status, status));
            }
        }
        return options;
    }

    private static Map<String, List<String>> buildTileStatusGroups() {
        Map<String, List<String>> result = new Map<String, List<String>>();
        for (String key : TILE_STATUS_GROUPS.keySet()) {
            result.put(key, new List<String>(TILE_STATUS_GROUPS.get(key)));
        }
        return result;
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
    
    
    private static Boolean isRecordAssigned(String recordId) {
        try {
            if (isSimulatedCacheActive()) {
                return simulatedRecordAssignments.containsKey(recordId);
            }
            Cache.OrgPartition orgCache = getCachePartition();
            if (orgCache == null) {
                return false;
            }
            String assignmentJson = (String) orgCache.get(ASSIGNMENT_CACHE_PREFIX + recordId);
            return assignmentJson != null;
        } catch (Exception e) {
            return false;
        }
    }
    
    
    private static Map<String, Object> getAssignmentData(String recordId) {
        try {
            if (isSimulatedCacheActive()) {
                if (!simulatedRecordAssignments.containsKey(recordId)) {
                    return null;
                }
                Map<String, Object> simulatedData = new Map<String, Object>{
                    'userId' => simulatedRecordAssignments.get(recordId)
                };
                if (simulatedAssignmentTimestamps.containsKey(recordId)) {
                    simulatedData.put('assignedAt', simulatedAssignmentTimestamps.get(recordId));
                }
                return simulatedData;
            }
            Cache.OrgPartition orgCache = getCachePartition();
            if (orgCache == null) {
                return null;
            }
            String assignmentJson = (String) orgCache.get(ASSIGNMENT_CACHE_PREFIX + recordId);
            if (String.isBlank(assignmentJson)) {
                return null;
            }
            return (Map<String, Object>) JSON.deserializeUntyped(assignmentJson);
        } catch (Exception e) {
            System.debug('Error getting assignment data: ' + e.getMessage());
            return null;
        }
    }
    
    private static Long getAssignmentTimestamp(String recordId) {
        try {
            Map<String, Object> assignmentData = getAssignmentData(recordId);
            if (assignmentData == null || !assignmentData.containsKey('assignedAt')) {
                return null;
            }
            return parseAssignmentTimestamp(assignmentData.get('assignedAt'));
        } catch (Exception e) {
            System.debug('Error getting assignment timestamp: ' + e.getMessage());
            return null;
        }
    }

    private static Long parseAssignmentTimestamp(Object rawValue) {
        if (rawValue == null) {
            return null;
        }
        if (rawValue instanceof Long) {
            return (Long) rawValue;
        }
        try {
            Decimal numericValue = Decimal.valueOf(String.valueOf(rawValue));
            return numericValue != null ? numericValue.longValue() : null;
        } catch (Exception parseError) {
            System.debug('Assignment timestamp parse error: ' + parseError.getMessage());
            return null;
        }
    }
    
    private static Cache.OrgPartition getCachePartition() {
        try {
            Cache.OrgPartition partition = Cache.Org.getPartition(CACHE_PARTITION);
            if (partition == null) {
                System.debug('Cache partition not available for user: ' + UserInfo.getUserId());
                return null;
            }
            return partition;
        } catch (Exception e) {
            System.debug('Cache partition error for user ' + UserInfo.getUserId() + ': ' + e.getMessage());
            return null;
        }
    }
    
    private static final Date TODAY = Date.today();
    
    private static String getDateCondition(String dueDateFilter) {
        switch on dueDateFilter {
            when 'today' { return 'Call_at_Date__c >= TODAY AND Call_at_Date__c < TOMORROW'; }
            when 'thisWeek' { return 'Call_at_Date__c >= THIS_WEEK AND Call_at_Date__c < NEXT_WEEK'; }
            when 'nextWeek' { return 'Call_at_Date__c >= NEXT_WEEK AND Call_at_Date__c < NEXT_N_WEEKS:2'; }
            when else { return null; }
        }
    }
    
    private static void validateFieldAccess() {
        Map<String, Schema.SObjectField> fieldMap = Schema.sObjectType.litify_pm__Intake__c.fields.getMap();
        List<String> missingFields = new List<String>();
        
        for (String fieldName : REQUIRED_FIELD_SET) {
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
    
    public class QueueResponse {
        @AuraEnabled public Boolean success { get; set; }
        @AuraEnabled public String errorMessage { get; set; }
        @AuraEnabled public List<QueueRecord> records { get; set; }
        @AuraEnabled public QueueStats stats { get; set; }
        @AuraEnabled public FilterOptions filters { get; set; }
        @AuraEnabled public Map<String, List<String>> tileStatusGroups { get; set; }
        
        // Success constructor
        public QueueResponse(List<QueueRecord> records, QueueStats stats, FilterOptions filters, Map<String, List<String>> tileStatusGroups) {
            this.success = true;
            this.records = records;
            this.stats = stats;
            this.filters = filters;
            this.tileStatusGroups = tileStatusGroups;
        }
        
        // Error constructor
        public QueueResponse(String errorMessage) {
            this.success = false;
            this.errorMessage = errorMessage;
            this.records = new List<QueueRecord>();
            this.stats = new QueueStats();
            this.filters = new FilterOptions();
            this.tileStatusGroups = new Map<String, List<String>>();
        }
    }
    
    public class QueueRecord {
        @AuraEnabled public litify_pm__Intake__c record { get; set; }
        @AuraEnabled public Integer priorityScore { get; set; }
        @AuraEnabled public Boolean isHighPriority { get; set; }
        @AuraEnabled public Boolean isDueToday { get; set; }
        @AuraEnabled public Boolean isOverdue { get; set; }
        @AuraEnabled public Boolean isAssigned { get; set; }
        @AuraEnabled public String assignedTo { get; set; }
        @AuraEnabled public Long assignedTimestamp { get; set; }
    }
    
    public class QueueStats {
        @AuraEnabled public Integer totalRecords { get; set; }
        @AuraEnabled public Integer highPriorityCount { get; set; }
        @AuraEnabled public Integer inContactCount { get; set; }
        @AuraEnabled public Integer noContactCount { get; set; }
        @AuraEnabled public Integer retainerSentCount { get; set; }
        @AuraEnabled public Integer referralCount { get; set; }
        
        public QueueStats() {
            this.totalRecords = 0;
            this.highPriorityCount = 0;
            this.inContactCount = 0;
            this.noContactCount = 0;
            this.retainerSentCount = 0;
            this.referralCount = 0;
        }
    }
    
    public class FilterOptions {
        @AuraEnabled public List<PicklistOption> statusOptions { get; set; }
        @AuraEnabled public List<PicklistOption> caseTypeOptions { get; set; }
    }
    
    public class PicklistOption {
        @AuraEnabled public String label { get; set; }
        @AuraEnabled public String value { get; set; }
        
        public PicklistOption(String label, String value) {
            this.label = label;
            this.value = value;
        }
    }
    
    public class AssignmentResult {
        @AuraEnabled public Boolean success { get; set; }
        @AuraEnabled public String message { get; set; }
        @AuraEnabled public String recordId { get; set; }
        @AuraEnabled public String recordName { get; set; }
        
        public AssignmentResult(Boolean success, String message) {
            this.success = success;
            this.message = message;
        }
    }

    public class AssignedRecordSummary {
        @AuraEnabled public Id recordId { get; set; }
        @AuraEnabled public String displayName { get; set; }
        @AuraEnabled public String status { get; set; }
    }
    
    public class ValidationResult {
        public Boolean isValid { get; set; }
        public String errorMessage { get; set; }
        
        public ValidationResult(Boolean isValid, String errorMessage) {
            this.isValid = isValid;
            this.errorMessage = errorMessage;
        }
    }
    
    private static ValidationResult validateFilterInputs(String statusFilter, String caseTypeFilter, String dueDateFilter, Boolean showScheduledCalls) {
        if (String.isNotBlank(statusFilter) && !getStatusesForView(showScheduledCalls).contains(statusFilter)) {
            List<String> validStatuses = getStatusListForMessage(showScheduledCalls);
            return new ValidationResult(false, 'Invalid status filter: ' + statusFilter + '. Valid options: ' + String.join(validStatuses, ', '));
        }
        if (String.isNotBlank(caseTypeFilter) && !LeadQueueConfig.CASE_TYPE_PRIORITY.containsKey(caseTypeFilter)) {
            return new ValidationResult(false, 'Invalid case type filter: ' + caseTypeFilter + '. Valid options: ' + String.join(getOrderedCaseTypes(), ', '));
        }
        if (String.isNotBlank(dueDateFilter) && !isValidDateFilter(dueDateFilter)) {
            return new ValidationResult(false, 'Invalid date filter: ' + dueDateFilter + '. Valid options: today, thisWeek, nextWeek');
        }
        return new ValidationResult(true, null);
    }

    private static List<String> getStatusListForMessage(Boolean showScheduledCalls) {
        List<String> result = new List<String>();
        Set<String> allowedStatuses = getStatusesForView(showScheduledCalls);
        for (String status : STATUS_ORDER) {
            if (allowedStatuses.contains(status)) {
                result.add(status);
            }
        }
        return result;
    }
    
    private static Boolean isValidDateFilter(String dateFilter) {
        return new Set<String>{'today', 'thisWeek', 'nextWeek'}.contains(dateFilter);
    }
    
    private static String getUserFriendlyErrorMessage(Exception e) {
        String exceptionType = e.getTypeName();
        if (exceptionType.contains('QueryException')) {
            return 'Database query error. Please contact your administrator.';
        } else if (exceptionType.contains('SecurityException') || (e.getMessage() != null && e.getMessage().contains('permission'))) {
            return 'Insufficient permissions to access intake records';
        } else {
            return 'Error loading queue data. Please contact your administrator if this persists.';
        }
    }
    
    private static Boolean isValidSalesforceId(String recordId) {
        if (String.isBlank(recordId)) {
            return false;
        }
        
        // Check if it's 15 or 18 characters and alphanumeric
        Pattern idPattern = Pattern.compile('[a-zA-Z0-9]{15}([a-zA-Z0-9]{3})?');
        return idPattern.matcher(recordId).matches();
    }
    
}
