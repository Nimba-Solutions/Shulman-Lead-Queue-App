public class CaseTypePriorityBackfill implements Database.Batchable<SObject> {
    public Database.QueryLocator start(Database.BatchableContext context) {
        return Database.getQueryLocator([
            SELECT Id, Type__c, Case_Type__c, Queue_Case_Type__c, litify_pm__Status__c, Priority_Score__c
            FROM litify_pm__Intake__c
            WHERE Type__c != null
                OR Case_Type__c != null
                OR Queue_Case_Type__c != null
                OR Priority_Score__c = null
        ]);
    }

    public void execute(Database.BatchableContext context, List<litify_pm__Intake__c> scope) {
        List<litify_pm__Intake__c> updates = new List<litify_pm__Intake__c>();
        for (litify_pm__Intake__c record : scope) {
            String queueCaseType = LeadQueueConfig.normalizeCaseType(record.Type__c, record.Case_Type__c);
            Integer caseTypePriority = LeadQueueConfig.getCaseTypePriority(queueCaseType);
            Integer priorityScore = LeadQueueConfig.calculatePriorityScore(record.litify_pm__Status__c, caseTypePriority);
            Boolean isChanged = false;

            if (record.Queue_Case_Type__c != queueCaseType) {
                record.Queue_Case_Type__c = queueCaseType;
                isChanged = true;
            }
            if (record.Priority_Score__c != priorityScore) {
                record.Priority_Score__c = priorityScore;
                isChanged = true;
            }
            if (isChanged) {
                updates.add(record);
            }
        }
        if (!updates.isEmpty()) {
            update updates;
        }
    }

    public void finish(Database.BatchableContext context) {
    }
}
