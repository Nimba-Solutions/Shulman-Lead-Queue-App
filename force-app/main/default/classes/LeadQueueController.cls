public with sharing class LeadQueueController {
    @AuraEnabled
    public static LeadQueueModels.QueueResponse getQueueData(String statusFilter, String caseTypeFilter, String dueDateFilter, Boolean showScheduledCalls) {
        return LeadQueueQueryService.getQueueData(statusFilter, caseTypeFilter, dueDateFilter, showScheduledCalls);
    }

    @AuraEnabled
    public static LeadQueueModels.QueueResponse getQueueDataPaged(String statusFilter, String caseTypeFilter, String dueDateFilter, Boolean showScheduledCalls, Integer pageNumber, Integer pageSize, String tileFilter, Boolean bypassCache) {
        return LeadQueueQueryService.getQueueDataPaged(statusFilter, caseTypeFilter, dueDateFilter, showScheduledCalls, pageNumber, pageSize, tileFilter, bypassCache);
    }

    @AuraEnabled
    public static LeadQueueModels.AssignmentResult assignNextAvailableRecord(String statusFilter, String caseTypeFilter, String dueDateFilter, Boolean showScheduledCalls, String tileFilter) {
        return LeadQueueAssignmentService.assignNextAvailableRecord(statusFilter, caseTypeFilter, dueDateFilter, showScheduledCalls, tileFilter);
    }

    @AuraEnabled(cacheable=true)
    public static Boolean isCacheConfigured() {
        return LeadQueueCacheRepository.isCacheConfigured();
    }

    @AuraEnabled
    public static LeadQueueModels.AssignmentResult assignRecord(String recordId) {
        return LeadQueueAssignmentService.assignRecord(recordId);
    }

    @AuraEnabled
    public static Boolean releaseUserAssignments(String recordId) {
        return LeadQueueAssignmentService.releaseUserAssignments(recordId);
    }

    @AuraEnabled(cacheable=false)
    public static Map<String, Long> getUserAssignmentData() {
        return LeadQueueAssignmentService.getUserAssignmentData();
    }

    @AuraEnabled(cacheable=true)
    public static LeadQueueModels.AssignedRecordSummary getAssignedRecordSummary(String recordId) {
        return LeadQueueAssignmentService.getAssignedRecordSummary(recordId);
    }

    @AuraEnabled(cacheable=false)
    public static List<String> getUserAssignedRecordIds() {
        return LeadQueueAssignmentService.getUserAssignedRecordIds();
    }
}
