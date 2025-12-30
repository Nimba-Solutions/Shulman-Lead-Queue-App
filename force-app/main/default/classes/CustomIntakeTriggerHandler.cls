public class CustomIntakeTriggerHandler {

    public static void handleTrigger() {
        LeadQueueLogging.debug('=== CUSTOM_TRIGGER_DEBUG: CustomIntakeTriggerHandler called - isBefore: ' + Trigger.isBefore + ', isAfter: ' + Trigger.isAfter + ', isUpdate: ' + Trigger.isUpdate + ' ===');
        
        if (Trigger.isBefore) {
            if (Trigger.isInsert) {
                handleBeforeInsert((List<litify_pm__Intake__c>) Trigger.new);
            }
            else if (Trigger.isUpdate) {
                handleBeforeUpdate((List<litify_pm__Intake__c>) Trigger.new, Trigger.oldMap);
            }
            else if (Trigger.isDelete) {
                handleBeforeDelete((List<litify_pm__Intake__c>) Trigger.old);
            }
        }
        
        if (Trigger.isAfter) {
            if (Trigger.isInsert) {
                handleAfterInsert((List<litify_pm__Intake__c>) Trigger.new);
            }
            else if (Trigger.isUpdate) {
                handleAfterUpdate((List<litify_pm__Intake__c>) Trigger.new, Trigger.oldMap);
            }
            else if (Trigger.isDelete) {
                handleAfterDelete((List<litify_pm__Intake__c>) Trigger.old);
            }
            else if (Trigger.isUndelete) {
                handleAfterUndelete((List<litify_pm__Intake__c>) Trigger.new);
            }
        }
    }
    
    private static void handleBeforeInsert(List<litify_pm__Intake__c> newRecords) {
        applyQueuePriority(newRecords);
    }
    
    private static void handleBeforeUpdate(List<litify_pm__Intake__c> newRecords, Map<Id, SObject> oldRecordsMap) {
        applyQueuePriority(newRecords);
    }
    
    private static void handleBeforeDelete(List<litify_pm__Intake__c> oldRecords) {
        // Add before delete logic here
    }
    
    private static void handleAfterInsert(List<litify_pm__Intake__c> newRecords) {
        LeadQueueRefreshPublisher.publish('intake-insert');
    }
    
    private static void handleAfterUpdate(List<litify_pm__Intake__c> newRecords, Map<Id, SObject> oldRecordsMap) {
        // Route to specific modules
        Map<Id, litify_pm__Intake__c> typedOldMap = (Map<Id, litify_pm__Intake__c>) oldRecordsMap;
        LeadQueueService.handleIntakeFieldChanges(newRecords, typedOldMap);
        if (shouldPublishQueueRefresh(newRecords, typedOldMap)) {
            LeadQueueRefreshPublisher.publish('intake-update');
        }
    }
    
    private static void handleAfterDelete(List<litify_pm__Intake__c> oldRecords) {
        LeadQueueRefreshPublisher.publish('intake-delete');
    }
    
    private static void handleAfterUndelete(List<litify_pm__Intake__c> newRecords) {
        LeadQueueRefreshPublisher.publish('intake-undelete');
    }

    private static Boolean shouldPublishQueueRefresh(List<litify_pm__Intake__c> newRecords, Map<Id, litify_pm__Intake__c> oldRecordsMap) {
        if (newRecords == null || oldRecordsMap == null) {
            return false;
        }
        for (litify_pm__Intake__c newRecord : newRecords) {
            litify_pm__Intake__c oldRecord = oldRecordsMap.get(newRecord.Id);
            if (oldRecord == null) {
                continue;
            }
            if (hasQueueRelevantChange(newRecord, oldRecord)) {
                return true;
            }
        }
        return false;
    }

    private static Boolean hasQueueRelevantChange(litify_pm__Intake__c newRecord, litify_pm__Intake__c oldRecord) {
        return newRecord.litify_pm__Status__c != oldRecord.litify_pm__Status__c
            || newRecord.Priority_Score__c != oldRecord.Priority_Score__c
            || newRecord.Queue_Case_Type__c != oldRecord.Queue_Case_Type__c
            || newRecord.Call_at_Date__c != oldRecord.Call_at_Date__c
            || newRecord.litify_pm__Sign_Up_Method__c != oldRecord.litify_pm__Sign_Up_Method__c
            || newRecord.Qualification_Status__c != oldRecord.Qualification_Status__c
            || newRecord.Test_Record__c != oldRecord.Test_Record__c
            || newRecord.Type__c != oldRecord.Type__c
            || newRecord.litify_pm__Display_Name__c != oldRecord.litify_pm__Display_Name__c
            || newRecord.Referred_By_Name__c != oldRecord.Referred_By_Name__c
            || newRecord.litify_pm__Phone__c != oldRecord.litify_pm__Phone__c
            || newRecord.Name != oldRecord.Name;
    }

    private static void applyQueuePriority(List<litify_pm__Intake__c> records) {
        for (litify_pm__Intake__c record : records) {
            String queueCaseType = LeadQueueConfig.normalizeCaseType(record.Type__c, record.Case_Type__c);
            Integer caseTypePriority = LeadQueueConfig.getCaseTypePriority(queueCaseType);
            record.Queue_Case_Type__c = queueCaseType;
            record.Priority_Score__c = LeadQueueConfig.calculatePriorityScore(record.litify_pm__Status__c, caseTypePriority);
        }
    }
}
