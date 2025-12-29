public class CaseTypePriorityBackfill implements Database.Batchable<SObject> {
    public Database.QueryLocator start(Database.BatchableContext context) {
        return Database.getQueryLocator([
            SELECT Id, Type__c, Case_Type__c, Queue_Case_Type__c, litify_pm__Status__c, Priority_Score__c
            FROM litify_pm__Intake__c
            WHERE Queue_Case_Type__c = null
                OR Priority_Score__c = null
                OR (Case_Type__c = null AND Queue_Case_Type__c != null)
        ]);
    }

    public void execute(Database.BatchableContext context, List<litify_pm__Intake__c> scope) {
        for (litify_pm__Intake__c record : scope) {
            String queueCaseType = LeadQueueConfig.normalizeCaseType(record.Type__c, record.Case_Type__c);
            Integer caseTypePriority = LeadQueueConfig.getCaseTypePriority(queueCaseType);
            record.Queue_Case_Type__c = queueCaseType;
            record.Priority_Score__c = LeadQueueConfig.calculatePriorityScore(record.litify_pm__Status__c, caseTypePriority);
        }
        update scope;
    }

    public void finish(Database.BatchableContext context) {
    }
}
