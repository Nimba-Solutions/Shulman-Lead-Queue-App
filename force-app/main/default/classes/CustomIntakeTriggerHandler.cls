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
        // Add after insert logic here
    }
    
    private static void handleAfterUpdate(List<litify_pm__Intake__c> newRecords, Map<Id, SObject> oldRecordsMap) {
        // Route to specific modules
        Map<Id, litify_pm__Intake__c> typedOldMap = (Map<Id, litify_pm__Intake__c>) oldRecordsMap;
        LeadQueueService.handleIntakeFieldChanges(newRecords, typedOldMap);
    }
    
    private static void handleAfterDelete(List<litify_pm__Intake__c> oldRecords) {
        // Add after delete logic here
    }
    
    private static void handleAfterUndelete(List<litify_pm__Intake__c> newRecords) {
        // Add after undelete logic here
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
