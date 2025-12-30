public with sharing class LeadQueueEligibilityService {
    private static final Set<String> REFERRAL_ALLOWED_CASE_TYPES = new Set<String>{
        'Worker Compensation',
        'WC & PI',
        'Personal Injury'
    };

    public static Set<String> getReferralAllowedCaseTypes() {
        return new Set<String>(REFERRAL_ALLOWED_CASE_TYPES);
    }

    public static Set<String> getReadyToCallStatuses() {
        return new Set<String>(LeadQueueConfig.STATUS_ORDER);
    }

    public static Set<String> getScheduledCallStatuses() {
        Set<String> result = new Set<String>(LeadQueueConfig.STATUS_ORDER);
        result.remove('Referral Pending');
        return result;
    }

    public static List<String> getReadyToCallStandardStatuses() {
        return getStatusesMinus(getReadyToCallStatuses(), new Set<String>{'Questionnaire', 'Intake Scheduled'});
    }

    public static List<String> getScheduledCallStandardStatuses() {
        return getStatusesMinus(getScheduledCallStatuses(), new Set<String>{'Intake Scheduled'});
    }

    public static Boolean isValidQueueRecord(litify_pm__Intake__c record) {
        if (record == null) {
            return false;
        }
        if (record.litify_pm__Status__c == 'Referral Pending'
            && !REFERRAL_ALLOWED_CASE_TYPES.contains(record.Queue_Case_Type__c)) {
            return false;
        }
        return record.Call_at_Date__c != null
            && String.isNotBlank(record.litify_pm__Status__c)
            && getReadyToCallStatuses().contains(record.litify_pm__Status__c)
            && (String.isBlank(record.Queue_Case_Type__c)
                || LeadQueueConfig.CASE_TYPE_PRIORITY.containsKey(record.Queue_Case_Type__c));
    }

    public static Boolean isEligibleForAssignment(litify_pm__Intake__c record) {
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

    private static List<String> getStatusesMinus(Set<String> source, Set<String> exclude) {
        List<String> result = new List<String>();
        for (String status : LeadQueueConfig.STATUS_ORDER) {
            if (source.contains(status) && !exclude.contains(status)) {
                result.add(status);
            }
        }
        return result;
    }
}
