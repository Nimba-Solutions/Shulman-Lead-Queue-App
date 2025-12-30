public with sharing class LeadQueueQueryService {
    private static final Map<String, Set<String>> TILE_STATUS_GROUPS = new Map<String, Set<String>>{
        'highPriority' => new Set<String>{'Intake Scheduled', 'Lead Generated'},
        'inContact' => new Set<String>{'In Contact/Under Review', 'Questionnaire', 'Missed Appointment'},
        'noContact' => new Set<String>{'Attempting to Contact'},
        'retainerSent' => new Set<String>{'Intake Package Sent'},
        'referrals' => new Set<String>{'Referral Pending'}
    };

    public static String buildBaseQuery(String requiredFields, Boolean showScheduledCalls, Boolean allowFutureWindow) {
        return 'SELECT ' + requiredFields + ' FROM litify_pm__Intake__c WHERE ' + buildBaseWhereClause(showScheduledCalls, allowFutureWindow);
    }

    public static String buildBaseWhereClause(Boolean showScheduledCalls, Boolean allowFutureWindow) {
        String baseConditions = '(Test_Record__c = false OR Test_Record__c = null) AND (Type__c NOT IN :excludedTypes OR Type__c = null)';
        
        if (showScheduledCalls == true) {
            // Scheduled calls: show future appointments
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
        
        // Ready to call: different time criteria per status
        String readyStandardStatuses = buildStatusInClause(LeadQueueEligibilityService.getReadyToCallStandardStatuses());
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
