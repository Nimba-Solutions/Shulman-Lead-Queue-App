public class CaseTypePriorityBackfill implements Database.Batchable<SObject> {
    public Database.QueryLocator start(Database.BatchableContext context) {
        return Database.getQueryLocator([
            SELECT Id
            FROM litify_pm__Intake__c
            WHERE Case_Type_Priority__c = null
        ]);
    }

    public void execute(Database.BatchableContext context, List<litify_pm__Intake__c> scope) {
        update scope;
    }

    public void finish(Database.BatchableContext context) {
    }
}
