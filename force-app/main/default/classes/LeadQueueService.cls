public with sharing class LeadQueueService {
    
    private static final Map<String, Integer> STATUS_PRIORITY = new Map<String, Integer>{
        'Lead Generated' => 1,
        'Intake Scheduled' => 2,
        'In Contact/Under Review' => 3,
        'Missed Appointment' => 4,
        'Intake Package Sent' => 5,
        'Attempting to Contact' => 6,
        'Questionnaire' => 7
    };
    
    private static final Map<String, Integer> CASE_TYPE_PRIORITY = new Map<String, Integer>{
        'Labor Law' => 1,
        'MVA' => 2,
        'Premises' => 3,
        'Personal Injury' => 4,
        'Worker Compensation' => 5
    };
    
    private static final Integer ASSIGNMENT_TTL = 1800; // 30 minutes
    private static final String CACHE_PARTITION = 'local.LeadQueueCache';
    private static final Integer HIGH_PRIORITY_THRESHOLD = 22;
    private static final Integer MEDIUM_PRIORITY_THRESHOLD = 55;
    private static final String BASE_WHERE_CLAUSE = '(Test_Record__c = false OR Test_Record__c = null) AND Call_at_Date__c <= :now AND Type__c IN (\'Worker Compensation\', \'Personal Injury\') AND (litify_pm__Status__c IN (\'Lead Generated\', \'In Contact/Under Review\', \'Missed Appointment\', \'Intake Package Sent\', \'Attempting to Contact\', \'Questionnaire\') OR (litify_pm__Status__c = \'Intake Scheduled\' AND (litify_pm__Sign_Up_Method__c = \'E-Sign\' OR (litify_pm__Sign_Up_Method__c = \'Office\' AND Call_at_Date__c <= :twoHoursFromNow))))';
    private static final String BASE_ORDER_BY = 'ORDER BY Priority_Score__c ASC, Call_at_Date__c ASC';
    private static final String REQUIRED_FIELDS = 'Id, Name, litify_pm__Display_Name__c, Referred_By_Name__c, litify_pm__Status__c, Priority_Score__c, CreatedDate, Case_Type_Reporting__c, Type__c, Call_at_Date__c, litify_pm__Phone__c, litify_pm__Sign_Up_Method__c, Test_Record__c, Qualification_Status__c';
    private static final String ASSIGNMENT_CACHE_PREFIX = 'assign';
    private static final String USER_CACHE_PREFIX = 'user';
    
    @AuraEnabled(cacheable=true)
    public static QueueResponse getQueueData(String statusFilter, String caseTypeFilter, String dueDateFilter, Boolean showScheduledCalls) {
        try {
            if (!Schema.sObjectType.litify_pm__Intake__c.isAccessible()) {
                throw new AuraHandledException('Insufficient permissions to access intake records');
            }
            
            validateFieldAccess();
            validateFilterInputs(statusFilter, caseTypeFilter, dueDateFilter);
            
            List<litify_pm__Intake__c> records = queryRecords(statusFilter, caseTypeFilter, dueDateFilter, showScheduledCalls);
            List<QueueRecord> queueRecords = processRecords(records, showScheduledCalls);
            QueueStats stats = calculateStats(queueRecords);
            
            return new QueueResponse(queueRecords, stats, getFilterOptions());
            
        } catch (Exception e) {
            // Provide specific user-friendly messages based on exception type
            String userMessage = getUserFriendlyErrorMessage(e);
            AuraHandledException ahe = new AuraHandledException(userMessage);
            ahe.setMessage(userMessage);
            throw ahe;
        }
    }
    
    @AuraEnabled
    public static AssignmentResult assignNextAvailableRecord(Boolean showScheduledCalls) {
        try {
            // Query multiple records to handle assignment conflicts based on current view
            List<litify_pm__Intake__c> records = getAvailableRecords(10, '', '', '', showScheduledCalls);
            
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
                    }
                }
            }
            
            return new AssignmentResult(false, 'No available records could be assigned');
        } catch (Exception e) {
            System.debug('Assignment next error: ' + e.getMessage());
            return new AssignmentResult(false, 'Assignment failed');
        }
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
            
            List<litify_pm__Intake__c> records = [
                SELECT Id FROM litify_pm__Intake__c 
                WHERE Id = :recordId 
                AND Type__c IN ('Worker Compensation', 'Personal Injury')
                LIMIT 1
            ];
            
            if (records.isEmpty()) {
                return new AssignmentResult(false, 'Record not found or not accessible');
            }
            
            String userId = UserInfo.getUserId();
            Cache.OrgPartition orgCache = getCachePartition();
            
            // If cache is unavailable, allow assignment with warning
            if (orgCache == null) {
                System.debug('LeadQueueService.assignRecord: Platform Cache unavailable for user ' + userId + ' - assignment tracking limited for record ' + recordId);
                return new AssignmentResult(true, 'Record assigned (cache unavailable - assignment tracking limited)');
            }
            
            // Check if record is already assigned
            if (isRecordAssigned(recordId)) {
                return new AssignmentResult(false, 'Record already assigned to another user');
            }
            
            // Check if user already has an assignment to prevent multiple assignments
            String existingAssignment = (String) orgCache.get(USER_CACHE_PREFIX + userId);
            if (existingAssignment != null) {
                return new AssignmentResult(false, 'User already has an assigned record. Release current assignment first.');
            }
            
            // Assign the record
            orgCache.put(ASSIGNMENT_CACHE_PREFIX + recordId, userId, ASSIGNMENT_TTL);
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
    public static List<String> getUserAssignedRecordIds() {
        try {
            String userId = UserInfo.getUserId();
            Cache.OrgPartition orgCache = getCachePartition();
            String assignedRecordId = null;
            if (orgCache != null) {
                assignedRecordId = (String) orgCache.get(USER_CACHE_PREFIX + userId);
            }
            return assignedRecordId != null ? new List<String>{assignedRecordId} : new List<String>();
            
        } catch (Exception e) {
            System.debug('User assignments error: ' + e.getMessage());
            throw new AuraHandledException('Failed to check user assignments: ' + e.getMessage());
        }
    }
    
    @AuraEnabled
    public static void autoReleaseRecords(List<Id> recordIds) {
        try {
            Cache.OrgPartition orgCache = getCachePartition();
            if (orgCache == null) {
                System.debug('LeadQueueService.autoReleaseRecords: Platform Cache unavailable - assignment tracking limited for ' + recordIds.size() + ' records');
                return;
            }
            
            for (Id recordId : recordIds) {
                String assignedUserId = (String) orgCache.get(ASSIGNMENT_CACHE_PREFIX + recordId);
                if (assignedUserId != null) {
                    // Remove record assignment
                    orgCache.remove(ASSIGNMENT_CACHE_PREFIX + recordId);
                    
                    // Remove user assignment
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
    
    private static String buildBaseQuery(Boolean showScheduledCalls) {
        String baseConditions = '(Test_Record__c = false OR Test_Record__c = null) AND Type__c IN (\'Worker Compensation\', \'Personal Injury\')';
        
        if (showScheduledCalls == true) {
            // Scheduled calls: show future appointments
            String statusCondition = '(litify_pm__Status__c IN (\'Lead Generated\', \'In Contact/Under Review\', \'Missed Appointment\', \'Intake Package Sent\', \'Attempting to Contact\', \'Questionnaire\') OR (litify_pm__Status__c = \'Intake Scheduled\' AND (litify_pm__Sign_Up_Method__c = \'E-Sign\' OR (litify_pm__Sign_Up_Method__c = \'Office\' AND Call_at_Date__c <= :twoHoursFromNow))))';
            String whereClause = baseConditions + ' AND Call_at_Date__c > :now AND ' + statusCondition;
            return 'SELECT ' + REQUIRED_FIELDS + ' FROM litify_pm__Intake__c WHERE ' + whereClause;
        } else {
            // Ready to call: different time criteria per status
            String complexCondition = '(' +
                // Standard statuses: show if Call_at_Date__c <= now
                '(litify_pm__Status__c IN (\'Lead Generated\', \'In Contact/Under Review\', \'Missed Appointment\', \'Intake Package Sent\', \'Attempting to Contact\') AND Call_at_Date__c <= :now)' +
                ' OR ' +
                // Questionnaire: show only if Call_at_Date__c <= 4 hours ago (exclude recent)
                '(litify_pm__Status__c = \'Questionnaire\' AND Call_at_Date__c <= :fourHoursAgo)' +
                ' OR ' +
                // Intake Scheduled: no 4-hour restriction
                '(litify_pm__Status__c = \'Intake Scheduled\' AND (litify_pm__Sign_Up_Method__c = \'E-Sign\' OR (litify_pm__Sign_Up_Method__c = \'Office\' AND Call_at_Date__c <= :twoHoursFromNow)))' +
                ')';
            
            String whereClause = baseConditions + ' AND ' + complexCondition;
            return 'SELECT ' + REQUIRED_FIELDS + ' FROM litify_pm__Intake__c WHERE ' + whereClause;
        }
    }
    
    private static List<litify_pm__Intake__c> getAvailableRecords(Integer limitCount, String statusFilter, String caseTypeFilter, String dueDateFilter, Boolean showScheduledCalls) {
        String query = buildBaseQuery(showScheduledCalls);
        
        Map<String, Object> bindVars = new Map<String, Object>();
        // Add the datetime bind variables for the base filter
        bindVars.put('now', Datetime.now());
        bindVars.put('twoHoursFromNow', Datetime.now().addHours(-2));
        bindVars.put('fourHoursAgo', Datetime.now().addHours(-4));
        
        List<String> conditions = new List<String>();
        
        if (String.isNotBlank(statusFilter)) {
            conditions.add('litify_pm__Status__c = :statusFilter');
            bindVars.put('statusFilter', statusFilter);
        }
        
        if (String.isNotBlank(caseTypeFilter)) {
            conditions.add('Case_Type_Reporting__c = :caseTypeFilter');
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
        
        query += ' ' + BASE_ORDER_BY;
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
        for (litify_pm__Intake__c record : records) {
            if (isValidQueueRecord(record)) {
                String assignedUserId = getAssignedUserId(record.Id);
                if (String.isNotBlank(assignedUserId)) {
                    assignedUserIds.add(assignedUserId);
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
                queueRecords.add(createQueueRecord(record, userIdToNameMap));
            }
        }
        if (showScheduledCalls == true) {
            queueRecords.sort(new DateComparator());
        } else {
            queueRecords.sort(new PriorityComparator());
        }
        return queueRecords;
    }
    
    private static Boolean isValidQueueRecord(litify_pm__Intake__c record) {
        return record.Call_at_Date__c != null 
            && String.isNotBlank(record.Case_Type_Reporting__c)
            && String.isNotBlank(record.litify_pm__Status__c)
            && CASE_TYPE_PRIORITY.containsKey(record.Case_Type_Reporting__c)
            && STATUS_PRIORITY.containsKey(record.litify_pm__Status__c);
    }
    
    private static QueueRecord createQueueRecord(litify_pm__Intake__c record, Map<Id, String> userIdToNameMap) {
        QueueRecord qr = new QueueRecord();
        qr.record = record;
        qr.priorityScore = record.Priority_Score__c != null ? Integer.valueOf(record.Priority_Score__c) : 99;
        qr.isHighPriority = qr.priorityScore <= HIGH_PRIORITY_THRESHOLD;
        qr.isDueToday = isDueToday(record.Call_at_Date__c);
        qr.isOverdue = isOverdue(record.Call_at_Date__c);
        qr.isAssigned = isRecordAssigned(record.Id);
        qr.assignedTo = getAssignedUserNameFromMap(record.Id, userIdToNameMap);
        return qr;
    }
    
    
    private static QueueStats calculateStats(List<QueueRecord> records) {
        QueueStats stats = new QueueStats();
        stats.totalRecords = records.size();
        
        for (QueueRecord record : records) {
            String status = record.record.litify_pm__Status__c;
            
            // High Priority: Intake Scheduled OR Lead Generated
            if (status == 'Intake Scheduled' || status == 'Lead Generated') {
                stats.highPriorityCount++;
            }
            
            // In Contact: In Contact/Under Review OR Questionnaire OR Missed Appointment
            if (status == 'In Contact/Under Review' || status == 'Questionnaire' || status == 'Missed Appointment') {
                stats.inContactCount++;
            }
            
            // No Contact: Attempting to Contact
            if (status == 'Attempting to Contact') {
                stats.noContactCount++;
            }
            
            // Retainer Sent: Intake Package Sent
            if (status == 'Intake Package Sent') {
                stats.retainerSentCount++;
            }
        }
        
        return stats;
    }
    
    private static FilterOptions getFilterOptions() {
        FilterOptions options = new FilterOptions();
        
        options.statusOptions = new List<PicklistOption>();
        options.statusOptions.add(new PicklistOption('All Statuses', ''));
        for (String status : STATUS_PRIORITY.keySet()) {
            options.statusOptions.add(new PicklistOption(status, status));
        }
        
        options.caseTypeOptions = new List<PicklistOption>();
        options.caseTypeOptions.add(new PicklistOption('All Case Types', ''));
        for (String caseType : CASE_TYPE_PRIORITY.keySet()) {
            options.caseTypeOptions.add(new PicklistOption(caseType, caseType));
        }
        
        return options;
    }
    
    
    private static Boolean isRecordAssigned(String recordId) {
        try {
            Cache.OrgPartition orgCache = getCachePartition();
            if (orgCache == null) {
                return false;
            }
            String assignedUserId = (String) orgCache.get(ASSIGNMENT_CACHE_PREFIX + recordId);
            return assignedUserId != null;
        } catch (Exception e) {
            return false;
        }
    }
    
    
    private static String getAssignedUserId(String recordId) {
        try {
            Cache.OrgPartition orgCache = getCachePartition();
            if (orgCache == null) {
                return '';
            }
            return (String) orgCache.get(ASSIGNMENT_CACHE_PREFIX + recordId);
        } catch (Exception e) {
            System.debug('Error getting assigned user ID: ' + e.getMessage());
            return '';
        }
    }
    
    private static String getAssignedUserNameFromMap(String recordId, Map<Id, String> userIdToNameMap) {
        try {
            String assignedUserId = getAssignedUserId(recordId);
            if (String.isBlank(assignedUserId)) {
                return '';
            }
            return userIdToNameMap.get(assignedUserId) ?? '';
        } catch (Exception e) {
            System.debug('Error getting assigned user name from map: ' + e.getMessage());
            return '';
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
        try {
            Map<String, Schema.SObjectField> fieldMap = Schema.sObjectType.litify_pm__Intake__c.fields.getMap();
            List<String> fields = new List<String>{'litify_pm__Status__c', 'Case_Type_Reporting__c', 'Call_at_Date__c', 'litify_pm__Phone__c', 'Priority_Score__c', 'Qualification_Status__c'};
            
            for (String field : fields) {
                Boolean fieldExists = fieldMap.containsKey(field);
                Boolean fieldAccessible = fieldExists ? fieldMap.get(field).getDescribe().isAccessible() : false;
                
                if (!fieldExists || !fieldAccessible) {
                    throw new AuraHandledException('Access denied to required field: ' + field + '. Please contact your administrator for field permissions.');
                }
            }
        } catch (Exception e) {
            throw e;
        }
    }
    
    private static Boolean isDueToday(Datetime callDateTime) {
        return callDateTime != null && callDateTime.date() == TODAY;
    }
    
    private static Boolean isOverdue(Datetime callDateTime) {
        return callDateTime != null && callDateTime.date() < TODAY;
    }
    
    public class PriorityComparator implements Comparator<QueueRecord> {
        public Integer compare(QueueRecord a, QueueRecord b) {
            if (a.priorityScore != b.priorityScore) {
                return a.priorityScore - b.priorityScore;
            }
            
            if (a.record.Call_at_Date__c == null && b.record.Call_at_Date__c == null) return 0;
            if (a.record.Call_at_Date__c == null) return 1;
            if (b.record.Call_at_Date__c == null) return -1;
            
            return a.record.Call_at_Date__c < b.record.Call_at_Date__c ? -1 : 
                   a.record.Call_at_Date__c > b.record.Call_at_Date__c ? 1 : 0;
        }
    }
    
    public class DateComparator implements Comparator<QueueRecord> {
        public Integer compare(QueueRecord a, QueueRecord b) {
            if (a.record.Call_at_Date__c == null && b.record.Call_at_Date__c == null) return 0;
            if (a.record.Call_at_Date__c == null) return 1;
            if (b.record.Call_at_Date__c == null) return -1;
            
            return a.record.Call_at_Date__c < b.record.Call_at_Date__c ? -1 : 
                   a.record.Call_at_Date__c > b.record.Call_at_Date__c ? 1 : 0;
        }
    }
    
    public class QueueResponse {
        @AuraEnabled public List<QueueRecord> records { get; set; }
        @AuraEnabled public QueueStats stats { get; set; }
        @AuraEnabled public FilterOptions filters { get; set; }
        
        public QueueResponse(List<QueueRecord> records, QueueStats stats, FilterOptions filters) {
            this.records = records;
            this.stats = stats;
            this.filters = filters;
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
    }
    
    public class QueueStats {
        @AuraEnabled public Integer totalRecords { get; set; }
        @AuraEnabled public Integer highPriorityCount { get; set; }
        @AuraEnabled public Integer inContactCount { get; set; }
        @AuraEnabled public Integer noContactCount { get; set; }
        @AuraEnabled public Integer retainerSentCount { get; set; }
        
        public QueueStats() {
            this.totalRecords = 0;
            this.highPriorityCount = 0;
            this.inContactCount = 0;
            this.noContactCount = 0;
            this.retainerSentCount = 0;
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
    
    private static void validateFilterInputs(String statusFilter, String caseTypeFilter, String dueDateFilter) {
        if (String.isNotBlank(statusFilter) && !STATUS_PRIORITY.containsKey(statusFilter)) {
            throw new AuraHandledException('Invalid status filter value');
        }
        if (String.isNotBlank(caseTypeFilter) && !CASE_TYPE_PRIORITY.containsKey(caseTypeFilter)) {
            throw new AuraHandledException('Invalid case type filter value');
        }
        if (String.isNotBlank(dueDateFilter) && !isValidDateFilter(dueDateFilter)) {
            throw new AuraHandledException('Invalid date filter value');
        }
    }
    
    private static Boolean isValidDateFilter(String dateFilter) {
        return new Set<String>{'today', 'thisWeek', 'nextWeek'}.contains(dateFilter);
    }
    
    private static String getUserFriendlyErrorMessage(Exception e) {
        String exceptionType = e.getTypeName();
        if (exceptionType.contains('QueryException')) {
            return 'Database query error. Please contact your administrator.';
        } else if (exceptionType.contains('SecurityException') || e.getMessage().contains('permission')) {
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