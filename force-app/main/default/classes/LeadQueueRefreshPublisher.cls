public class LeadQueueRefreshPublisher {
    public static void publish(String reason) {
        if (Test.isRunningTest()) {
            return;
        }
        try {
            LeadQueueRefresh__e eventMessage = new LeadQueueRefresh__e();
            if (String.isNotBlank(reason)) {
                eventMessage.Reason__c = reason;
            }
            EventBus.publish(eventMessage);
        } catch (Exception e) {
            LeadQueueLogging.debug('LeadQueueRefreshPublisher error: ' + e.getMessage());
        }
    }
}
