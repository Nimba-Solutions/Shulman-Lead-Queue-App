export const CDC_RELEVANT_FIELDS = [
    'litify_pm__Status__c',
    'Priority_Score__c',
    'Queue_Case_Type__c',
    'Case_Type__c',
    'Type__c',
    'Call_at_Date__c',
    'Follow_Up_Date_Time__c',
    'Appointment_Date__c',
    'litify_pm__Sign_Up_Method__c',
    'Qualification_Status__c',
    'Test_Record__c',
    'litify_pm__Display_Name__c',
    'Referred_By_Name__c',
    'litify_pm__Phone__c',
    'Name'
];

export function buildRefreshPayload({ action, originId, source }) {
    return {
        action,
        originId,
        source,
        timestamp: Date.now()
    };
}
