public with sharing class LeadQueueQueryService {
    private static final List<String> STATUS_ORDER = LeadQueueConfig.STATUS_ORDER;
    private static final Integer DEFAULT_PAGE_SIZE = 50;
    private static final Integer MAX_PAGE_SIZE = 200;
    private static final Integer HIGH_PRIORITY_THRESHOLD = 22;
    private static final String READY_TO_CALL_ORDER_BY = 'ORDER BY Priority_Score__c ASC, Call_at_Date__c ASC';
    private static final String SCHEDULED_CALL_ORDER_BY = 'ORDER BY Call_at_Date__c ASC';
    private static final String REQUIRED_FIELDS = 'Id, Name, litify_pm__Display_Name__c, Referred_By_Name__c, litify_pm__Status__c, Priority_Score__c, Queue_Case_Type__c, Call_at_Date__c, litify_pm__Phone__c, litify_pm__Sign_Up_Method__c, Test_Record__c, Qualification_Status__c';
    private static final Set<String> EXCLUDED_INTAKE_TYPES = new Set<String>{
        'SSD',
        'Civil Rights'
    };
    private static final Set<String> REQUIRED_FIELD_SET = buildRequiredFieldSet();
    private static final Set<String> REQUIRED_ACCESS_FIELD_SET = buildRequiredAccessFieldSet();
    private static final Date TODAY = Date.today();

    private static final Map<String, Set<String>> TILE_STATUS_GROUPS = new Map<String, Set<String>>{
        'highPriority' => new Set<String>{'Intake Scheduled', 'Lead Generated'},
        'inContact' => new Set<String>{'In Contact/Under Review', 'Questionnaire', 'Missed Appointment'},
        'noContact' => new Set<String>{'Attempting to Contact'},
        'retainerSent' => new Set<String>{'Intake Package Sent'},
        'referrals' => new Set<String>{'Referral Pending'}
    };

    public static LeadQueueModels.QueueResponse getQueueData(String statusFilter, String caseTypeFilter, String dueDateFilter, Boolean showScheduledCalls) {
        return getQueueDataPaged(statusFilter, caseTypeFilter, dueDateFilter, showScheduledCalls, null, null, null, false);
    }

    public static LeadQueueModels.QueueResponse getQueueDataPaged(String statusFilter, String caseTypeFilter, String dueDateFilter, Boolean showScheduledCalls, Integer pageNumber, Integer pageSize, String tileFilter, Boolean bypassCache) {
        try {
            if (!Schema.sObjectType.litify_pm__Intake__c.isAccessible()) {
                return new LeadQueueModels.QueueResponse('Insufficient permissions to access intake records');
            }

            try {
                validateFieldAccess();
            } catch (Exception e) {
                return new LeadQueueModels.QueueResponse('Missing required field permissions: ' + e.getMessage());
            }

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

            List<litify_pm__Intake__c> records = queryRecords(statusFilter, caseTypeFilter, dueDateFilter, showScheduledCalls, tileFilter, safePageSize, offset);
            List<LeadQueueModels.QueueRecord> queueRecords = processRecords(records, showScheduledCalls);
            LeadQueueModels.QueueStats stats = calculateStatsForFilters(statusFilter, caseTypeFilter, dueDateFilter, showScheduledCalls);
            Integer listTotalRecords = String.isNotBlank(tileFilter)
                ? calculateListTotalRecords(statusFilter, caseTypeFilter, dueDateFilter, showScheduledCalls, tileFilter)
                : stats.totalRecords;

            LeadQueueModels.QueueResponse response = new LeadQueueModels.QueueResponse(queueRecords, stats, getFilterOptions(showScheduledCalls), getTileStatusGroups(), listTotalRecords);
            LeadQueueCacheRepository.putQueueResponse(cacheKey, response);
            return response;

        } catch (Exception e) {
            String userMessage = getUserFriendlyErrorMessage(e);
            return new LeadQueueModels.QueueResponse('An unexpected error occurred: ' + userMessage);
        }
    }

    public static List<litify_pm__Intake__c> getAvailableRecords(Integer limitCount, Integer offset, String statusFilter, String caseTypeFilter, String dueDateFilter, Boolean showScheduledCalls, String tileFilter) {
        Boolean allowFutureWindow = 'nextWeek'.equalsIgnoreCase(dueDateFilter);
        String query = buildBaseQuery(REQUIRED_FIELDS, showScheduledCalls, allowFutureWindow);

        Map<String, Object> bindVars = new Map<String, Object>();
        Datetime nowValue = Datetime.now();
        bindVars.put('now', nowValue);
        bindVars.put('twoHoursFromNow', nowValue.addHours(2));
        bindVars.put('fourHoursAgo', nowValue.addHours(-4));
        bindVars.put('twoWeeksFromNow', nowValue.addDays(14));
        bindVars.put('excludedTypes', EXCLUDED_INTAKE_TYPES);
        List<String> conditions = buildFilterConditions(statusFilter, caseTypeFilter, dueDateFilter, tileFilter, bindVars);

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

    public static litify_pm__Intake__c getRecordById(String recordId) {
        if (String.isBlank(recordId)) {
            return null;
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
        return records.isEmpty() ? null : records[0];
    }

    public static void validateFieldAccess() {
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

    public static Boolean isStatusInGroup(String groupKey, String status) {
        if (String.isBlank(groupKey) || String.isBlank(status)) {
            return false;
        }
        Set<String> statusGroup = TILE_STATUS_GROUPS.get(groupKey);
        return statusGroup != null && statusGroup.contains(status);
    }

    public static Map<String, List<String>> getTileStatusGroups() {
        Map<String, List<String>> result = new Map<String, List<String>>();
        for (String key : TILE_STATUS_GROUPS.keySet()) {
            result.put(key, new List<String>(TILE_STATUS_GROUPS.get(key)));
        }
        return result;
    }

    public static String buildBaseQuery(String requiredFields, Boolean showScheduledCalls, Boolean allowFutureWindow) {
        return 'SELECT ' + requiredFields + ' FROM litify_pm__Intake__c WHERE ' + buildBaseWhereClause(showScheduledCalls, allowFutureWindow);
    }

    public static String buildBaseWhereClause(Boolean showScheduledCalls, Boolean allowFutureWindow) {
        String baseConditions = '(Test_Record__c = false OR Test_Record__c = null) AND (Type__c NOT IN :excludedTypes OR Type__c = null)';

        if (showScheduledCalls == true) {
            String scheduledStandardStatuses = buildStatusInClause(LeadQueueEligibilityService.getScheduledCallStandardStatuses());
            String statusCondition = '(litify_pm__Status__c IN ' + scheduledStandardStatuses +
                ' OR (litify_pm__Status__c = \'Intake Scheduled\' AND (litify_pm__Sign_Up_Method__c = \'E-Sign\' OR (litify_pm__Sign_Up_Method__c = \'Office\' AND Call_at_Date__c >= :twoHoursFromNow))))';
            String timeClause = allowFutureWindow
                ? 'Call_at_Date__c >= :now AND Call_at_Date__c <= :twoWeeksFromNow'
                : 'Call_at_Date__c >= :now';
            return baseConditions + ' AND ' + statusCondition + ' AND ' + timeClause;
        }
        if (allowFutureWindow) {
            String readyStandardStatuses = buildStatusInClause(LeadQueueEligibilityService.getReadyToCallStandardStatuses());
            String futureCondition = '(' +
                '(litify_pm__Status__c IN ' + readyStandardStatuses + ')' +
                ' OR ' +
                '(litify_pm__Status__c = \'Questionnaire\')' +
                ' OR ' +
                '(litify_pm__Status__c = \'Intake Scheduled\')' +
            ')';

            return baseConditions + ' AND ' + futureCondition;
        }

        String readyStandardStatuses = buildStatusInClause(LeadQueueEligibilityService.getReadyToCallStandardStatuses());
        String complexCondition = '(' +
            '(litify_pm__Status__c IN ' + readyStandardStatuses + ' AND Call_at_Date__c <= :now)' +
            ' OR ' +
            '(litify_pm__Status__c = \'Questionnaire\' AND Call_at_Date__c <= :fourHoursAgo)' +
            ' OR ' +
            '(litify_pm__Status__c = \'Intake Scheduled\' AND (' +
                '(litify_pm__Sign_Up_Method__c = \'E-Sign\' AND Call_at_Date__c <= :now)' +
                ' OR ' +
                '(litify_pm__Sign_Up_Method__c = \'Office\' AND Call_at_Date__c <= :now)' +
            '))' +
            ')';

        return baseConditions + ' AND ' + complexCondition;
    }

    public static String buildStatusInClause(List<String> statuses) {
        if (statuses == null || statuses.isEmpty()) {
            return '(\'\')';
        }
        List<String> quoted = new List<String>();
        for (String status : statuses) {
            quoted.add('\'' + String.escapeSingleQuotes(status) + '\'');
        }
        return '(' + String.join(quoted, ', ') + ')';
    }

    public static List<String> buildFilterConditions(String statusFilter, String caseTypeFilter, String dueDateFilter, String tileFilter, Map<String, Object> bindVars) {
        List<String> conditions = new List<String>();
        addQueueCaseTypeEligibilityCondition(conditions, bindVars);
        addReferralCaseTypeCondition(conditions, bindVars);
        if (String.isNotBlank(statusFilter)) {
            conditions.add('litify_pm__Status__c = :statusFilter');
            bindVars.put('statusFilter', statusFilter);
        }
        if (String.isNotBlank(caseTypeFilter)) {
            conditions.add('Queue_Case_Type__c = :caseTypeFilter');
            bindVars.put('caseTypeFilter', caseTypeFilter);
        }
        if (String.isNotBlank(tileFilter)) {
            Set<String> tileStatuses = TILE_STATUS_GROUPS.get(tileFilter);
            if (tileStatuses != null && !tileStatuses.isEmpty()) {
                conditions.add('litify_pm__Status__c IN :tileStatuses');
                bindVars.put('tileStatuses', new List<String>(tileStatuses));
            }
        }
        if (String.isNotBlank(dueDateFilter)) {
            String dateCondition = getDateCondition(dueDateFilter);
            if (dateCondition != null) {
                conditions.add(dateCondition);
            }
        }
        return conditions;
    }

    private static LeadQueueModels.ValidationResult validateFilterInputs(String statusFilter, String caseTypeFilter, String dueDateFilter, Boolean showScheduledCalls, String tileFilter) {
        if (String.isNotBlank(statusFilter)) {
            Set<String> allowedStatuses = showScheduledCalls == true
                ? LeadQueueEligibilityService.getScheduledCallStatuses()
                : LeadQueueEligibilityService.getReadyToCallStatuses();
            if (!allowedStatuses.contains(statusFilter)) {
                return new LeadQueueModels.ValidationResult(false,
                    'Invalid status filter: ' + statusFilter + '. Valid options: ' + String.join(new List<String>(allowedStatuses), ', '));
            }
        }

        if (String.isNotBlank(caseTypeFilter)) {
            Set<String> validCaseTypes = new Set<String>(LeadQueueConfig.CASE_TYPE_PRIORITY.keySet());
            if (!validCaseTypes.contains(caseTypeFilter)) {
                return new LeadQueueModels.ValidationResult(false,
                    'Invalid case type filter: ' + caseTypeFilter + '. Valid options: ' + String.join(new List<String>(validCaseTypes), ', '));
            }
        }

        if (String.isNotBlank(dueDateFilter)) {
            Set<String> validDates = new Set<String>{'today', 'thisWeek', 'nextWeek'};
            if (!validDates.contains(dueDateFilter)) {
                return new LeadQueueModels.ValidationResult(false,
                    'Invalid date filter: ' + dueDateFilter + '. Valid options: today, thisWeek, nextWeek');
            }
        }

        if (String.isNotBlank(tileFilter) && !TILE_STATUS_GROUPS.containsKey(tileFilter)) {
            return new LeadQueueModels.ValidationResult(false,
                'Invalid tile filter: ' + tileFilter + '. Valid options: ' + String.join(new List<String>(TILE_STATUS_GROUPS.keySet()), ', '));
        }

        return new LeadQueueModels.ValidationResult(true, null);
    }

    private static String getUserFriendlyErrorMessage(Exception e) {
        if (e == null) {
            return 'Unexpected error';
        }
        if (e instanceof AuraHandledException) {
            return e.getMessage();
        }
        if (e instanceof QueryException) {
            return 'Unable to load Lead Queue data. Please contact your administrator.';
        }
        return String.isNotBlank(e.getMessage()) ? e.getMessage() : 'Unexpected error';
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

    private static List<litify_pm__Intake__c> queryRecords(String statusFilter, String caseTypeFilter, String dueDateFilter, Boolean showScheduledCalls, String tileFilter, Integer limitCount, Integer offset) {
        return getAvailableRecords(limitCount, offset, statusFilter, caseTypeFilter, dueDateFilter, showScheduledCalls, tileFilter);
    }

    private static List<LeadQueueModels.QueueRecord> processRecords(List<litify_pm__Intake__c> records, Boolean showScheduledCalls) {
        List<LeadQueueModels.QueueRecord> queueRecords = new List<LeadQueueModels.QueueRecord>();

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

        for (litify_pm__Intake__c record : records) {
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

            if (isStatusInGroup('highPriority', status)) {
                stats.highPriorityCount++;
            }

            if (isStatusInGroup('inContact', status)) {
                stats.inContactCount++;
            }

            if (isStatusInGroup('noContact', status)) {
                stats.noContactCount++;
            }

            if (isStatusInGroup('retainerSent', status)) {
                stats.retainerSentCount++;
            }

            if (isStatusInGroup('referrals', status)) {
                stats.referralCount++;
            }
        }

        return stats;
    }

    private static LeadQueueModels.QueueStats calculateStatsForFilters(String statusFilter, String caseTypeFilter, String dueDateFilter, Boolean showScheduledCalls) {
        LeadQueueModels.QueueStats stats = new LeadQueueModels.QueueStats();
        Boolean allowFutureWindow = 'nextWeek'.equalsIgnoreCase(dueDateFilter);
        String whereClause = buildBaseWhereClause(showScheduledCalls, allowFutureWindow);

        Map<String, Object> bindVars = new Map<String, Object>();
        Datetime nowValue = Datetime.now();
        bindVars.put('now', nowValue);
        bindVars.put('twoHoursFromNow', nowValue.addHours(2));
        bindVars.put('fourHoursAgo', nowValue.addHours(-4));
        bindVars.put('twoWeeksFromNow', nowValue.addDays(14));
        bindVars.put('excludedTypes', EXCLUDED_INTAKE_TYPES);

        List<String> conditions = buildFilterConditions(statusFilter, caseTypeFilter, dueDateFilter, null, bindVars);
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
            if (isStatusInGroup('highPriority', status)) {
                stats.highPriorityCount += count;
            }
            if (isStatusInGroup('inContact', status)) {
                stats.inContactCount += count;
            }
            if (isStatusInGroup('noContact', status)) {
                stats.noContactCount += count;
            }
            if (isStatusInGroup('retainerSent', status)) {
                stats.retainerSentCount += count;
            }
            if (isStatusInGroup('referrals', status)) {
                stats.referralCount += count;
            }
        }
        stats.totalRecords = total;
        return stats;
    }

    private static Integer calculateListTotalRecords(String statusFilter, String caseTypeFilter, String dueDateFilter, Boolean showScheduledCalls, String tileFilter) {
        Boolean allowFutureWindow = 'nextWeek'.equalsIgnoreCase(dueDateFilter);
        String whereClause = buildBaseWhereClause(showScheduledCalls, allowFutureWindow);

        Map<String, Object> bindVars = new Map<String, Object>();
        Datetime nowValue = Datetime.now();
        bindVars.put('now', nowValue);
        bindVars.put('twoHoursFromNow', nowValue.addHours(2));
        bindVars.put('fourHoursAgo', nowValue.addHours(-4));
        bindVars.put('twoWeeksFromNow', nowValue.addDays(14));
        bindVars.put('excludedTypes', EXCLUDED_INTAKE_TYPES);

        List<String> conditions = buildFilterConditions(statusFilter, caseTypeFilter, dueDateFilter, tileFilter, bindVars);
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
        Set<String> allowedStatuses = showScheduledCalls == true
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

    private static Boolean isDueToday(Datetime callDateTime) {
        return callDateTime != null && callDateTime.date() == TODAY;
    }

    private static Boolean isOverdue(Datetime callDateTime) {
        return callDateTime != null && callDateTime.date() < TODAY;
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

    private static void addQueueCaseTypeEligibilityCondition(List<String> conditions, Map<String, Object> bindVars) {
        Set<String> allowedCaseTypes = LeadQueueConfig.CASE_TYPE_PRIORITY.keySet();
        if (allowedCaseTypes == null || allowedCaseTypes.isEmpty()) {
            return;
        }
        conditions.add('(Queue_Case_Type__c = null OR Queue_Case_Type__c IN :allowedCaseTypes)');
        bindVars.put('allowedCaseTypes', new List<String>(allowedCaseTypes));
    }

    private static void addReferralCaseTypeCondition(List<String> conditions, Map<String, Object> bindVars) {
        Set<String> referralCaseTypes = LeadQueueEligibilityService.getReferralAllowedCaseTypes();
        if (referralCaseTypes == null || referralCaseTypes.isEmpty()) {
            return;
        }
        conditions.add('(litify_pm__Status__c != \'Referral Pending\' OR Queue_Case_Type__c IN :referralCaseTypes)');
        bindVars.put('referralCaseTypes', new List<String>(referralCaseTypes));
    }

    private static String getDateCondition(String dueDateFilter) {
        switch on dueDateFilter {
            when 'today' { return 'Call_at_Date__c >= TODAY AND Call_at_Date__c < TOMORROW'; }
            when 'thisWeek' { return 'Call_at_Date__c >= THIS_WEEK AND Call_at_Date__c < NEXT_WEEK'; }
            when 'nextWeek' { return 'Call_at_Date__c >= NEXT_WEEK AND Call_at_Date__c < NEXT_N_WEEKS:2'; }
            when else { return null; }
        }
    }
}
