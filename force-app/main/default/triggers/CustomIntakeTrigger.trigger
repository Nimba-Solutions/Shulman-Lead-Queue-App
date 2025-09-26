trigger CustomIntakeTrigger on litify_pm__Intake__c (before insert, before update, after insert, after update, before delete, after delete, after undelete) {
    CustomIntakeTriggerHandler.handleTrigger();
}